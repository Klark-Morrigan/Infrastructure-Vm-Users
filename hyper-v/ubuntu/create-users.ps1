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

# Install / import every required PowerShell module. The helper owns the
# dependency list for this repo so each entry-point script does not repeat
# the bootstrap block.
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# Dot-source helpers after the modules are loaded so Assert-RequiredProperties
# (PowerShell.Common) and the SSH helpers (Infrastructure.HyperV) are
# available inside their function bodies.
. "$PSScriptRoot\reconcile\common\ConvertFrom-VmUsersConfigJson.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-GroupReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-SudoersReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-UserReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-VmUserCreate.ps1"

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
# 4. Probe SSH on each matched VM
#    Test-VmSshPort answers "is sshd accepting connections?" - a strict
#    superset of an ICMP ping, since a successful TCP connect implies the
#    host is up AND has bound port 22. Eliminates the post-reboot race
#    where ICMP succeeds before sshd binds.
# ---------------------------------------------------------------------------

$reachable = [System.Collections.Generic.List[hashtable]]::new()

foreach ($t in $targets) {
    $name = $t.Entry.vmName
    $ip   = $t.Provisioner.ipAddress

    Write-Host "[$name] Probing SSH ..." -ForegroundColor Cyan

    if (Test-VmSshPort -IpAddress $ip) {
        Write-Host "[$name] SSH reachable." -ForegroundColor Green
        $reachable.Add($t)
    }
    else {
        Write-Warning "[$name] SSH unreachable - skipping."
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
        # Security note: SSH.NET accepts any host key by default (no
        # HostKeyReceived handler). This is equivalent to Posh-SSH's
        # -AcceptKey and is acceptable on a private Hyper-V network with
        # statically provisioned IPs. Do NOT use on untrusted networks.
        # PasswordAuthenticationMethod requires a plain string. VM passwords
        # originate as JSON field values (ConvertFrom-Json -> [string]);
        # converting to SecureString would only require converting back here.
        $auth      = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                         $prov.username, $prov.password)
        $connInfo  = [Renci.SshNet.ConnectionInfo]::new(
                         $prov.ipAddress, $prov.username, @($auth))
        $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
        $sshClient.Connect()

        Invoke-VmUserCreate `
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
