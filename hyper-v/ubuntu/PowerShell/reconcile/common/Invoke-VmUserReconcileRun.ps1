<#
.NOTES
    Do not run this file directly. It is dot-sourced by create-users.ps1 and
    remove-users.ps1 after Common.PowerShell is loaded (which supplies the
    phase-timing shims, ConvertTo-Array, and Get-Secret) and after the caller
    has dot-sourced its own reconcile helpers plus ConvertFrom-VmUsersConfigJson.
#>

# ---------------------------------------------------------------------------
# Invoke-VmUserReconcileRun
#   The whole user-reconcile orchestration, shared by both lifecycle
#   directions. create-users.ps1 and remove-users.ps1 differ in only three
#   ways - the reconcile helpers they dot-source, the final phase label, and
#   the single per-VM call - so everything around that call (the two vault
#   reads, router resolution, the vmName join, the SSH probe, the per-VM
#   session lifecycle, and the cross-process timing) lives here once. Two
#   verbatim copies of a multi-stage vault-read + router-resolution +
#   SSH-probe + session-lifecycle flow would drift silently: a fix to one
#   (a probe timeout, a KVP-discovery tweak, a Dispose-ordering correction)
#   is easy to forget in the other.
#
#   The caller supplies:
#     -SecretSuffix    the lifecycle label the two secret names carry.
#     -FinalPhaseName  the label for the third timed stage (e.g.
#                      'Per-VM SSH reconcile' vs 'Per-VM SSH removal').
#     -PerVmAction     run once per reachable VM inside the open SSH session,
#                      receiving the connected client, the VM name, and the
#                      users entry - the lone create-vs-remove call.
#
#   Because this is a function seam (not a top-level script), it can be
#   dot-sourced and exercised end-to-end with Get-Secret / Test-VmSshPort /
#   Get-VmKvpIpAddress / New-VmSshClientWithJump mocked, so the whole flow
#   gains real behavioural coverage rather than AST-only structural checks.
# ---------------------------------------------------------------------------

