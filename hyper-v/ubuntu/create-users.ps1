<#
.SYNOPSIS
    Reconciles OS users on Ubuntu VMs against the desired state in the
    VmUsers vault.

.DESCRIPTION
    Reads VM connection details (IP, admin credentials) from the existing
    VmProvisioner vault and the desired user list from the VmUsers vault.
    Joins the two by vmName, then for each reachable VM reconciles OS users
    and sudoers rules via SSH.

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable.
    - Posh-SSH is installed, or an internet connection is available so this
      script can install it from PSGallery automatically.

.EXAMPLE
    .\create-users.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Bootstrap Infrastructure.Common first - it provides Invoke-ModuleInstall
# used for all subsequent module installs. Infrastructure.Secrets and
# Posh-SSH are prerequisites (setup-secrets.ps1 installs the former; the
# latter is auto-installed below), so we do not silently install them here.
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'1.2.1') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# Dot-source helpers after Infrastructure.Common is loaded so
# Assert-RequiredProperties is available inside their function bodies.
. "$PSScriptRoot\reconcile\common\ConvertFrom-VmUsersConfigJson.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-GroupReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-SudoersReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-UserReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-VmUserCreate.ps1"

# Infrastructure.Secrets must already be installed by setup-secrets.ps1.
Import-Module Infrastructure.Secrets                    -ErrorAction Stop
Import-Module Microsoft.PowerShell.SecretManagement    -ErrorAction Stop

# Posh-SSH is installed here solely to obtain its bundled Renci.SshNet.dll.
# Posh-SSH's own cmdlets (New-SSHSession, Invoke-SSHCommand) are NOT used
# because ConnectionInfoGenerator in Posh-SSH 3.x has a bug that drops
# algorithm entries from the SSH.NET ConnectionInfo, causing "Key exchange
# negotiation failed" against OpenSSH 9.x (Ubuntu 24.04). SSH.NET is used
# directly instead via Invoke-SshClientCommand (Infrastructure.Common) and the
# connection block in the reconciliation loop below.
Invoke-ModuleInstall -ModuleName 'Posh-SSH'

# ---------------------------------------------------------------------------
# 1. Read VmProvisionerConfig from the VmProvisioner vault
#    Fields used: vmName, ipAddress, username, password (admin SSH creds).
#    All other provisioner fields (cpuCount, ramGB, etc.) are irrelevant here
#    and intentionally ignored.
# ---------------------------------------------------------------------------

Write-Host "Reading VmProvisionerConfig from VmProvisioner vault ..." `
    -ForegroundColor Cyan

$provisionerJson = Get-Secret `
    -Vault VmProvisioner `
    -Name  VmProvisionerConfig `
    -AsPlainText `
    -ErrorAction Stop

# @() normalises PS 5.1 single-element JSON unwrapping to a consistent array.
$provisionerVms = @($provisionerJson | ConvertFrom-Json)

Write-Host "OK - $($provisionerVms.Count) VM(s) in VmProvisionerConfig." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Read VmUsersConfig from the VmUsers vault
#    ConvertFrom-VmUsersConfigJson validates structure and emits each entry
#    to the pipeline; @() collects all of them.
# ---------------------------------------------------------------------------

Write-Host "Reading VmUsersConfig from VmUsers vault ..." `
    -ForegroundColor Cyan

$usersJson = Get-Secret `
    -Vault VmUsers `
    -Name  VmUsersConfig `
    -AsPlainText `
    -ErrorAction Stop

$userEntries = @(ConvertFrom-VmUsersConfigJson -Json $usersJson)

Write-Host "OK - $($userEntries.Count) VM entry/entries in VmUsersConfig." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Join by vmName
#    Build a hashtable index from the provisioner list for O(1) lookup, then
#    match each users entry. Unmatched entries are warned and skipped - they
#    likely reference a VM not yet provisioned or contain a typo in vmName.
# ---------------------------------------------------------------------------

$provisionerIndex = @{}
foreach ($vm in $provisionerVms) {
    $provisionerIndex[$vm.vmName] = $vm
}

# Each element is a hashtable pairing the users entry with its provisioner
# counterpart so downstream phases have both in one place.
$targets = [System.Collections.Generic.List[hashtable]]::new()

foreach ($entry in $userEntries) {
    $name = $entry.vmName

    if (-not $provisionerIndex.ContainsKey($name)) {
        Write-Warning "[$name] No matching entry in VmProvisionerConfig - skipping."
        continue
    }

    $targets.Add(@{
        Entry       = $entry
        Provisioner = $provisionerIndex[$name]
    })
}

