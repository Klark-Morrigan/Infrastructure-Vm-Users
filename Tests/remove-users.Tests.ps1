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
    $script:scriptPath = Join-Path $PSScriptRoot '..\hyper-v\ubuntu\remove-users.ps1'
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
