<#
.SYNOPSIS
    Removes OS users provisioned by create-users.ps1 from Ubuntu VMs.

.DESCRIPTION
    Reads VM connection details (IP, admin credentials) from the existing
    VmProvisioner vault and the desired user list from the VmUsers vault.
    Joins the two by vmName, then for each reachable VM removes sudoers
    files, user accounts, and declared groups via SSH.

    The same VmUsersConfig that drives create-users.ps1 drives this script -
    every user and declared group in the config is removed.

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable.
    - Posh-SSH is installed, or an internet connection is available so this
      script can install it from PSGallery automatically.

    Unreachable VMs are warned and skipped. Re-run once the VM is reachable,
    or remove the users manually.

.EXAMPLE
    .\remove-users.ps1
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
if (-not $_common -or $_common.Version -lt [Version]'2.0.1') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# Dot-source helpers after Infrastructure.Common is loaded so
# Assert-RequiredProperties is available inside their function bodies.
. "$PSScriptRoot\reconcile\common\ConvertFrom-VmUsersConfigJson.ps1"
. "$PSScriptRoot\reconcile\down\Invoke-VmUserRemove.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmGroups.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmSudoers.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmUsers.ps1"

# Infrastructure.Secrets must already be installed by setup-secrets.ps1.
Import-Module Infrastructure.Secrets                    -ErrorAction Stop
Import-Module Microsoft.PowerShell.SecretManagement    -ErrorAction Stop

# Posh-SSH is installed here solely to obtain its bundled Renci.SshNet.dll.
# Posh-SSH's own cmdlets (New-SSHSession, Invoke-SSHCommand) are NOT used
# because ConnectionInfoGenerator in Posh-SSH 3.x has a bug that drops
# algorithm entries from the SSH.NET ConnectionInfo, causing "Key exchange
# negotiation failed" against OpenSSH 9.x (Ubuntu 24.04). SSH.NET is used
# directly instead via Invoke-SshClientCommand (Infrastructure.Common) and the
# connection block in the removal loop below.
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

$provisionerVms = ConvertTo-Array ($provisionerJson | ConvertFrom-Json)

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

$userEntries = ConvertTo-Array (ConvertFrom-VmUsersConfigJson -Json $usersJson)

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
# 5. Removal via SSH
#    For each reachable VM, open one SSH session and remove sudoers files,
#    users, and declared groups within it. The session is always closed in
#    the finally block, even if an operation throws.
#
#    Security note: SSH.NET accepts any host key by default (no
#    HostKeyReceived handler). This is equivalent to Posh-SSH's -AcceptKey
#    and is acceptable on a private Hyper-V network with statically
#    provisioned IPs. Do NOT use on untrusted networks.
# ---------------------------------------------------------------------------

foreach ($t in $reachable) {
    $name = $t.Entry.vmName
    $prov = $t.Provisioner

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
        # PasswordAuthenticationMethod requires a plain string. VM passwords
        # originate as JSON field values (ConvertFrom-Json -> [string]);
        # converting to SecureString would only require converting back here.
        $auth      = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                         $prov.username, $prov.password)
        $connInfo  = [Renci.SshNet.ConnectionInfo]::new(
                         $prov.ipAddress, $prov.username, @($auth))
        $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
        $sshClient.Connect()

        Invoke-VmUserRemove `
            -SshClient $sshClient `
            -VmName    $name `
            -Entry     $t.Entry
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
