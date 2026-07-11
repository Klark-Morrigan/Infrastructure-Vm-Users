<#
.SYNOPSIS
    Structural wiring checks for the thin create-users.ps1 entry script.

.DESCRIPTION
    After feature 88 D2-C, create-users.ps1 is a thin entry point: it
    bootstraps modules, dot-sources its create-direction reconcile helpers plus
    the shared orchestrator, and makes a single call to Invoke-VmUserReconcileRun
    with the create-direction final-phase label and a -PerVmAction that calls
    Invoke-VmUserCreate. All the multi-stage behaviour (the two vault reads,
    router resolution, the vmName join, the SSH probe, the per-VM session
    lifecycle, and the timing export) moved into the orchestrator, which is
    behaviourally tested under reconcile/common/Invoke-VmUserReconcileRun.Tests.ps1.

    The script still has top-level side effects (module install/import) that make
    it impractical to dot-source, so these AST checks pin only what the thin entry
    script itself owns: the SecretSuffix parameter contract, the single
    orchestrator call carrying the suffix and the create-direction label, the
    per-VM action wired to Invoke-VmUserCreate, and the absence of any stale
    behaviour (bare secret literals, direct vault reads) that would signal a
    partial revert of the extraction.
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

    # This entry script's create-direction identity.
    $script:expectedFinalPhase = 'Per-VM SSH reconcile'
    $script:expectedPerVmVerb  = 'Invoke-VmUserCreate'
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

Describe 'create-users.ps1 - delegates to the shared orchestrator' {

    BeforeAll {
        $script:orchestratorCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmUserReconcileRun' })
    }

    It 'dot-sources the shared orchestrator helper' {
        # The single call below resolves only if the orchestrator is dot-sourced
        # first; pin the dot-source so a dropped import fails here, not at runtime.
        $script:scriptText | Should -Match 'reconcile\\common\\Invoke-VmUserReconcileRun\.ps1'
    }

    It 'calls Invoke-VmUserReconcileRun exactly once' {
        $script:orchestratorCalls.Count | Should -Be 1
    }

    It 'binds -SecretSuffix to the script $SecretSuffix parameter' {
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'SecretSuffix'
        $arg | Should -BeOfType `
            ([System.Management.Automation.Language.VariableExpressionAst])
        $arg.VariablePath.UserPath | Should -Be 'SecretSuffix'
    }

    It 'passes the create-direction final-phase label' {
        # Guards the third stage name the E2E graft (C2) attaches under the
        # "reconcile users" part; a rename here silently reshapes that report.
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'FinalPhaseName'
        $arg.Value | Should -Be $script:expectedFinalPhase
    }

    It 'wires the per-VM action to Invoke-VmUserCreate' {
        # The lone create-vs-remove difference: the entry script's -PerVmAction
        # body must call its own create helper over the open session.
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'PerVmAction'
        $arg | Should -BeOfType `
            ([System.Management.Automation.Language.ScriptBlockExpressionAst])
        $arg.Extent.Text | Should -Match $script:expectedPerVmVerb
    }
}

Describe 'create-users.ps1 - no orchestration behaviour leaked back in' {

    # Regression guards for a partial revert of the D2-C extraction. Everything
    # below moved into Invoke-VmUserReconcileRun; a reappearance here means the
    # thin entry script grew a second, drifting copy of the flow.

    BeforeAll {
        $script:stringLiterals = $script:ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)
    }

    It 'no longer reads the vaults directly (Get-Secret moved to the orchestrator)' {
        $getSecret = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Get-Secret' })
        $getSecret.Count | Should -Be 0
    }

    It 'no longer declares its own timing stages' {
        $init = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Initialize-PhaseTimings' })
        $init.Count | Should -Be 0
    }

    It 'no longer exports the timing tree directly (the orchestrator finally owns it)' {
        $export = @($script:commands | Where-Object {
            $_.GetCommandName() -in @('Export-PhaseTimingTree', 'Export-PhaseTimingTreeIfRequested')
        })
        $export.Count | Should -Be 0
    }

    It 'has no bare "VmProvisionerConfig" string literal' {
        $offenders = $script:stringLiterals | Where-Object {
            $_.Value -eq 'VmProvisionerConfig'
        }
        @($offenders).Count | Should -Be 0 `
            -Because 'the secret name lives in the orchestrator and always carries the suffix'
    }

    It 'has no bare "VmUsersConfig" string literal' {
        $offenders = $script:stringLiterals | Where-Object {
            $_.Value -eq 'VmUsersConfig'
        }
        @($offenders).Count | Should -Be 0
    }
}

Describe 'create-users.ps1 - Common.PowerShell floor' {

    It 'raises the Common.PowerShell floor to the Export-PhaseTimingTreeIfRequested release (>= 9.3.0)' {
        # The shim the orchestrator calls ships in Common.PowerShell 9.3.0; the
        # bootstrap floor must stay >= that so the import resolves it. Pin the
        # MinimumVersion so a downgrade cannot silently leave the run calling an
        # unexported verb.
        $depsPath = Join-Path (Split-Path $script:scriptPath -Parent) `
            '..\shared\Install-ModuleDependencies.ps1'
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText | Should -Match "MinimumVersion '(9\.(?:[3-9]|\d\d+)\.\d+|[1-9]\d+\.\d+\.\d+)'"
    }
}
