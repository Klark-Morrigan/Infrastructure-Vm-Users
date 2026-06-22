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
param(
    # Required. See create-users.ps1 for the suffix contract.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install / import every required PowerShell module. The helper owns the
# dependency list for this repo so each entry-point script does not repeat
# the bootstrap block.
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# Dot-source helpers after the modules are loaded so Assert-RequiredProperties
# (Common.PowerShell) and the SSH helpers (Infrastructure.HyperV) are
# available inside their function bodies.
. "$PSScriptRoot\reconcile\common\ConvertFrom-VmUsersConfigJson.ps1"
. "$PSScriptRoot\reconcile\down\Invoke-VmUserRemove.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmGroups.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmSudoers.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmUsers.ps1"

# ---------------------------------------------------------------------------
# 1. Read VmProvisionerConfig from the VmProvisioner vault
#    Fields used: vmName, ipAddress, username, password (admin SSH creds).
#    All other provisioner fields (cpuCount, ramGB, etc.) are irrelevant here
#    and intentionally ignored.
# ---------------------------------------------------------------------------

$provisionerSecretName = "VmProvisionerConfig-$SecretSuffix"
Write-Host "Reading $provisionerSecretName from VmProvisioner vault ..." `
    -ForegroundColor Cyan

$provisionerJson = Get-Secret `
    -Vault VmProvisioner `
    -Name  $provisionerSecretName `
    -AsPlainText `
    -ErrorAction Stop

$provisionerVms = ConvertTo-Array ($provisionerJson | ConvertFrom-Json)

Write-Host "OK - $($provisionerVms.Count) VM(s) in $provisionerSecretName." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 1b. Router-VM resolution (feature-53 NAT topology)
#    Workloads in the per-environment private switch are not reachable from
#    the host directly - the router VM forwards their SSH via MASQUERADE.
#    Find any router row in the same VmProvisionerConfig batch (kind ==
#    'router'), discover its upstream IP via Hyper-V KVP, and stamp it as
#    _RouterVm on each workload so New-VmSshClientWithJump picks the
#    jump-through-router path for that workload's session.
#
#    Symmetric with create-users.ps1's resolution block; both scripts
#    own the same lookup so neither becomes the implicit pre-condition
#    for the other.
# ---------------------------------------------------------------------------

$routerVm = $provisionerVms | Where-Object {
    $_.PSObject.Properties['kind'] -and $_.kind -eq 'router'
} | Select-Object -First 1

if ($null -ne $routerVm) {
    Import-Module Hyper-V -ErrorAction Stop

    if (-not ($routerVm.PSObject.Properties['ipAddress'] -and $routerVm.ipAddress)) {
        Write-Host "Resolving router '$($routerVm.vmName)' upstream IP via KVP ..." `
            -NoNewline -ForegroundColor Cyan
        $routerIp = Get-VmKvpIpAddress `
                        -VmName     $routerVm.vmName `
                        -SwitchName $routerVm.externalSwitchName `
                        -OnPoll     { Write-Host '.' -NoNewline -ForegroundColor Cyan }
        Add-Member -InputObject $routerVm -MemberType NoteProperty `
                   -Name 'ipAddress' -Value $routerIp -Force
        Write-Host " $routerIp" -ForegroundColor Green
    }

    foreach ($vm in $provisionerVms) {
        $isRouter = $vm.PSObject.Properties['kind'] -and $vm.kind -eq 'router'
        if ($isRouter) { continue }
        $sameEnv = $vm.PSObject.Properties['privateSwitchName'] -and
                   $vm.privateSwitchName -eq $routerVm.privateSwitchName
        if (-not $sameEnv) { continue }

        Add-Member -InputObject $vm -MemberType NoteProperty `
                   -Name '_RouterVm' -Value $routerVm -Force
    }
}

# ---------------------------------------------------------------------------
# 2. Read VmUsersConfig from the VmUsers vault
#    ConvertFrom-VmUsersConfigJson validates structure and emits each entry
#    to the pipeline; @() collects all of them.
# ---------------------------------------------------------------------------

$usersSecretName = "VmUsersConfig-$SecretSuffix"
Write-Host "Reading $usersSecretName from VmUsers vault ..." `
    -ForegroundColor Cyan

$usersJson = Get-Secret `
    -Vault VmUsers `
    -Name  $usersSecretName `
    -AsPlainText `
    -ErrorAction Stop

$userEntries = ConvertTo-Array (ConvertFrom-VmUsersConfigJson -Json $usersJson)

Write-Host "OK - $($userEntries.Count) VM entry/entries in $usersSecretName." `
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
#
#    Workloads carrying _RouterVm (feature-53 NAT topology) sit on a
#    private switch the host has no route to - skip the direct probe
#    and rely on the connect attempt's own diagnostics.
# ---------------------------------------------------------------------------

$reachable = [System.Collections.Generic.List[hashtable]]::new()

foreach ($t in $targets) {
    $name = $t.Entry.vmName
    $prov = $t.Provisioner
    $ip   = $prov.ipAddress

    $hasRouter = $prov.PSObject.Properties['_RouterVm'] -and $prov._RouterVm
    if ($hasRouter) {
        Write-Host "[$name] Skipping direct SSH probe (jumped through router)." `
            -ForegroundColor Cyan
        $reachable.Add($t)
        continue
    }

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

    # New-VmSshClientWithJump branches on _RouterVm: jumped through
    # router when stamped (feature-53 NAT), direct otherwise. The
    # returned session exposes Client + Tunnel + Dispose() so the
    # surrounding flow does not have to branch.
    $sshSession = $null

    try {
        $sshSession = New-VmSshClientWithJump -Vm $prov

        Invoke-VmUserRemove `
            -SshClient $sshSession.Client `
            -VmName    $name `
            -Entry     $t.Entry
    }
    catch [Renci.SshNet.Common.SshConnectionException] {
        Write-Error "[$name] SSH connection failed: $($_.Exception.Message)"
    }
    catch [System.Net.Sockets.SocketException] {
        # "Connection refused" - SSH is not listening on port 22 on
        # the workload (or the router, when jumped). The VM is up
        # (probe / route succeeded) but sshd may not have started yet.
        Write-Error "[$name] SSH port refused: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $sshSession) {
            # Swallow teardown failures at verbose level so a Dispose()
            # error cannot mask the per-VM outcome reported above.
            try { $sshSession.Dispose() }
            catch { Write-Verbose "[$name] Dispose() failed during cleanup: $($_.Exception.Message)" }
        }
    }
}
