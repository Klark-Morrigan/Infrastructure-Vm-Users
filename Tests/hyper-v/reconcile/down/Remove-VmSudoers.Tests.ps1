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

    . "$PSScriptRoot\..\..\..\..\hyper-v\ubuntu\reconcile\down\Remove-VmSudoers.ps1"

    function New-SshResult([int] $ExitStatus, [string[]] $Output = @(), [string] $Err = '') {
        [PSCustomObject] @{ ExitStatus = $ExitStatus; Output = $Output; Error = $Err }
    }

    function New-User([string] $Username) {
        [PSCustomObject] @{ username = $Username }
    }
}

Describe 'Remove-VmSudoers' {

    Context 'sudoers file exists' {
        It 'issues the rm command' {
            Mock Invoke-SshClientCommand {
                if ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                else                            { New-SshResult 0 }
            }

            Remove-VmSudoers -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -User (New-User 'u-deploy')

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*rm '/etc/sudoers.d/u-deploy'*"
            }
        }

        It 'throws when rm fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                else                            { New-SshResult 1 @() 'permission denied' }
            }

            { Remove-VmSudoers -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -User (New-User 'u-deploy') } |
                Should -Throw -ExpectedMessage '*Failed to remove sudoers*'
        }
    }

    Context 'sudoers file absent' {
        It 'does not issue rm and does not throw' {
            Mock Invoke-SshClientCommand {
                New-SshResult 0 @('absent')
            }

            { Remove-VmSudoers -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -User (New-User 'u-deploy') } | Should -Not -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*rm*'
            }
        }
    }
}
