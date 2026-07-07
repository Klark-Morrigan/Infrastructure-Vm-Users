<#
.SYNOPSIS
    Structural wiring checks for the thin remove-users.ps1 entry script.

.DESCRIPTION
    See create-users.Tests.ps1 for the rationale - after feature 88 D2-C,
    remove-users.ps1 is the symmetric thin entry point: it bootstraps modules,
    dot-sources its remove-direction reconcile helpers plus the shared
    orchestrator, and makes a single Invoke-VmUserReconcileRun call carrying the
    remove-direction final-phase label and a -PerVmAction that calls
    Invoke-VmUserRemove. The shared behaviour is covered once by
    reconcile/common/Invoke-VmUserReconcileRun.Tests.ps1; these checks mirror
    create-users.Tests.ps1 with the direction swapped.
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

    # This entry script's remove-direction identity.
    $script:expectedFinalPhase = 'Per-VM SSH removal'
    $script:expectedPerVmVerb  = 'Invoke-VmUserRemove'
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

Describe 'remove-users.ps1 - delegates to the shared orchestrator' {

    BeforeAll {
        $script:orchestratorCalls = @($script:commands |
            Where-Object { $_.GetCommandName() -eq 'Invoke-VmUserReconcileRun' })
    }

    It 'dot-sources the shared orchestrator helper' {
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

    It 'passes the remove-direction final-phase label' {
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'FinalPhaseName'
        $arg.Value | Should -Be $script:expectedFinalPhase
    }

    It 'wires the per-VM action to Invoke-VmUserRemove' {
        $arg = Get-BoundArgFor -Call $script:orchestratorCalls[0] -ParameterName 'PerVmAction'
        $arg | Should -BeOfType `
            ([System.Management.Automation.Language.ScriptBlockExpressionAst])
        $arg.Extent.Text | Should -Match $script:expectedPerVmVerb
    }
}

Describe 'remove-users.ps1 - no orchestration behaviour leaked back in' {

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
        @($offenders).Count | Should -Be 0
    }

    It 'has no bare "VmUsersConfig" string literal' {
        $offenders = $script:stringLiterals | Where-Object {
            $_.Value -eq 'VmUsersConfig'
        }
        @($offenders).Count | Should -Be 0
    }
}

Describe 'remove-users.ps1 - Common.PowerShell floor' {

    It 'raises the Common.PowerShell floor to the Export-PhaseTimingTreeIfRequested release (>= 9.3.0)' {
        $depsPath = Join-Path (Split-Path $script:scriptPath -Parent) `
            '..\shared\Install-ModuleDependencies.ps1'
        $depsText = Get-Content -Path $depsPath -Raw
        $depsText | Should -Match "MinimumVersion '(9\.(?:[3-9]|\d\d+)\.\d+|[1-9]\d+\.\d+\.\d+)'"
    }
}
