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
    $script:scriptPath = Join-Path $PSScriptRoot '..\hyper-v\ubuntu\create-users.ps1'
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
