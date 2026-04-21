# Integration tests for Invoke-UserReconciliation against a real Linux SSH
# session. See _TestSetup.ps1 for environment details and isolation notes.

BeforeAll {
    . "$PSScriptRoot\_TestSetup.ps1"
}

AfterAll {
    if ($null -ne $Script:SshClient) {
        if ($Script:SshClient.IsConnected) { $Script:SshClient.Disconnect() }
        $Script:SshClient.Dispose()
    }

    & bash -c 'userdel -r infra-t-user 2>/dev/null; groupdel infra-t-group 2>/dev/null' |
        Out-Null
    & bash -c "userdel -r ${Script:AdminUser} 2>/dev/null" | Out-Null
}

Describe 'Invoke-UserReconciliation' {

    BeforeEach {
        # Ensure test group exists so useradd -G does not fail.
        & bash -c 'groupadd infra-t-group 2>/dev/null' | Out-Null
    }

    AfterEach {
        & bash -c 'userdel -r infra-t-user 2>/dev/null; groupdel infra-t-group 2>/dev/null' |
            Out-Null
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

        $shell = Invoke-SshQuery "getent passwd infra-t-user | cut -d: -f7"
        $shell | Should -Be '/bin/bash'
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

        Invoke-SshQuery "id -Gn infra-t-user" | Should -Match 'infra-t-group'
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

        # Second call - must not throw.
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

        $shell = Invoke-SshQuery "getent passwd infra-t-user | cut -d: -f7"
        $shell | Should -Be '/bin/bash'
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

        Invoke-SshQuery "id -Gn infra-t-user" | Should -Match 'infra-t-group'
    }

    It 'sets the password so the user can authenticate via SSH' {
        # Uses a second SSH session as the test user to prove chpasswd ran
        # correctly - the only reliable way to verify a password was set on a
        # real system is to authenticate with it.
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

        # Open a second SSH.NET connection as the test user to prove chpasswd
        # set the password correctly - the only reliable verification is to
        # authenticate with it.
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
            # Desired homeDir differs from the one useradd created above.
            homeDir  = '/home/infra-t-other'
        }

        Invoke-UserReconciliation `
            -SshClient       $Script:SshClient `
            -VmName          $Script:VmName `
            -User            $user `
            -WarningVariable warnings

        # Original directory must still exist - it must not have been moved.
        Invoke-SshQuery 'test -d /home/infra-t-user && echo exists || echo absent' |
            Should -Be 'exists'
        # New path must not have been created.
        Invoke-SshQuery 'test -d /home/infra-t-other && echo exists || echo absent' |
            Should -Be 'absent'
        # Warning must have been emitted identifying the drift.
        $warnings | Should -Match 'homeDir has drifted'
    }
}
