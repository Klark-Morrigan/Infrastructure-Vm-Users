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
param(
    # Required. The secret reads target `VmProvisionerConfig-<Suffix>`
    # and `VmUsersConfig-<Suffix>`. Operator invocations pass
    # `Production`; ephemeral fixtures (test harnesses, parallel
    # workflows, multi-tenant deployments) pass their own label.
    # Mandatory so a caller cannot silently fall through to a default
    # name and collide with another lifecycle's data.
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
#    When no router row is present the batch predates feature 53 (or the
#    operator deliberately runs a single-switch topology); every workload
#    keeps the legacy direct-connect path and the join below proceeds as
#    before.
# ---------------------------------------------------------------------------

# Import Hyper-V here (not in Install-ModuleDependencies) because Get-VM /
# Get-VMNetworkAdapter are needed only when a router row is present, and
# Install-ModuleDependencies runs unconditionally - importing it there
# would fail on Hyper-V-absent hosts that the no-router path supports.
$routerVm = $provisionerVms | Where-Object {
    $_.PSObject.Properties['kind'] -and $_.kind -eq 'router'
} | Select-Object -First 1

if ($null -ne $routerVm) {
    Import-Module Hyper-V -ErrorAction Stop

    # Static-mode routers (externalDhcp = false) keep their ipAddress in
    # the vault; DHCP-mode routers (the schema default) carry it only in
    # Hyper-V KVP. Discover on demand so both modes work without forking
    # the call site.
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

    # Stamp _RouterVm onto every workload (kind != 'router') sharing the
    # router's privateSwitchName. New-VmSshClientWithJump reads this
    # property to decide direct-vs-jumped connection without callers
    # having to thread the router VM explicitly.
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
#    private switch the host has no route to - a direct Test-VmSshPort
#    would always return $false. Skip the probe for those: the connect
#    attempt below opens a tunnel + session in one step and surfaces its
#    own "unreachable" diagnostic when either leg fails, which is the
#    same information the probe was trying to extract.
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

    # New-VmSshClientWithJump owns the direct-vs-jump decision:
    #   - Workload with _RouterVm stamped (feature-53 NAT topology):
    #     opens SSH to the router, sets up a Renci.SshNet.ForwardedPortLocal
    #     to the workload's :22, then connects through the loopback
    #     endpoint. The returned session's Dispose tears the tunnel
    #     down in the right order.
    #   - Static / pre-feature-53 caller: direct New-VmSshClient.
    # Either way callers see a uniform { Client, Tunnel, Dispose() }
    # shape, so the surrounding flow does not branch on topology.
    #
    # Security note: New-VmSshClient (and the jump leg inside the
    # helper) accepts any host key - same posture as the legacy
    # direct-SshClient code path this replaced. Acceptable on a
    # private Hyper-V network with statically provisioned IPs; do NOT
    # use on untrusted networks.
    $sshSession = $null

    try {
        $sshSession = New-VmSshClientWithJump -Vm $prov

        Invoke-VmUserCreate `
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
        # Session owns both the workload client AND (when jumped) the
        # underlying tunnel; Dispose() tears them down in the right
        # order so the workload session closes before the forwarded
        # port goes away. Safe to call when $sshSession is $null
        # (Connect threw before assignment).
        if ($null -ne $sshSession) {
            # Swallow teardown failures at verbose level so a Dispose()
            # error cannot mask the per-VM outcome reported above.
            try { $sshSession.Dispose() }
            catch { Write-Verbose "[$name] Dispose() failed during cleanup: $($_.Exception.Message)" }
        }
    }
}
