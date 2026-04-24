# Integration tests for Invoke-VmUserRemove against a real Linux SSH session.
# Covers all three operations it delegates to: Remove-VmSudoers,
# Remove-VmUsers, and Remove-VmGroups.
# See Initialize-SshEnvironment.ps1 for environment details.

BeforeAll {
    . "$PSScriptRoot\Initialize-SshEnvironment.ps1"

    $src = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'hyper-v', 'ubuntu', 'reconcile')
    . ([IO.Path]::Combine($src, 'down', 'Remove-VmGroups.ps1'))
    . ([IO.Path]::Combine($src, 'down', 'Remove-VmSudoers.ps1'))
    . ([IO.Path]::Combine($src, 'down', 'Remove-VmUsers.ps1'))
    . ([IO.Path]::Combine($src, 'down', 'Invoke-VmUserRemove.ps1'))
}

AfterAll {
    & bash -c @'
userdel -r infra-t-user  2>/dev/null
userdel -r infra-t-user2 2>/dev/null
groupdel  infra-t-group  2>/dev/null
'@  | Out-Null
    . "$PSScriptRoot\Remove-SshEnvironment.ps1"
}

# Helper: build a minimal entry object matching VmUsersConfig structure.
# $Groups is the optional 'groups' array (declared groups); omit to leave
# the property absent so Invoke-VmUserRemove exercises the no-groups branch.
function New-Entry {
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

Describe 'Invoke-VmUserRemove' {

    AfterEach {
        & bash -c @'
userdel -r infra-t-user  2>/dev/null
userdel -r infra-t-user2 2>/dev/null
groupdel  infra-t-group  2>/dev/null
'@  | Out-Null
    }

    # ------------------------------------------------------------------
    # Remove-VmSudoers
    # ------------------------------------------------------------------

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
            -Entry     (New-Entry @('infra-t-user'))

        Invoke-SshQuery 'test -f /etc/sudoers.d/infra-t-user && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'does not throw when the sudoers file is already absent' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        # No sudoers file written - removal must be a no-op.
        { Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-Entry @('infra-t-user'))
        } | Should -Not -Throw
    }

    # ------------------------------------------------------------------
    # Remove-VmUsers
    # ------------------------------------------------------------------

    It 'removes the user account' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-Entry @('infra-t-user'))

        # 'id' exits non-zero when the account is gone.
        Invoke-SshQuery 'id infra-t-user 2>/dev/null && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'removes the home directory together with the account' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-Entry @('infra-t-user'))

        Invoke-SshQuery 'test -d /home/infra-t-user && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'does not throw when the user is already absent' {
        # No useradd - account never existed.
        { Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-Entry @('infra-t-user'))
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
            -Entry     (New-Entry @('infra-t-user', 'infra-t-user2'))

        Invoke-SshQuery 'id infra-t-user  2>/dev/null && echo exists || echo absent' |
            Should -Be 'absent'
        Invoke-SshQuery 'id infra-t-user2 2>/dev/null && echo exists || echo absent' |
            Should -Be 'absent'
    }

    # ------------------------------------------------------------------
    # Remove-VmGroups
    # ------------------------------------------------------------------

    It 'removes a declared group after all users are gone' {
        & bash -c @'
groupadd infra-t-group
useradd -m -s /bin/bash -g infra-t-group infra-t-user
'@  | Out-Null

        $group = [PSCustomObject] @{ groupName = 'infra-t-group' }
        Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-Entry @('infra-t-user') -Groups @($group))

        # getent exits non-zero when the group is gone.
        Invoke-SshQuery 'getent group infra-t-group 2>/dev/null && echo exists || echo absent' |
            Should -Be 'absent'
    }

    It 'does not throw when the declared group is already absent' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        $group = [PSCustomObject] @{ groupName = 'infra-t-group' }
        { Invoke-VmUserRemove `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -Entry     (New-Entry @('infra-t-user') -Groups @($group))
        } | Should -Not -Throw
    }

    It 'warns and skips a declared group that still has members outside this config' {
        # infra-t-group has infra-t-user2 as an extra member that is not
        # listed in the removal entry, so groupdel cannot safely run.
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
            -Entry           (New-Entry @('infra-t-user') -Groups @($group)) `
            -WarningVariable warnings

        # Group must still exist - it was not force-deleted.
        Invoke-SshQuery 'getent group infra-t-group 2>/dev/null && echo exists || echo absent' |
            Should -Be 'exists'
        $warnings | Should -Match 'still has members'
    }
}
