<#
.SYNOPSIS
    Behavioural tests for the shared user-reconcile orchestrator.

.DESCRIPTION
    Invoke-VmUserReconcileRun is a function seam (unlike the top-level entry
    scripts create-users.ps1 / remove-users.ps1, which have un-dot-sourceable
    side effects), so the whole flow can be dot-sourced with every boundary
    cmdlet mocked - Get-Secret, ConvertFrom-VmUsersConfigJson, Test-VmSshPort,
    Get-VmKvpIpAddress, New-VmSshClientWithJump - and driven end-to-end. This
    is the coverage the two AST-only entry-script suites could not provide.

    The phase-timing shims (Initialize-PhaseTimings / Invoke-WithPhaseTimer /
    Export-PhaseTimingTreeIfRequested) and ConvertTo-Array come from
    Common.PowerShell in production; here they are stubbed so the suite is
    hermetic. Invoke-WithPhaseTimer's stub simply runs its -Action, which is
    exactly the shim's observable effect - it wraps a stopwatch around the
    action but never alters control flow. The env-var opt-in behaviour of
    Export-PhaseTimingTreeIfRequested itself is owned by Common.PowerShell's
    tests; here we only assert the orchestrator calls it from the finally on
    both the success and failure paths.
#>

BeforeAll {
    $script:orchestratorPath =
        Join-Path $PSScriptRoot '..\..\..\reconcile\common\Invoke-VmUserReconcileRun.ps1'

    # --- Common.PowerShell surface (stubbed) ---------------------------------
    # ConvertTo-Array normalises a scalar-or-array into an array, matching the
    # Common.PowerShell cmdlet the orchestrator relies on to count VMs/entries -
    # including its $null -> empty-array contract (a bare @($null) would yield a
    # one-element array containing $null and break the router scan).
    function ConvertTo-Array {
        param([AllowNull()] $InputObject)
        if ($null -eq $InputObject) { return , @() }
        , @($InputObject)
    }

    # The phase-timing shims. Invoke-WithPhaseTimer runs the action inline (the
    # shim's control-flow-neutral behaviour); the other two are no-op seams the
    # tests Mock to assert on.
    function Initialize-PhaseTimings { param([object[]] $Phases) }
    function Invoke-WithPhaseTimer   { param([string] $Name, [scriptblock] $Action) & $Action }
    function Export-PhaseTimingTreeIfRequested { }

    # --- Infrastructure.HyperV / SecretManagement boundary (stubbed) ---------
    function Get-Secret                { param($Vault, $Name, [switch] $AsPlainText) }
    function ConvertFrom-VmUsersConfigJson { param([string] $Json) }
    function Test-VmSshPort            { param($IpAddress) }
    function Get-VmKvpIpAddress        { param($VmName, $SwitchName, [scriptblock] $OnPoll) }
    function New-VmSshClientWithJump   { param($Vm) }

    . $script:orchestratorPath

    # Builds a provisioner VM row (workload by default).
    function New-ProvisionerVm {
        param(
            [string] $VmName,
            [string] $Ip = '10.0.0.10',
            [string] $Kind,
            [string] $PrivateSwitch
        )
        $vm = [PSCustomObject] @{ vmName = $VmName; ipAddress = $Ip; username = 'admin' }
        if ($Kind)          { Add-Member -InputObject $vm -NotePropertyName 'kind'              -NotePropertyValue $Kind }
        if ($PrivateSwitch) { Add-Member -InputObject $vm -NotePropertyName 'privateSwitchName' -NotePropertyValue $PrivateSwitch }
        $vm
    }

    # Builds a VmUsersConfig entry.
    function New-UserEntry {
        param([string] $VmName)
        [PSCustomObject] @{
            vmName = $VmName
            users  = @([PSCustomObject] @{ username = 'u-deploy'; shell = '/bin/bash'; homeDir = '/home/u-deploy' })
        }
    }

    # Builds a fake SSH session whose Dispose() bumps a script-scoped counter so
    # tests can assert the per-VM session was always torn down.
    function New-FakeSession {
        param([string] $VmName)
        $session = [PSCustomObject] @{ Client = [PSCustomObject] @{ Vm = $VmName } }
        Add-Member -InputObject $session -MemberType ScriptMethod -Name Dispose `
            -Value { $script:disposeCount++ } -PassThru
    }

    # A -PerVmAction that records each invocation (client + vm + entry) so tests
    # can assert it fired once per reachable VM with the right arguments.
    $script:recordingPerVmAction = {
        param($Client, $VmName, $Entry)
        $script:perVmCalls.Add([PSCustomObject] @{ Client = $Client; VmName = $VmName; Entry = $Entry })
    }
}

Describe 'Invoke-VmUserReconcileRun' {

    BeforeEach {
        $script:disposeCount = 0
        $script:perVmCalls   = [System.Collections.Generic.List[object]]::new()
    }

    Context 'secret names carry the suffix' {

        It 'reads both vaults with the SecretSuffix-stamped names' {
            Mock Get-Secret {
                if ($Vault -eq 'VmProvisioner') { return '[]' }
                return 'users-json'
            }
            Mock ConvertFrom-VmUsersConfigJson { @() }

            Invoke-VmUserReconcileRun -SecretSuffix 'Env42' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $script:recordingPerVmAction

            Should -Invoke Get-Secret -Times 1 -ParameterFilter {
                $Vault -eq 'VmProvisioner' -and $Name -eq 'VmProvisionerConfig-Env42'
            }
            Should -Invoke Get-Secret -Times 1 -ParameterFilter {
                $Vault -eq 'VmUsers' -and $Name -eq 'VmUsersConfig-Env42'
            }
        }
    }

    Context 'the final phase label is threaded to the timing declaration' {

        It 'declares the passed FinalPhaseName as a stage' {
            Mock Initialize-PhaseTimings {}
            Mock Get-Secret { if ($Vault -eq 'VmProvisioner') { return '[]' } return 'x' }
            Mock ConvertFrom-VmUsersConfigJson { @() }

            Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH removal' `
                -PerVmAction $script:recordingPerVmAction

            Should -Invoke Initialize-PhaseTimings -Times 1 -ParameterFilter {
                $Phases -contains 'Per-VM SSH removal'
            }
        }
    }

    Context 'vmName join' {

        It 'skips a users entry with no matching provisioner row' {
            $provJson = @(New-ProvisionerVm -VmName 'node-01') | ConvertTo-Json -Depth 5
            Mock Get-Secret { if ($Vault -eq 'VmProvisioner') { return $provJson } return 'x' }
            Mock ConvertFrom-VmUsersConfigJson {
                @((New-UserEntry 'node-01'), (New-UserEntry 'node-99'))
            }
            Mock Test-VmSshPort { $true }
            Mock New-VmSshClientWithJump { New-FakeSession -VmName $Vm.vmName }

            Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $script:recordingPerVmAction

            # node-99 has no provisioner row, so only node-01 reaches the loop.
            $script:perVmCalls              | Should -HaveCount 1
            $script:perVmCalls[0].VmName    | Should -Be 'node-01'
        }
    }

    Context 'SSH reachability probe' {

        It 'runs the action only for VMs that pass the probe' {
            $provJson = @(
                (New-ProvisionerVm -VmName 'node-01' -Ip '10.0.0.11'),
                (New-ProvisionerVm -VmName 'node-02' -Ip '10.0.0.12')
            ) | ConvertTo-Json -Depth 5
            Mock Get-Secret { if ($Vault -eq 'VmProvisioner') { return $provJson } return 'x' }
            Mock ConvertFrom-VmUsersConfigJson {
                @((New-UserEntry 'node-01'), (New-UserEntry 'node-02'))
            }
            # node-01 reachable, node-02 not.
            Mock Test-VmSshPort { $IpAddress -eq '10.0.0.11' }
            Mock New-VmSshClientWithJump { New-FakeSession -VmName $Vm.vmName }

            Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $script:recordingPerVmAction

            $script:perVmCalls           | Should -HaveCount 1
            $script:perVmCalls[0].VmName | Should -Be 'node-01'
        }
    }

    Context 'router-jump topology (feature 53)' {

        BeforeEach {
            # A router row plus one workload on the same private switch. The
            # router carries no ipAddress, so it must be resolved via KVP.
            $router = New-ProvisionerVm -VmName 'router-01' -Kind 'router' -PrivateSwitch 'sw-a'
            $router.PSObject.Properties.Remove('ipAddress')
            Add-Member -InputObject $router -NotePropertyName 'externalSwitchName' -NotePropertyValue 'sw-ext'
            $workload = New-ProvisionerVm -VmName 'node-01' -PrivateSwitch 'sw-a'

            $script:routerProvJson = ConvertTo-Json -Depth 5 -InputObject @($router, $workload)
        }

        It 'resolves the router IP via KVP and skips the direct probe for jumped workloads' {
            Mock Get-Secret { if ($Vault -eq 'VmProvisioner') { return $script:routerProvJson } return 'x' }
            Mock ConvertFrom-VmUsersConfigJson { @(New-UserEntry 'node-01') }
            Mock Import-Module {}                              # Hyper-V import on the router path
            Mock Get-VmKvpIpAddress { '192.168.7.5' }
            Mock Test-VmSshPort { $true }
            Mock New-VmSshClientWithJump { New-FakeSession -VmName $Vm.vmName }

            Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $script:recordingPerVmAction

            # KVP discovery ran, but the host-route probe was skipped for the
            # jumped workload (connect surfaces its own diagnostic instead).
            Should -Invoke Get-VmKvpIpAddress -Times 1
            Should -Invoke Test-VmSshPort     -Times 0
            $script:perVmCalls | Should -HaveCount 1
        }
    }

    Context 'per-VM action and session lifecycle' {

        BeforeEach {
            $provJson = @(New-ProvisionerVm -VmName 'node-01') | ConvertTo-Json -Depth 5
            Mock Get-Secret { if ($Vault -eq 'VmProvisioner') { return $provJson } return 'x' }
            Mock ConvertFrom-VmUsersConfigJson { @(New-UserEntry 'node-01') }
            Mock Test-VmSshPort { $true }
            Mock New-VmSshClientWithJump { New-FakeSession -VmName $Vm.vmName }
        }

        It 'invokes -PerVmAction once per reachable VM with the open client and entry' {
            Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $script:recordingPerVmAction

            $script:perVmCalls              | Should -HaveCount 1
            $script:perVmCalls[0].VmName    | Should -Be 'node-01'
            $script:perVmCalls[0].Client.Vm | Should -Be 'node-01'
            $script:perVmCalls[0].Entry.vmName | Should -Be 'node-01'
        }

        It 'disposes the session on the success path' {
            Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $script:recordingPerVmAction

            $script:disposeCount | Should -Be 1
        }

        It 'disposes the session even when the action throws' {
            $throwing = { param($Client, $VmName, $Entry) throw 'boom' }

            { Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $throwing } | Should -Throw

            $script:disposeCount | Should -Be 1
        }

        # Note: the two per-VM catch clauses (SshConnectionException /
        # SocketException) are not unit-covered here - matching the first clause
        # forces resolution of the Renci.SshNet type, which only loads when
        # Posh-SSH is imported. That is integration territory; the hermetic suite
        # stays free of the SSH stack. The connect/dispose lifecycle either side
        # of the catch is covered by the success and throw cases above.
    }

    Context 'cross-process timing export (finally)' {

        BeforeEach {
            $provJson = @(New-ProvisionerVm -VmName 'node-01') | ConvertTo-Json -Depth 5
            Mock Get-Secret { if ($Vault -eq 'VmProvisioner') { return $provJson } return 'x' }
            Mock ConvertFrom-VmUsersConfigJson { @(New-UserEntry 'node-01') }
            Mock Test-VmSshPort { $true }
            Mock New-VmSshClientWithJump { New-FakeSession -VmName $Vm.vmName }
            Mock Export-PhaseTimingTreeIfRequested {}
        }

        It 'calls Export-PhaseTimingTreeIfRequested on the success path' {
            Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $script:recordingPerVmAction

            Should -Invoke Export-PhaseTimingTreeIfRequested -Times 1
        }

        It 'calls Export-PhaseTimingTreeIfRequested on the failure path' {
            $throwing = { param($Client, $VmName, $Entry) throw 'boom' }

            { Invoke-VmUserReconcileRun -SecretSuffix 'S' `
                -FinalPhaseName 'Per-VM SSH reconcile' `
                -PerVmAction $throwing } | Should -Throw

            Should -Invoke Export-PhaseTimingTreeIfRequested -Times 1
        }
    }
}
