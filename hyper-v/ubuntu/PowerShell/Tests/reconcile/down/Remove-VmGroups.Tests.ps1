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

    . "$PSScriptRoot\..\..\..\reconcile\down\Remove-VmGroups.ps1"

    function New-SshResult([int] $ExitStatus, [string[]] $Output = @(), [string] $Err = '') {
        [PSCustomObject] @{ ExitStatus = $ExitStatus; Output = $Output; Error = $Err }
    }

    function New-Group([string] $GroupName) {
        [PSCustomObject] @{ groupName = $GroupName }
    }
}

Describe 'Remove-VmGroups' {

    Context 'group exists with no members' {
        It 'issues groupdel' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*') { New-SshResult 0 @('docker:x:999:') }
                else                          { New-SshResult 0 }
            }

            Remove-VmGroups -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker')

            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*groupdel 'docker'*"
            }
        }

        It 'throws when groupdel fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*') { New-SshResult 0 @('docker:x:999:') }
                else                          { New-SshResult 1 @() 'permission denied' }
            }

            { Remove-VmGroups -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker') } |
                Should -Throw -ExpectedMessage '*groupdel failed*'
        }
    }

    Context 'group exists with remaining members' {
        It 'warns and does not issue groupdel' {
            Mock Invoke-SshClientCommand {
                New-SshResult 0 @('docker:x:999:u-runner')
            }
            Mock Write-Warning {}

            Remove-VmGroups -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker')

            Should -Invoke Write-Warning -Times 1 -ParameterFilter {
                $Message -like '*still has members*'
            }
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*groupdel*'
            }
        }
    }

    Context 'group absent' {
        It 'does not issue groupdel and does not throw' {
            Mock Invoke-SshClientCommand { New-SshResult 1 }

            { Remove-VmGroups -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker') } | Should -Not -Throw

            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*groupdel*'
            }
        }
    }

    Context 'no declared groups' {
        It 'issues no SSH commands' {
            Mock Invoke-SshClientCommand {}

            Remove-VmGroups -SshClient ([PSCustomObject] @{}) -VmName 'node-01' `
                -DeclaredGroups @()

            Should -Invoke Invoke-SshClientCommand -Times 0
        }
    }
}
