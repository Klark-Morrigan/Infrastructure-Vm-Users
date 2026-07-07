<#
.SYNOPSIS
    Structural wiring checks for remove-users.ps1.

.DESCRIPTION
    See create-users.Tests.ps1 for the rationale - remove-users.ps1
    has the same two-vault read shape and the same SecretSuffix
    contract, so the checks mirror that file with the script path
    swapped.
#>

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\remove-users.ps1'
    $script:scriptText = Get-Content -LiteralPath $script:scriptPath -Raw

    $tokens    = $null
    $parseErrs = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath, [ref] $tokens, [ref] $parseErrs)
    if ($parseErrs.Count -gt 0) {
        throw "remove-users.ps1 has parse errors: $($parseErrs -join '; ')"
    }

    $script:commands = $script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)

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

Describe 'remove-users.ps1 - SecretSuffix parameter contract' {

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

Describe 'remove-users.ps1 - Get-Secret wiring carries the suffix' {

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

Describe 'remove-users.ps1 - jump-host wiring (feature 53 NAT topology)' {

    # Symmetric to create-users.ps1's jump-host wiring tests. The remove
    # path is the same shape (resolve router, stamp _RouterVm, connect
    # via the jump-aware helper) so its regression surface is identical.

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
        # (?s) enables single-line mode so the regex spans the backtick
        # continuation between `Add-Member` and `-Name '_RouterVm'`.
        $script:scriptText | Should -Match `
            "(?s)Add-Member[^']*-Name\s+'_RouterVm'"
    }

    It 'no longer constructs Renci.SshNet.SshClient directly' {
        $script:scriptText | Should -Not -Match `
            '\[Renci\.SshNet\.SshClient\]::new'
    }
}

Describe 'remove-users.ps1 - no stale unsuffixed literals' {

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
        @($offenders).Count | Should -Be 0
    }

    It 'has no bare "VmUsersConfig" string literal' {
        $offenders = $script:stringLiterals | Where-Object {
            $_.Value -eq 'VmUsersConfig'
        }
        @($offenders).Count | Should -Be 0
    }
}

Describe 'remove-users.ps1 - cross-process timing export (feature 88 D2)' {

    # Symmetric to create-users.ps1's timing-export tests. remove-users.ps1 is
    # the other CHILD half of the process-boundary bridge: a parent
    # orchestrator sets $env:TIMING_TREE_OUTPUT_PATH and the script serialises
    # its phase tree there via the Export-PhaseTimingTree shim. The behavioural
    # guarantee is owned by Common.PowerShell's Export-PhaseTimingTree.Tests.ps1;
    # these AST checks pin the stage declarations, the per-stage wrappers, and
    # the single env-guarded export the script adds.

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

        # The three stages remove-users.ps1 times, in run order. Each is
        # pre-declared (so a never-run stage still renders) and wrapped in its
        # own Invoke-WithPhaseTimer.
        $script:expectedPhases = @(
            'Read configs + resolve router IP',
            'Match + SSH-probe targets',
            'Per-VM SSH removal'
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
        # remove-users.ps1 has no early-exit path, so a single finally-path
        # export covers the success and failure paths both.
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
