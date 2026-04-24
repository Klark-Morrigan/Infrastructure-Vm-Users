BeforeAll {
    function Invoke-GroupReconciliation   { param($SshClient, $VmName, $DeclaredGroups, $Users) }
    function Invoke-SudoersReconciliation { param($SshClient, $VmName, $User) }
    function Invoke-UserReconciliation    { param($SshClient, $VmName, $User) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\reconcile\up\Invoke-VmUserCreate.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}

    # Builds a minimal valid entry. Optionally add a groups property.
    function New-Entry {
        param(
            [string[]] $Usernames = @('u-deploy'),
            [object[]] $Groups    = $null
        )
        $users = $Usernames | ForEach-Object {
            [PSCustomObject] @{
                username = $_
                shell    = '/bin/bash'
                homeDir  = "/home/$_"
                groups   = @()
            }
        }
        $entry = [PSCustomObject] @{ vmName = 'node-01'; users = $users }
        if ($null -ne $Groups) {
            Add-Member -InputObject $entry -MemberType NoteProperty `
                -Name 'groups' -Value $Groups
        }
        $entry
    }
}

Describe 'Invoke-VmUserCreate' {

    Context 'group reconciliation' {
        It 'calls Invoke-GroupReconciliation once per VM' {
            Mock Invoke-GroupReconciliation   {}
            Mock Invoke-UserReconciliation    {}
            Mock Invoke-SudoersReconciliation {}

            Invoke-VmUserCreate -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry)

            Should -Invoke Invoke-GroupReconciliation -Times 1
        }

        It 'passes an empty DeclaredGroups when the entry has no groups property' {
            Mock Invoke-GroupReconciliation   {}
            Mock Invoke-UserReconciliation    {}
            Mock Invoke-SudoersReconciliation {}

            Invoke-VmUserCreate -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry)

            Should -Invoke Invoke-GroupReconciliation -Times 1 -ParameterFilter {
                $DeclaredGroups.Count -eq 0
            }
        }

        It 'passes declared groups when the entry has a groups property' {
            Mock Invoke-GroupReconciliation   {}
            Mock Invoke-UserReconciliation    {}
            Mock Invoke-SudoersReconciliation {}

            $groups = @([PSCustomObject] @{ groupName = 'docker' })
            Invoke-VmUserCreate -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry -Groups $groups)

            Should -Invoke Invoke-GroupReconciliation -Times 1 -ParameterFilter {
                $DeclaredGroups.Count -eq 1
            }
        }
    }

    Context 'per-user reconciliation' {
        It 'calls Invoke-UserReconciliation and Invoke-SudoersReconciliation once per user' {
            Mock Invoke-GroupReconciliation   {}
            Mock Invoke-UserReconciliation    {}
            Mock Invoke-SudoersReconciliation {}

            Invoke-VmUserCreate -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry @('u-deploy', 'u-runner'))

            Should -Invoke Invoke-UserReconciliation    -Times 2
            Should -Invoke Invoke-SudoersReconciliation -Times 2
        }

        It 'calls Invoke-UserReconciliation before Invoke-SudoersReconciliation for each user' {
            $Script:_callOrder = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-GroupReconciliation   {}
            Mock Invoke-UserReconciliation    { $Script:_callOrder.Add('user') }
            Mock Invoke-SudoersReconciliation { $Script:_callOrder.Add('sudoers') }

            Invoke-VmUserCreate -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry @('u-deploy', 'u-runner'))

            # Expected interleaved order: user, sudoers, user, sudoers
            $Script:_callOrder[0] | Should -Be 'user'
            $Script:_callOrder[1] | Should -Be 'sudoers'
            $Script:_callOrder[2] | Should -Be 'user'
            $Script:_callOrder[3] | Should -Be 'sudoers'
        }
    }
}