function Invoke-VmUserReconcileRun {
    [CmdletBinding()]
    param(
        # The secret reads target `VmProvisionerConfig-<Suffix>` and
        # `VmUsersConfig-<Suffix>`. See create-users.ps1 for the contract.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SecretSuffix,

        # Label for the third timed stage - the per-VM session loop. Named per
        # direction so the emitted tree distinguishes reconcile from removal.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FinalPhaseName,

        # Invoked once per reachable VM with the open SSH client, the VM name,
        # and the users entry (positional: $Client, $VmName, $Entry). This is
        # the only step that differs between the create and remove directions.
        [Parameter(Mandatory)]
        [scriptblock] $PerVmAction
    )

    # -----------------------------------------------------------------------
    # Phase-timing setup
    #   Initialize-PhaseTimings / Invoke-WithPhaseTimer /
    #   Export-PhaseTimingTreeIfRequested are the 2-level compat shims exported
    #   by Common.PowerShell. Declare the three stages in run order so the tree
    #   lists each one - even a stage that never ran because an earlier one
    #   failed. The stages run inside Invoke-WithPhaseTimer wrappers; the outer
    #   try/finally calls the self-guarding Export-PhaseTimingTreeIfRequested
    #   shim, which exports the tree only when the TIMING_TREE_OUTPUT_PATH
    #   opt-in is set so a parent orchestrator can graft this run's timings
    #   under the part that shelled out to the entry script.
    # -----------------------------------------------------------------------

    Initialize-PhaseTimings -Phases @(
        'Read configs + resolve router IP',
        'Match + SSH-probe targets',
        $FinalPhaseName
    )

    try {

        Invoke-WithPhaseTimer -Name 'Read configs + resolve router IP' -Action {

            # ---------------------------------------------------------------
            # 1. Read VmProvisionerConfig from the VmProvisioner vault
            #    Fields used: vmName, ipAddress, username, password (admin SSH
            #    creds). All other provisioner fields (cpuCount, ramGB, etc.)
            #    are irrelevant here and intentionally ignored.
            # ---------------------------------------------------------------

            # $script:-scoped because Invoke-WithPhaseTimer runs -Action in a
            # child scope; a bare assignment would not survive to the next
            # phase. The values this and the following phases publish this way
            # are read by later phases, so they must land in the script scope,
            # not the action's.
            $provisionerSecretName = "VmProvisionerConfig-$SecretSuffix"
            Write-Host "Reading $provisionerSecretName from VmProvisioner vault ..." `
                -ForegroundColor Cyan

            $provisionerJson = Get-Secret `
                -Vault VmProvisioner `
                -Name  $provisionerSecretName `
                -AsPlainText `
                -ErrorAction Stop

            $script:provisionerVms = ConvertTo-Array ($provisionerJson | ConvertFrom-Json)

            Write-Host "OK - $($provisionerVms.Count) VM(s) in $provisionerSecretName." `
                -ForegroundColor Green

            # ---------------------------------------------------------------
            # 1b. Router-VM resolution (feature-53 NAT topology)
            #    Workloads in the per-environment private switch are not
            #    reachable from the host directly - the router VM forwards
            #    their SSH via MASQUERADE. Find any router row in the same
            #    VmProvisionerConfig batch (kind == 'router'), discover its
            #    upstream IP via Hyper-V KVP, and stamp it as _RouterVm on each
            #    workload so New-VmSshClientWithJump picks the jump-through-
            #    router path for that workload's session.
            #
            #    When no router row is present the batch predates feature 53 (or
            #    the operator deliberately runs a single-switch topology); every
            #    workload keeps the legacy direct-connect path and the join
            #    below proceeds as before.
            # ---------------------------------------------------------------

            # Import Hyper-V here (not in Install-ModuleDependencies) because
            # Get-VM / Get-VMNetworkAdapter are needed only when a router row is
            # present, and Install-ModuleDependencies runs unconditionally -
            # importing it there would fail on Hyper-V-absent hosts that the
            # no-router path supports.
            $routerVm = $provisionerVms | Where-Object {
                $_.PSObject.Properties['kind'] -and $_.kind -eq 'router'
            } | Select-Object -First 1

            if ($null -ne $routerVm) {
                Import-Module Hyper-V -ErrorAction Stop

                # Static-mode routers (externalDhcp = false) keep their
                # ipAddress in the vault; DHCP-mode routers (the schema default)
                # carry it only in Hyper-V KVP. Discover on demand so both modes
                # work without forking the call site.
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

                # Stamp _RouterVm onto every workload (kind != 'router') sharing
                # the router's privateSwitchName. New-VmSshClientWithJump reads
                # this property to decide direct-vs-jumped connection without
                # callers having to thread the router VM explicitly.
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

            # ---------------------------------------------------------------
            # 2. Read VmUsersConfig from the VmUsers vault
            #    ConvertFrom-VmUsersConfigJson validates structure and emits
            #    each entry to the pipeline; ConvertTo-Array collects them.
            # ---------------------------------------------------------------

            $usersSecretName = "VmUsersConfig-$SecretSuffix"
            Write-Host "Reading $usersSecretName from VmUsers vault ..." `
                -ForegroundColor Cyan

            $usersJson = Get-Secret `
                -Vault VmUsers `
                -Name  $usersSecretName `
                -AsPlainText `
                -ErrorAction Stop

            $script:userEntries = ConvertTo-Array (ConvertFrom-VmUsersConfigJson -Json $usersJson)

            Write-Host "OK - $($userEntries.Count) VM entry/entries in $usersSecretName." `
                -ForegroundColor Green
        }

        Invoke-WithPhaseTimer -Name 'Match + SSH-probe targets' -Action {

            # ---------------------------------------------------------------
            # 3. Join by vmName
            #    Build a hashtable index from the provisioner list for O(1)
            #    lookup, then match each users entry. Unmatched entries are
            #    warned and skipped - they likely reference a VM not yet
            #    provisioned or contain a typo in vmName.
            # ---------------------------------------------------------------

            $provisionerIndex = @{}
            foreach ($vm in $provisionerVms) {
                $provisionerIndex[$vm.vmName] = $vm
            }

            # Each element is a hashtable pairing the users entry with its
            # provisioner counterpart so downstream phases have both in one
            # place.
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

            # ---------------------------------------------------------------
            # 4. Probe SSH on each matched VM
            #    Test-VmSshPort answers "is sshd accepting connections?" - a
            #    strict superset of an ICMP ping, since a successful TCP connect
            #    implies the host is up AND has bound port 22. Eliminates the
            #    post-reboot race where ICMP succeeds before sshd binds.
            #
            #    Workloads carrying _RouterVm (feature-53 NAT topology) sit on a
            #    private switch the host has no route to - a direct
            #    Test-VmSshPort would always return $false. Skip the probe for
            #    those: the connect attempt below opens a tunnel + session in
            #    one step and surfaces its own "unreachable" diagnostic when
            #    either leg fails, which is the same information the probe was
            #    trying to extract.
            # ---------------------------------------------------------------

            $script:reachable = [System.Collections.Generic.List[hashtable]]::new()

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
        }

        Invoke-WithPhaseTimer -Name $FinalPhaseName -Action {

            # ---------------------------------------------------------------
            # 5. Per-VM reconcile / removal via SSH
            #    For each reachable VM, open one SSH session and run the
            #    caller's -PerVmAction within it (the create or remove step).
            #    The session is always closed in the finally block, even if the
            #    action throws.
            #
            #    Security note: New-VmSshClientWithJump (and the jump leg inside
            #    it) accepts any host key - equivalent to Posh-SSH's -AcceptKey.
            #    Acceptable on a private Hyper-V network with statically
            #    provisioned IPs. Do NOT use against untrusted or shared
            #    networks.
            #
            #    Sudo assumption: cloud-init adds the provisioned admin user to
            #    the sudo group with NOPASSWD via
            #    /etc/sudoers.d/90-cloud-init-users (Ubuntu default). If your
            #    image disables passwordless sudo, the per-VM action's SSH
            #    commands would need -sudo-password handling.
            # ---------------------------------------------------------------

            foreach ($t in $reachable) {
                $name = $t.Entry.vmName
                $prov = $t.Provisioner

                Write-Host ""
                Write-Host "[$name] Connecting as '$($prov.username)' ..." `
                    -ForegroundColor Cyan

                # New-VmSshClientWithJump owns the direct-vs-jump decision:
                #   - Workload with _RouterVm stamped (feature-53 NAT topology):
                #     opens SSH to the router, sets up a
                #     Renci.SshNet.ForwardedPortLocal to the workload's :22,
                #     then connects through the loopback endpoint. The returned
                #     session's Dispose tears the tunnel down in the right order.
                #   - Static / pre-feature-53 caller: direct New-VmSshClient.
                # Either way callers see a uniform { Client, Tunnel, Dispose() }
                # shape, so the surrounding flow does not branch on topology.
                $sshSession = $null

                try {
                    $sshSession = New-VmSshClientWithJump -Vm $prov

                    # The lone create-vs-remove call. The action runs inside the
                    # open session; the caller passes its own reconcile helper.
                    & $PerVmAction $sshSession.Client $name $t.Entry
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
                        # Swallow teardown failures at verbose level so a
                        # Dispose() error cannot mask the per-VM outcome
                        # reported above.
                        try { $sshSession.Dispose() }
                        catch { Write-Verbose "[$name] Dispose() failed during cleanup: $($_.Exception.Message)" }
                    }
                }
            }
        }
    }
    finally {
        # Cross-process handoff (opt-in). When a parent orchestrator (the E2E
        # runner) sets TIMING_TREE_OUTPUT_PATH, the shim serialises the phase
        # tree to that path so the parent can graft this run's timings under the
        # part that shelled out to the entry script. The shim owns the env-var
        # name and the guard, so this stays one call: it fires on success AND
        # failure, and no-ops when the var is unset or timings were never
        # initialised (no file written).
        Export-PhaseTimingTreeIfRequested
    }
}
