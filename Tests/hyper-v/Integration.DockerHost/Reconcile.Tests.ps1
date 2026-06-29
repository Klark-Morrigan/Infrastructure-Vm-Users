# Consolidated integration tests for all reconciliation functions.
# All tests share one SSH environment (one apt-get run, one SSH session).
# Each Describe block owns its BeforeEach/AfterEach cleanup so user and
# group names can be reused safely across blocks - Pester runs sequentially.
# See Initialize-DockerHostEnvironment.ps1 for environment setup details.

BeforeAll {
    . "$PSScriptRoot\Initialize-DockerHostEnvironment.ps1"

    $src = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'hyper-v', 'ubuntu', 'reconcile')
    . ([IO.Path]::Combine($src, 'up', 'Invoke-GroupReconciliation.ps1'))
    . ([IO.Path]::Combine($src, 'up', 'Invoke-SudoersReconciliation.ps1'))
    . ([IO.Path]::Combine($src, 'up', 'Invoke-UserReconciliation.ps1'))
    . ([IO.Path]::Combine($src, 'down', 'Remove-VmGroups.ps1'))
    . ([IO.Path]::Combine($src, 'down', 'Remove-VmSudoers.ps1'))
    . ([IO.Path]::Combine($src, 'down', 'Remove-VmUsers.ps1'))
    . ([IO.Path]::Combine($src, 'down', 'Invoke-VmUserRemove.ps1'))

    # Must be inside BeforeAll - Pester 5 It blocks cannot see functions
    # defined at script scope outside BeforeAll.
    function New-RemoveEntry {
        param(
            [string[]] $Usernames,
            [object[]] $Groups = $null
        )
        $users = $Usernames | ForEach-Object {
            [PSCustomObject] @{
                username = $_
                shell    = '/bin/bash'
                homeDir  = "/home/$_"
            }
        }
        $entry = [PSCustomObject] @{ vmName = $Script:VmName; users = $users }
        if ($null -ne $Groups) {
            Add-Member -InputObject $entry -MemberType NoteProperty `
                -Name 'groups' -Value $Groups
        }
        $entry
    }
}

AfterAll {
    & bash -c @'
userdel -r infra-t-user  2>/dev/null
userdel -r infra-t-user2 2>/dev/null
groupdel  infra-t-group  2>/dev/null
groupdel  infra-t-implicit 2>/dev/null
rm -f /etc/sudoers.d/infra-t-user
'@  | Out-Null
    . "$PSScriptRoot\Remove-DockerHostEnvironment.ps1"
}

# ---------------------------------------------------------------------------
# Invoke-GroupReconciliation
# ---------------------------------------------------------------------------

Describe 'Invoke-GroupReconciliation' {

    AfterEach {
        & bash -c @'
groupdel infra-t-group    2>/dev/null
groupdel infra-t-implicit 2>/dev/null
'@  | Out-Null
    }

    It 'creates a declared group' {
        $group = [PSCustomObject]@{ groupName = 'infra-t-group' }

        Invoke-GroupReconciliation `
            -SshClient      $Script:SshClient `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()

        Invoke-SshQuery 'getent group infra-t-group' | Should -Match 'infra-t-group'
    }

    It 'is idempotent for a group that already exists' {
        & bash -c 'groupadd infra-t-group' | Out-Null
        $group = [PSCustomObject]@{ groupName = 'infra-t-group' }

        { Invoke-GroupReconciliation `
            -SshClient      $Script:SshClient `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()
        } | Should -Not -Throw
    }

    It 'creates a declared group with a pinned GID' {
        $group = [PSCustomObject]@{ groupName = 'infra-t-group'; gid = 19500 }

        Invoke-GroupReconciliation `
            -SshClient      $Script:SshClient `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()

        $gid = (Invoke-SshQuery 'getent group infra-t-group') -split ':' |
            Select-Object -Index 2
        $gid | Should -Be '19500'
    }

    It 'throws when an existing group has a conflicting GID' {
        & bash -c 'groupadd -g 19501 infra-t-group' | Out-Null
        $group = [PSCustomObject]@{ groupName = 'infra-t-group'; gid = 19502 }

        { Invoke-GroupReconciliation `
            -SshClient      $Script:SshClient `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()
        } | Should -Throw '*GID*'
    }

    It 'creates implicit groups referenced in users[].groups' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            groups   = @('infra-t-implicit')
        }

        Invoke-GroupReconciliation `
            -SshClient      $Script:SshClient `
            -VmName         $Script:VmName `
            -DeclaredGroups @() `
            -Users          @($user)

        Invoke-SshQuery 'getent group infra-t-implicit' | Should -Match 'infra-t-implicit'
    }
}

# ---------------------------------------------------------------------------
# Invoke-UserReconciliation
# ---------------------------------------------------------------------------

Describe 'Invoke-UserReconciliation' {

    BeforeEach {
        & bash -c 'groupadd infra-t-group 2>/dev/null' | Out-Null
    }

    AfterEach {
        & bash -c @'
userdel -r infra-t-user 2>/dev/null
groupdel  infra-t-group 2>/dev/null
'@  | Out-Null
    }

    It 'creates a new user with the correct shell' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-UserReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery 'getent passwd infra-t-user | cut -d: -f7' |
            Should -Be '/bin/bash'
    }

    It 'creates a new user and assigns supplementary groups' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            groups   = @('infra-t-group')
        }

        Invoke-UserReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery 'id -Gn infra-t-user' | Should -Match 'infra-t-group'
    }

    It 'is idempotent when user already matches desired state' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-UserReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        { Invoke-UserReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user
        } | Should -Not -Throw
    }

    It 'updates the shell when it drifts' {
        & bash -c 'useradd -m -s /bin/sh infra-t-user' | Out-Null
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-UserReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery 'getent passwd infra-t-user | cut -d: -f7' |
            Should -Be '/bin/bash'
    }

    It 'updates supplementary groups when they drift' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            groups   = @('infra-t-group')
        }

        Invoke-UserReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery 'id -Gn infra-t-user' | Should -Match 'infra-t-group'
    }

    It 'sets the password so the user can authenticate via SSH' {
        $testPass = 'InfraTestUser1!'
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            password = $testPass
        }

        Invoke-UserReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        $userAuth     = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                            'infra-t-user', $testPass)
        $userConnInfo = [Renci.SshNet.ConnectionInfo]::new(
                            'localhost', 'infra-t-user', @($userAuth))
        $userClient   = [Renci.SshNet.SshClient]::new($userConnInfo)
        $userClient.Connect()
        $userClient.Disconnect()
        $userClient.Dispose()
    }

    It 'emits a warning but does not move the directory when homeDir drifts' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-other'
        }

        Invoke-UserReconciliation `
            -SshClient       $Script:SshClient `
            -VmName          $Script:VmName `
            -User            $user `
            -WarningVariable warnings

        Invoke-SshQuery 'test -d /home/infra-t-user && echo exists || echo absent' |
            Should -Be 'exists'
        Invoke-SshQuery 'test -d /home/infra-t-other && echo exists || echo absent' |
            Should -Be 'absent'
        $warnings | Should -Match 'homeDir has drifted'
    }
}

# ---------------------------------------------------------------------------
# Invoke-SudoersReconciliation
# ---------------------------------------------------------------------------

Describe 'Invoke-SudoersReconciliation' {

    BeforeEach {
        & bash -c 'useradd -m -s /bin/bash infra-t-user 2>/dev/null' | Out-Null
    }

    AfterEach {
        & bash -c @'
rm -f /etc/sudoers.d/infra-t-user
userdel -r infra-t-user 2>/dev/null
'@  | Out-Null
    }

    It 'writes sudoers rules when none exist' {
        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @('infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls')
        }

        Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery 'sudo cat /etc/sudoers.d/infra-t-user' |
            Should -Match 'NOPASSWD'
    }

    It 'is idempotent when rules already match' {
        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @('infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls')
        }

        Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        { Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user
        } | Should -Not -Throw
    }

    It 'updates rules when they drift' {
        & bash -c @'
echo 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls' \
    | sudo tee /etc/sudoers.d/infra-t-user > /dev/null
sudo chmod 0440 /etc/sudoers.d/infra-t-user
'@  | Out-Null

        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @('infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/id')
        }

        Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        $content = Invoke-SshQuery 'sudo cat /etc/sudoers.d/infra-t-user'
        $content | Should -Match '/usr/bin/id'
        $content | Should -Not -Match '/usr/bin/ls'
    }

    It 'leaves the live file untouched when visudo rejects an invalid rule' {
        # Write a known-good file first so we can verify it is not overwritten.
        & bash -c @'
echo 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls' \
    | sudo tee /etc/sudoers.d/infra-t-user > /dev/null
sudo chmod 0440 /etc/sudoers.d/infra-t-user
'@  | Out-Null

        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @('THIS IS NOT VALID SUDOERS SYNTAX !!!')
        }

        # The function must throw rather than silently apply the bad rule.
        { Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user
        } | Should -Throw

        # The live file must still contain the original valid rule.
        Invoke-SshQuery 'sudo cat /etc/sudoers.d/infra-t-user' |
            Should -Match '/usr/bin/ls'
    }

    It 'removes the sudoers file when rules are emptied' {
        & bash -c @'
echo 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls' \
    | sudo tee /etc/sudoers.d/infra-t-user > /dev/null
sudo chmod 0440 /etc/sudoers.d/infra-t-user
'@  | Out-Null

        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery 'sudo test -f /etc/sudoers.d/infra-t-user && echo exists || echo absent' |
            Should -Be 'absent'
    }
}

# ---------------------------------------------------------------------------
# Invoke-VmUserRemove
# ---------------------------------------------------------------------------

Describe 'Invoke-VmUserRemove' {

    AfterEach {
        & bash -c @'
userdel -r infra-t-user  2>/dev/null
userdel -r infra-t-user2 2>/dev/null
groupdel  infra-t-group  2>/dev/null
rm -f /etc/sudoers.d/infra-t-user
'@  | Out-Null
    }

    It 'removes the sudoers file for a declared user' {
        & bash -c @'
useradd -m -s /bin/bash infra-t-user
echo "infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/id" \
    > /etc/sudoers.d/infra-t-user
chmod 0440 /etc/sudoers.d/infra-t-user
'@  | Out-Null

        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user'))

        Invoke-SshQuery 'test -f /etc/sudoers.d/infra-t-user && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'does not throw when the sudoers file is already absent' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        { Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user'))
        } | Should -Not -Throw
    }

    It 'removes the user account' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user'))

        Invoke-SshQuery 'id infra-t-user 2>/dev/null && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'removes the home directory together with the account' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user'))

        Invoke-SshQuery 'test -d /home/infra-t-user && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'does not throw when the user is already absent' {
        { Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user'))
        } | Should -Not -Throw
    }

    It 'removes all declared users in a single call' {
        & bash -c @'
useradd -m -s /bin/bash infra-t-user
useradd -m -s /bin/bash infra-t-user2
'@  | Out-Null

        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user', 'infra-t-user2'))

        Invoke-SshQuery 'id infra-t-user  2>/dev/null && echo exists || echo absent' |
            Should -Be 'absent'
        Invoke-SshQuery 'id infra-t-user2 2>/dev/null && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'removes a declared group after all users are gone' {
        & bash -c @'
groupadd infra-t-group
useradd -m -s /bin/bash -g infra-t-group infra-t-user
'@  | Out-Null

        $group = [PSCustomObject] @{ groupName = 'infra-t-group' }
        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user') -Groups @($group))

        Invoke-SshQuery 'getent group infra-t-group >/dev/null 2>&1 && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'does not throw when the declared group is already absent' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        $group = [PSCustomObject] @{ groupName = 'infra-t-group' }
        { Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-RemoveEntry @('infra-t-user') -Groups @($group))
        } | Should -Not -Throw
    }

    It 'warns and skips a declared group that still has members outside this config' {
        & bash -c @'
groupadd infra-t-group
useradd -m -s /bin/bash infra-t-user
useradd -m -s /bin/bash infra-t-user2
usermod -aG infra-t-group infra-t-user2
'@  | Out-Null

        $group = [PSCustomObject] @{ groupName = 'infra-t-group' }
        Invoke-VmUserRemove `
            -SshClient       $Script:SshClient `
            -VmName          $Script:VmName `
            -Entry           (New-RemoveEntry @('infra-t-user') -Groups @($group)) `
            -WarningVariable warnings

        Invoke-SshQuery 'getent group infra-t-group >/dev/null 2>&1 && echo exists || echo absent' |
            Should -Be 'exists'
        $warnings | Should -Match 'still has members'
    }
}
