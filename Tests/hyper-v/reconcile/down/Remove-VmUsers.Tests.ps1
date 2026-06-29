# PSAvoidUsingPositionalParameters is suppressed file-wide: the BeforeAll
# block defines local test-double factories (New-SshResult, New-User, ...)
# whose positional call sites are the idiomatic, readable form in this
# suite, not a real cmdlet-argument hazard.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPositionalParameters', '',
    Justification = 'Positional calls to local test-double factories are idiomatic here')]
param()

BeforeAll {
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\reconcile\down\Remove-VmUsers.ps1"

    function New-SshResult([int] $ExitStatus, [string[]] $Output = @(), [string] $Err = '') {
        [PSCustomObject] @{ ExitStatus = $ExitStatus; Output = $Output; Error = $Err }
    }

    function New-User([string] $Username) {
        [PSCustomObject] @{ username = $Username }
    }
}

Describe 'Remove-VmUsers' {

    Context 'user exists' {
        It 'issues userdel -r' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'id*') { New-SshResult 0 }
                else                      { New-SshResult 0 }
            }

            Remove-VmUsers -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -User (New-User 'u-deploy')

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*userdel -r 'u-deploy'*"
            }
        }

        It 'throws when userdel fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'id*') { New-SshResult 0 }
                else                      { New-SshResult 1 @() 'permission denied' }
            }

            { Remove-VmUsers -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -User (New-User 'u-deploy') } |
                Should -Throw -ExpectedMessage '*userdel failed*'
        }
    }

    Context 'user absent' {
        It 'does not issue userdel and does not throw' {
            Mock Invoke-SshClientCommand { New-SshResult 1 }

            { Remove-VmUsers -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -User (New-User 'u-deploy') } | Should -Not -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*userdel*'
            }
        }
    }
}
