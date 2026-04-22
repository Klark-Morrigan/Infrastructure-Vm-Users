# Integration tests for Invoke-GroupReconciliation against a real Linux SSH
# session. See Initialize-SshEnvironment.ps1 for environment details and isolation notes.

BeforeAll {
    . "$PSScriptRoot\Initialize-SshEnvironment.ps1"
}

AfterAll {
    & bash -c 'groupdel infra-t-group 2>/dev/null; groupdel infra-t-implicit 2>/dev/null' |
        Out-Null
    . "$PSScriptRoot\Remove-SshEnvironment.ps1"
}

Describe 'Invoke-GroupReconciliation' {

    AfterEach {
        & bash -c 'groupdel infra-t-group 2>/dev/null; groupdel infra-t-implicit 2>/dev/null' |
            Out-Null
    }

    It 'creates a declared group' {
        $group = [PSCustomObject]@{ groupName = 'infra-t-group' }

        Invoke-GroupReconciliation `
            -SshClient      $Script:SshClient `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()

        Invoke-SshQuery "getent group infra-t-group" | Should -Match 'infra-t-group'
    }

    It 'is idempotent for a group that already exists' {
        # Create the group first, then reconcile again - should not throw.
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

        # getent output: name:x:gid:members
        $gid = (Invoke-SshQuery "getent group infra-t-group") -split ':' | Select-Object -Index 2
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

        Invoke-SshQuery "getent group infra-t-implicit" | Should -Match 'infra-t-implicit'
    }
}
