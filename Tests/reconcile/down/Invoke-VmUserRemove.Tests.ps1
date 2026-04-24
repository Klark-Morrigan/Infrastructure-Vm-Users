BeforeAll {
    function Remove-VmGroups  { param($SshClient, $VmName, $DeclaredGroups) }
    function Remove-VmSudoers { param($SshClient, $VmName, $User) }
    function Remove-VmUsers   { param($SshClient, $VmName, $User) }

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\reconcile\down\Invoke-VmUserRemove.ps1"

    $Script:FakeSsh = [PSCustomObject] @{}

    function New-Entry {
        param(
            [string[]] $Usernames = @('u-deploy'),
            [object[]] $Groups    = $null
        )
        $users = $Usernames | ForEach-Object {
            [PSCustomObject] @{ username = $_; shell = '/bin/bash'; homeDir = "/home/$_" }
        }
        $entry = [PSCustomObject] @{ vmName = 'node-01'; users = $users }
        if ($null -ne $Groups) {
            Add-Member -InputObject $entry -MemberType NoteProperty `
                -Name 'groups' -Value $Groups
        }
        $entry
    }
}

Describe 'Invoke-VmUserRemove' {

    Context 'per-user helpers' {
        It 'calls Remove-VmSudoers and Remove-VmUsers once per user' {
            Mock Remove-VmSudoers {}
            Mock Remove-VmUsers   {}
            Mock Remove-VmGroups  {}

            Invoke-VmUserRemove -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry @('u-deploy', 'u-runner'))

            Should -Invoke Remove-VmSudoers -Times 2
            Should -Invoke Remove-VmUsers   -Times 2
        }
    }

    Context 'group removal' {
        It 'calls Remove-VmGroups once per VM regardless of user count' {
            Mock Remove-VmSudoers {}
            Mock Remove-VmUsers   {}
            Mock Remove-VmGroups  {}

            Invoke-VmUserRemove -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry @('u-deploy', 'u-runner'))

            Should -Invoke Remove-VmGroups -Times 1
        }

        It 'passes an empty DeclaredGroups when the entry has no groups property' {
            $Script:_capturedGroups = $null
            Mock Remove-VmSudoers {}
            Mock Remove-VmUsers   {}
            Mock Remove-VmGroups  { $Script:_capturedGroups = $DeclaredGroups }

            Invoke-VmUserRemove -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry)

            $Script:_capturedGroups | Should -HaveCount 0
        }

        It 'passes declared groups to Remove-VmGroups' {
            $Script:_capturedGroups = $null
            Mock Remove-VmSudoers {}
            Mock Remove-VmUsers   {}
            Mock Remove-VmGroups  { $Script:_capturedGroups = $DeclaredGroups }

            $groups = @([PSCustomObject] @{ groupName = 'docker' })
            Invoke-VmUserRemove -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry -Groups $groups)

            $Script:_capturedGroups          | Should -HaveCount 1
            $Script:_capturedGroups[0].groupName | Should -Be 'docker'
        }
    }

    Context 'call order' {
        It 'calls sudoers and users before groups' {
            $Script:_callOrder = [System.Collections.Generic.List[string]]::new()
            Mock Remove-VmSudoers { $Script:_callOrder.Add('sudoers') }
            Mock Remove-VmUsers   { $Script:_callOrder.Add('users') }
            Mock Remove-VmGroups  { $Script:_callOrder.Add('groups') }

            Invoke-VmUserRemove -SshClient $Script:FakeSsh -VmName 'node-01' `
                -Entry (New-Entry @('u-deploy', 'u-runner'))

            # sudoers, users interleaved per user; groups last
            $Script:_callOrder[0] | Should -Be 'sudoers'
            $Script:_callOrder[1] | Should -Be 'users'
            $Script:_callOrder[2] | Should -Be 'sudoers'
            $Script:_callOrder[3] | Should -Be 'users'
            $Script:_callOrder[4] | Should -Be 'groups'
        }
    }
}
