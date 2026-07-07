<#
.SYNOPSIS
    Structural wiring checks for create-users.ps1.

.DESCRIPTION
    create-users.ps1 has top-level side effects (module install/import,
    two vault reads, SSH reconcile loop) that make it impractical to
    dot-source from a test. The script also reads the two SecretManagement
    secrets inline rather than via an extracted helper, so there is no
    function seam to mock for behavioural coverage.

    As a pragmatic compromise these tests parse the file via AST and
    assert the parts of the SecretSuffix contract that would otherwise
    silently regress:

      - $SecretSuffix is a Mandatory + ValidateNotNullOrEmpty script
        parameter.
      - Both Get-Secret calls bind -Name to a variable (the per-vault
        $...SecretName string assembled from $SecretSuffix), NOT a
        literal vault key.
      - The two name-building expandable strings interpolate
        $SecretSuffix - a regression that hard-codes the suffix would
        defeat the lifecycle-isolation contract the parameter exists
        to enforce.
      - No bare 'VmProvisionerConfig' or 'VmUsersConfig' string
        literals remain in the file (regression guard for a partial
        revert).
#>

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\create-users.ps1'
    $script:scriptText = Get-Content -LiteralPath $script:scriptPath -Raw

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath, [ref] $tokens, [ref] $parseErrs)
    if ($parseErrs.Count -gt 0) {
        throw "create-users.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    # Returns the value-expression AST node bound to the named parameter
    # in a CommandAst. Walks the CommandElements in pairs looking for
    # `-Name <value>`. Returns $null if not found.
    function Get-BoundArgFor {
        param(
            [System.Management.Automation.Language.CommandAst] $Call,
            [string] $ParameterName
        )
        for ($i = 1; $i -lt $Call.CommandElements.Count - 1; $i++) {
            $cur  = $Call.CommandElements[$i]
            $next = $Call.CommandElements[$i + 1]
            if ($cur -is [System.Management.Automation.Language.CommandParameterAst] -and
                $cur.ParameterName -eq $ParameterName) {
                return $next
            }
        }
        return $null
    }
}

Describe 'create-users.ps1 - SecretSuffix parameter contract' {

    It 'declares -SecretSuffix as a script parameter' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $param | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix Mandatory' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasMandatory = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'Parameter' -and
            ($_.NamedArguments | Where-Object {
                $_.ArgumentName -eq 'Mandatory'
            })
        }
        $hasMandatory | Should -Not -BeNullOrEmpty
    }

    It 'marks -SecretSuffix ValidateNotNullOrEmpty' {
        $param = $script:ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'SecretSuffix' } |
            Select-Object -First 1
        $hasValidator = $param.Attributes | Where-Object {
            $_.TypeName.Name -eq 'ValidateNotNullOrEmpty'
        }
        $hasValidator | Should -Not -BeNullOrEmpty
    }
}

Describe 'create-users.ps1 - Get-Secret wiring carries the suffix' {

    # Each Get-Secret call must bind -Name to a variable (the assembled
    # `VmProvisionerConfig-$SecretSuffix` / `VmUsersConfig-$SecretSuffix`
    # string), not a bare literal. A regression that replaces the
    # variable with the old literal would silently defeat the per-
    # lifecycle isolation the parameter exists to enforce.

    BeforeAll {
        $script:getSecretCalls = $script:commands | Where-Object {
            $_.GetCommandName() -eq 'Get-Secret'
        }
    }

    It 'calls Get-Secret exactly twice (once per vault)' {
        @($script:getSecretCalls).Count | Should -Be 2
    }

    It 'the VmProvisioner-vault Get-Secret binds -Name to a variable' {
        $call = $script:getSecretCalls | Where-Object {
            $vaultArg = Get-BoundArgFor -Call $_ -ParameterName 'Vault'
            $vaultArg -and $vaultArg.Extent.Text -eq 'VmProvisioner'
        } | Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty

        $nameArg = Get-BoundArgFor -Call $call -ParameterName 'Name'
        $nameArg | Should -BeOfType `
            ([System.Management.Automation.Language.VariableExpressionAst])
    }

    It 'the VmUsers-vault Get-Secret binds -Name to a variable' {
        $call = $script:getSecretCalls | Where-Object {
            $vaultArg = Get-BoundArgFor -Call $_ -ParameterName 'Vault'
            $vaultArg -and $vaultArg.Extent.Text -eq 'VmUsers'
        } | Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty

        $nameArg = Get-BoundArgFor -Call $call -ParameterName 'Name'
        $nameArg | Should -BeOfType `
            ([System.Management.Automation.Language.VariableExpressionAst])
    }

    It 'assembles the VmProvisioner secret name by interpolating $SecretSuffix' {
        $script:scriptText | Should -Match `
            '"VmProvisionerConfig-\$SecretSuffix"'
    }

    It 'assembles the VmUsers secret name by interpolating $SecretSuffix' {
        $script:scriptText | Should -Match `
            '"VmUsersConfig-\$SecretSuffix"'
    }
}

