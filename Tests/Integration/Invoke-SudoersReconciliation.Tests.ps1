# Integration tests for Invoke-SudoersReconciliation against a real Linux
# SSH session. See Initialize-SshEnvironment.ps1 for environment details and isolation notes.

BeforeAll {
    . "$PSScriptRoot\Initialize-SshEnvironment.ps1"
}

AfterAll {
    & bash -c 'rm -f /etc/sudoers.d/infra-t-user; userdel -r infra-t-user 2>/dev/null' |
        Out-Null
    . "$PSScriptRoot\Remove-SshEnvironment.ps1"
}

Describe 'Invoke-SudoersReconciliation' {

    BeforeEach {
        # Ensure the test user exists so sudoers operations have a real subject.
        & bash -c 'useradd -m -s /bin/bash infra-t-user 2>/dev/null' | Out-Null
    }

    AfterEach {
        & bash -c 'rm -f /etc/sudoers.d/infra-t-user; userdel -r infra-t-user 2>/dev/null' |
            Out-Null
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

        $content = Invoke-SshQuery 'sudo cat /etc/sudoers.d/infra-t-user'
        $content | Should -Match 'NOPASSWD'
    }

    It 'is idempotent when rules already match' {
        $rule = 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls'
        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @($rule)
        }

        Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user

        # Second call - must not throw and file content must be unchanged.
        { Invoke-SudoersReconciliation `
            -SshClient $Script:SshClient `
            -VmName    $Script:VmName `
            -User      $user
        } | Should -Not -Throw
    }

    It 'updates rules when they drift' {
        # Write initial rules directly.
        & bash -c "echo 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls' | sudo tee /etc/sudoers.d/infra-t-user > /dev/null && sudo chmod 0440 /etc/sudoers.d/infra-t-user" |
            Out-Null

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

    It 'removes the sudoers file when rules are emptied' {
        & bash -c "echo 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls' | sudo tee /etc/sudoers.d/infra-t-user > /dev/null && sudo chmod 0440 /etc/sudoers.d/infra-t-user" |
            Out-Null

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