Write-Host "Matched $($targets.Count) of $($userEntries.Count) VM entry/entries." `
    -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 4. Ping each matched VM
#    Test-Connection -Quiet returns $true/$false without throwing.
#    -Count 1 keeps it fast; a single echo reply is enough to confirm the VM
#    is up and the host can reach it.
# ---------------------------------------------------------------------------

$reachable = [System.Collections.Generic.List[hashtable]]::new()

foreach ($t in $targets) {
    $name = $t.Entry.vmName
    $ip   = $t.Provisioner.ipAddress

    Write-Host "[$name] Pinging ..." -ForegroundColor Cyan

    if (Test-Connection -ComputerName $ip -Count 1 -Quiet) {
        Write-Host "[$name] Reachable." -ForegroundColor Green
        $reachable.Add($t)
    }
    else {
        Write-Warning "[$name] Unreachable - skipping."
    }
}

Write-Host "$($reachable.Count) of $($targets.Count) matched VM(s) reachable." `
    -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 5. Reconciliation via SSH
#    For each reachable VM, open one SSH session and reconcile groups, users,
#    and sudoers rules within it. The session is always closed in the finally
#    block, even if an operation throws.
#
#    Security note: -AcceptKey auto-trusts the host key on first connection
#    without verifying a fingerprint. This is acceptable on an internal
#    Hyper-V network with statically provisioned IPs. Do NOT use -AcceptKey
#    against untrusted or shared networks.
#
#    Sudo assumption: cloud-init adds the provisioned admin user to the
#    sudo group with NOPASSWD via /etc/sudoers.d/90-cloud-init-users (Ubuntu
#    default). If your image disables passwordless sudo, add -sudo-password
#    handling before the useradd/usermod calls.
# ---------------------------------------------------------------------------

foreach ($t in $reachable) {
    $name  = $t.Entry.vmName
    $users = @($t.Entry.users)
    $prov  = $t.Provisioner

    Write-Host ""
    Write-Host "[$name] Connecting as '$($prov.username)' ..." `
        -ForegroundColor Cyan

    # $sshClient is declared before the try so the finally block can always
    # reference it, even when Connect() throws before the assignment.
    $sshClient = $null

    try {
        # Connect via SSH.NET directly, bypassing Posh-SSH's wrapper.
        # See the Posh-SSH comment above for why this is necessary.
        #
        # Security note: SSH.NET accepts any host key by default (no
        # HostKeyReceived handler). This is equivalent to Posh-SSH's
        # -AcceptKey and is acceptable on a private Hyper-V network with
        # statically provisioned IPs. Do NOT use on untrusted networks.
        # PasswordAuthenticationMethod requires a plain string. Vm passwords
        # originate as JSON field values (ConvertFrom-Json -> [string]);
        # converting to SecureString would only require converting back here.
        $auth      = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                         $prov.username, $prov.password)
        $connInfo  = [Renci.SshNet.ConnectionInfo]::new(
                         $prov.ipAddress, $prov.username, @($auth))
        $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
        $sshClient.Connect()

        # Get-Member is used to check for the optional 'groups' property
        # without triggering StrictMode on a missing key.
        $entryMembers   = (Get-Member -InputObject $t.Entry -MemberType NoteProperty).Name
        $declaredGroups = if ($entryMembers -contains 'groups') {
            @($t.Entry.groups)
        } else {
            @()
        }

        # 5a. Groups must exist before users reference them in useradd/usermod.
        Invoke-GroupReconciliation `
            -SshClient      $sshClient `
            -VmName         $name `
            -DeclaredGroups $declaredGroups `
            -Users          $users

        foreach ($user in $users) {
            # 5b. Ensure the user exists with the correct shell and groups.
            Invoke-UserReconciliation `
                -SshClient $sshClient `
                -VmName    $name `
                -User      $user

            # 5c. Ensure the sudoers file matches desired rules.
            Invoke-SudoersReconciliation `
                -SshClient $sshClient `
                -VmName    $name `
                -User      $user
        }
    }
    catch [Renci.SshNet.Common.SshConnectionException] {
        Write-Error "[$name] SSH connection failed: $($_.Exception.Message)"
    }
    catch [System.Net.Sockets.SocketException] {
        # "Connection refused" - SSH is not listening on port 22.
        # The VM is up (ping passed) but sshd may not have started yet.
        Write-Error "[$name] SSH port refused: $($_.Exception.Message)"
    }
    finally {
        # Always release the TCP connection, even if Connect() or an
        # operation above threw.
        if ($null -ne $sshClient) {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }
}