Describe 'create-users.ps1 - jump-host wiring (feature 53 NAT topology)' {

    # The host has no route into the per-environment private switch
    # workloads sit on after feature 53 step 2. The script must (1)
    # find the router row in VmProvisionerConfig, (2) discover its
    # upstream IP via KVP, (3) stamp _RouterVm onto every workload in
    # the same env, and (4) reach workloads via New-VmSshClientWithJump
    # instead of constructing a Renci.SshNet.SshClient directly. Lock
    # each leg as a structural check so a future refactor that drops
    # one of them is caught before the agent first runs.

    BeforeAll {
        $script:commandCalls = $script:commands |
            Where-Object { $null -ne $_.GetCommandName() }
    }

    It 'calls Get-VmKvpIpAddress to discover the router upstream IP' {
        $call = $script:commandCalls | Where-Object {
            $_.GetCommandName() -eq 'Get-VmKvpIpAddress'
        } | Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'calls New-VmSshClientWithJump for the per-VM SSH session' {
        $call = $script:commandCalls | Where-Object {
            $_.GetCommandName() -eq 'New-VmSshClientWithJump'
        } | Select-Object -First 1
        $call | Should -Not -BeNullOrEmpty
    }

    It 'stamps _RouterVm onto workloads via Add-Member' {
        # Regression guard: New-VmSshClientWithJump decides direct vs
        # jumped based on this property. If the stamping is dropped,
        # every workload silently falls back to the direct-connect
        # branch and times out behind the router. (?s) enables single-
        # line mode so the regex spans the backtick continuation
        # between `Add-Member` and `-Name '_RouterVm'`.
        $script:scriptText | Should -Match `
            "(?s)Add-Member[^']*-Name\s+'_RouterVm'"
    }

    It 'no longer constructs Renci.SshNet.SshClient directly' {
        # Regression guard for a partial revert. The jump-aware helper
        # owns the SshClient lifetime now; bare construction here would
        # bypass the jump leg entirely.
        $script:scriptText | Should -Not -Match `
            '\[Renci\.SshNet\.SshClient\]::new'
    }
}

Describe 'create-users.ps1 - no stale unsuffixed literals' {

    # Regression guard for a partial revert. A bare 'VmProvisionerConfig'
    # or 'VmUsersConfig' StringConstantExpressionAst anywhere in the file
    # is a strong signal that the suffix wiring was undone in one spot
    # but the rest of the file was left alone.

    BeforeAll {
        $script:stringLiterals = $script:ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)
    }

    It 'has no bare "VmProvisionerConfig" string literal' {
        $offenders = $script:stringLiterals | Where-Object {
            $_.Value -eq 'VmProvisionerConfig'
        }
        @($offenders).Count | Should -Be 0 `
            -Because 'the secret name must always carry the suffix'
    }

    It 'has no bare "VmUsersConfig" string literal' {
        $offenders = $script:stringLiterals | Where-Object {
            $_.Value -eq 'VmUsersConfig'
        }
        @($offenders).Count | Should -Be 0
    }
}

Describe 'create-users.ps1 - cross-process timing export (feature 88 D2)' {

    # create-users.ps1 is the CHILD half of the process-boundary timing bridge:
    # a parent orchestrator (the E2E runner) sets $env:TIMING_TREE_OUTPUT_PATH
    # and the script serialises its phase tree there via the
    # Export-PhaseTimingTree shim so the parent can graft this run's timings
    # under the "reconcile users" part that shelled out to it. The behavioural
    # guarantee that the shim writes schema-valid JSON when a path is given and
    # no-ops when the context was never initialised is owned by
    # Common.PowerShell's Export-PhaseTimingTree.Tests.ps1. create-users.ps1 has
    # top-level side effects (vault reads, module imports, SSH loop) so it
    # cannot be dot-sourced to exercise it end-to-end; these AST checks pin what
    # the script adds - the stage declarations, the per-stage wrappers, and the
    # single env-guarded export - the same structural way the rest of this suite
    # pins wiring.

    BeforeAll {
        $script:initCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Initialize-PhaseTimings' })
        $script:phaseTimerCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-WithPhaseTimer' })
        $script:exportCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Export-PhaseTimingTree' })

        # The outer try/finally (the only one with a Finally block); its extent
        # bounds the finally-path export.
        $script:outerTry = $script:ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally
        }, $true) | Select-Object -First 1

        # The three stages create-users.ps1 times, in run order. Each is
        # pre-declared (so a never-run stage still renders) and wrapped in its
        # own Invoke-WithPhaseTimer.
        $script:expectedPhases = @(
            'Read configs + resolve router IP',
            'Match + SSH-probe targets',
            'Per-VM SSH reconcile'
        )
    }

    It 'declares the timing context once via Initialize-PhaseTimings' {
        $script:initCalls.Count | Should -Be 1
    }

    It 'records the three stages under the expected names' {
        # Guards the stage names the E2E graft (C2) attaches under the
        # "reconcile users" part; a rename here silently reshapes that report.
        $wrapped = $script:phaseTimerCalls | ForEach-Object {
            (Get-BoundArgFor -Call $_ -ParameterName 'Name').Value
        }
        foreach ($phase in $script:expectedPhases) {
            $wrapped | Should -Contain $phase
        }
    }

    It 'wraps each stage in its own Invoke-WithPhaseTimer' {
        $script:phaseTimerCalls.Count | Should -Be $script:expectedPhases.Count
    }

    It 'invokes Export-PhaseTimingTree exactly once (finally)' {
        # create-users.ps1 has no early-exit path (unlike provision.ps1's
        # reboot exit), so a single finally-path export covers the success and
        # failure paths both.
        $script:exportCalls.Count | Should -Be 1
    }

    It 'guards the export behind an $env:TIMING_TREE_OUTPUT_PATH check' {
        # Unset => the guard is false => no call => no file written, so the
        # opt-out path leaves an operator run's behaviour unchanged.
        $ifAst = $script:exportCalls[0].Parent
        while ($null -ne $ifAst -and
               -not ($ifAst -is [System.Management.Automation.Language.IfStatementAst])) {
            $ifAst = $ifAst.Parent
        }
        $ifAst | Should -Not -BeNullOrEmpty `
            -Because 'an unconditional export would drop a stray artifact on every operator run'
        $ifAst.Clauses[0].Item1.Extent.Text |
            Should -Match 'env:TIMING_TREE_OUTPUT_PATH'
    }

    It 'passes $env:TIMING_TREE_OUTPUT_PATH as the export -Path' {
        $script:exportCalls[0].Extent.Text |
            Should -Match '-Path\s+\$env:TIMING_TREE_OUTPUT_PATH'
    }

    It 'exports from the outer try/finally (fires on success and failure)' {
        $script:outerTry | Should -Not -BeNullOrEmpty
        $finallyExtent = $script:outerTry.Finally.Extent
        $inFinally = @($script:exportCalls | Where-Object {
            $_.Extent.StartOffset -ge $finallyExtent.StartOffset -and
            $_.Extent.EndOffset   -le $finallyExtent.EndOffset
        })
        $inFinally.Count | Should -Be 1 `
            -Because 'the finally export covers both normal-completion and thrown-failure paths'
    }

    It 'raises the Common.PowerShell floor to the Export-PhaseTimingTree release (>= 9.2.0)' {
        # The shim ships in Common.PowerShell 9.2.0; the bootstrap floor must
        # rise so the import resolves it. Pin the MinimumVersion so a downgrade
        # cannot silently leave the script calling an unexported verb.
        $depsPath = Join-Path (Split-Path $script:scriptPath -Parent) `
            '..\shared\Install-ModuleDependencies.ps1'
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText | Should -Match "MinimumVersion '(9\.(?:[2-9]|\d\d+)\.\d+|[1-9]\d+\.\d+\.\d+)'"
    }
}
