BeforeAll {
    function Invoke-SSHCommand { param($SessionId, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\hyper-v\ubuntu\reconcile-users.ps1"

    function New-SshResult([int] $ExitStatus, [string[]] $Output = @(), [string] $Err = '') {
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = $Err }
    }

    function New-User {
        param(
            [string]   $Username,
            [string]   $Shell    = '/bin/bash',
            [string]   $HomeDir  = '/home/u-deploy',
            [string[]] $Groups   = @(),
            # Password is optional - omit the parameter entirely to produce a
            # user object without a 'password' property, mirroring the JSON
            # schema where the field is absent rather than null.
            [string]   $Password
        )
        $obj = [PSCustomObject]@{
            username = $Username
            shell    = $Shell
            homeDir  = $HomeDir
            groups   = $Groups
        }
        if ($PSBoundParameters.ContainsKey('Password')) {
            Add-Member -InputObject $obj -MemberType NoteProperty `
                -Name 'password' -Value $Password
        }
        $obj
    }
}

Describe 'Invoke-UserReconciliation' {

    # ------------------------------------------------------------------
    Context 'user object has no groups property' {
    # ------------------------------------------------------------------

        It 'treats a missing groups property as an empty list during useradd' {
            # groups is optional in the config schema. A user object without
            # the property must not throw under Set-StrictMode -Version Latest.
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 1
                }
                elseif ($Command -like 'getent group*') {
                    New-SshResult 1
                }
                else {
                    New-SshResult 0
                }
            }
            $userWithNoGroupsProperty = [PSCustomObject]@{
                username = 'u-deploy'; shell = '/bin/bash'; homeDir = '/home/u-deploy'
            }
            { Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User $userWithNoGroupsProperty } | Should -Not -Throw
            Should -Invoke Invoke-SSHCommand -Times 0 -ParameterFilter {
                $Command -like '*-G*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user does not exist' {
    # ------------------------------------------------------------------

        It 'calls useradd with -m, -d, -s and the username when the user is absent' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 1
                }
                elseif ($Command -like 'getent group*') {
                    New-SshResult 1
                }
                else {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy')
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*useradd*-m*-d '/home/u-deploy'*-s '/bin/bash'*u-deploy*"
            }
        }

        It 'includes -G when the user has supplementary groups' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 1
                }
                elseif ($Command -like 'getent group*') {
                    New-SshResult 1
                }
                else {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy' @('docker', 'runners'))
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*-G*docker*" -and $Command -like "*-G*runners*"
            }
        }

        It 'omits -G when the user has no supplementary groups' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 1
                }
                elseif ($Command -like 'getent group*') {
                    New-SshResult 1
                }
                else {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy')
            Should -Invoke Invoke-SSHCommand -Times 0 -ParameterFilter {
                $Command -like '*-G*'
            }
        }

        It 'passes -g when a primary group with the same name already exists' {
            # Reproduces the case where the group was declared in the groups
            # config and created before user reconciliation runs.
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 1
                }
                elseif ($Command -like 'getent group*') {
                    New-SshResult 0
                }
                else {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-actions-runner')
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*useradd*-g*u-actions-runner*"
            }
        }

        It 'omits -g when no primary group with the same name exists' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 1
                }
                elseif ($Command -like 'getent group*') {
                    New-SshResult 1
                }
                else {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy')
            Should -Invoke Invoke-SSHCommand -Times 0 -ParameterFilter {
                $Command -like '*useradd* -g *'
            }
        }

        It 'throws when useradd fails' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 1
                }
                elseif ($Command -like 'getent group*') {
                    New-SshResult 1
                }
                else {
                    New-SshResult 1 @() 'permission denied'
                }
            }
            { Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy') } |
                Should -Throw -ExpectedMessage '*useradd failed*'
        }
    }

    # ------------------------------------------------------------------
    Context 'user exists - no drift' {
    # ------------------------------------------------------------------

        It 'emits a Write-Warning but does not run usermod when homeDir has drifted' {
            # homeDir is intentionally not reconciled - moving it risks data
            # loss. A Write-Warning must be emitted so the operator knows the
            # VM and config disagree; usermod must never be called.
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent passwd*') {
                    # VM has the conventional homeDir; config requests /srv/custom-home.
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy')
                }
            }
            Mock Write-Warning {}
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/srv/custom-home' @())
            Should -Invoke Write-Warning -Times 1 -ParameterFilter {
                $Message -like '*homeDir has drifted*'
            }
            Should -Invoke Invoke-SSHCommand -Times 0 -ParameterFilter {
                $Command -like '*usermod*'
            }
        }

        It 'does not call usermod or Write-Warning when shell, groups and homeDir are correct' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy docker')
                }
            }
            Mock Write-Warning {}
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy' @('docker'))
            Should -Invoke Invoke-SSHCommand -Times 0 -ParameterFilter {
                $Command -like '*usermod*'
            }
            Should -Invoke Write-Warning -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'user exists - shell drift' {
    # ------------------------------------------------------------------

        It 'calls usermod when the shell has changed' {
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/sh')
                }
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy')
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash')
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*usermod*-s '/bin/bash'*"
            }
        }

        It 'throws when usermod fails' {
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/sh')
                }
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy')
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 1 @() 'permission denied'
                }
            }
            { Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash') } |
                Should -Throw -ExpectedMessage '*usermod failed*'
        }
    }

    # ------------------------------------------------------------------
    Context 'user exists - group drift' {
    # ------------------------------------------------------------------

        It 'calls usermod with the new group name when supplementary groups have changed' {
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                # Current groups: only primary. Desired: docker added.
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy')
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy' @('docker'))
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*usermod*-G*docker*"
            }
        }

        It 'calls usermod with empty -G when all supplementary groups are removed' {
            # usermod -G '' removes all supplementary groups. An empty desired
            # list must not be skipped - it is a deliberate removal.
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                # Current: user is in docker. Desired: no supplementary groups.
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy docker')
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy' @())
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*usermod*-G ''*"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user exists - group order' {
    # ------------------------------------------------------------------

        It 'does not call usermod when groups match but are listed in a different order on host' {
            # The comparison sorts both sides before comparing, so the on-disk
            # order returned by id -Gn must not be treated as drift.
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                # Host has groups in reverse order relative to the desired list.
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy runners docker')
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy' @('docker', 'runners'))
            Should -Invoke Invoke-SSHCommand -Times 0 -ParameterFilter {
                $Command -like '*usermod*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'probe command failures' {
    # ------------------------------------------------------------------

        It 'calls usermod when getent passwd fails (pins current behaviour: treat as empty shell)' {
            # KNOWN BEHAVIOUR: getent passwd exit status is not checked. A
            # failing getent (e.g. LDAP timeout, permission error) produces
            # empty strings for both $currentShell and $currentHomeDir.
            # The empty shell always differs from any non-empty desired shell,
            # triggering a spurious usermod. The empty homeDir always differs
            # from any non-empty desired homeDir, triggering a spurious
            # Write-Warning. Add ExitStatus checks before both comparisons
            # if this becomes a problem.
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 1  # fails - empty output
                }
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy')
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash')
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*usermod*'
            }
        }

        It 'calls usermod when id -Gn fails (pins current behaviour: treat as no groups)' {
            # KNOWN BEHAVIOUR: id -Gn exit status is not checked. A failing
            # id -Gn produces an empty $currentGroups array. If desired groups
            # are non-empty this always appears as drift, triggering a spurious
            # usermod. Add an ExitStatus check before the groups comparison if
            # this becomes a problem.
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                if ($Command -like 'id -Gn*') {
                    New-SshResult 1  # fails - empty output
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy' @('docker'))
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*usermod*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'user exists - shell and group drift together' {
    # ------------------------------------------------------------------

        It 'issues a single usermod for both shell and group changes' {
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") {
                    New-SshResult 0
                }
                if ($Command -like 'getent*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/sh')
                }
                if ($Command -like 'id -Gn*') {
                    New-SshResult 0 @('u-deploy')
                }
                if ($Command -like '*usermod*') {
                    New-SshResult 0
                }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' '/bin/bash' '/home/u-deploy' @('docker'))
            # Both changes in one usermod call - not two separate calls.
            Should -Invoke Invoke-SSHCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*usermod*-s '/bin/bash'*" -and $Command -like "*-G*docker*"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'password' {
    # ------------------------------------------------------------------

        It 'calls chpasswd after creating a new user when password is in config' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') { New-SshResult 1 }
                elseif ($Command -like 'getent group*') { New-SshResult 1 }
                else { New-SshResult 0 }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' -Password 's3cret')
            # Verify the stdin pipe pattern: password must not appear as a
            # chpasswd argument (visible in ps aux on the remote host).
            Should -Invoke Invoke-SSHCommand -Times 1 -ParameterFilter {
                $Command -like "echo*u-deploy*s3cret*|*chpasswd*"
            }
        }

        It 'calls chpasswd after updating an existing user when password is in config' {
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") { New-SshResult 0 }
                elseif ($Command -like 'getent passwd*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                elseif ($Command -like 'id -Gn*') { New-SshResult 0 @('u-deploy') }
                else { New-SshResult 0 }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' -Password 's3cret')
            # Same stdin pipe check as the create path - chpasswd must not
            # receive the password as a command-line argument.
            Should -Invoke Invoke-SSHCommand -Times 1 -ParameterFilter {
                $Command -like "echo*u-deploy*s3cret*|*chpasswd*"
            }
        }

        It 'does not call chpasswd when password is absent from config' {
            Mock Invoke-SSHCommand {
                if ($Command -like "id '*'") { New-SshResult 0 }
                elseif ($Command -like 'getent passwd*') {
                    New-SshResult 0 @('u-deploy:x:1001:1001::/home/u-deploy:/bin/bash')
                }
                elseif ($Command -like 'id -Gn*') { New-SshResult 0 @('u-deploy') }
                else { New-SshResult 0 }
            }
            Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy')
            Should -Invoke Invoke-SSHCommand -Times 0 -ParameterFilter {
                $Command -like '*chpasswd*'
            }
        }

        It 'throws when chpasswd fails' {
            Mock Invoke-SSHCommand {
                if ($Command -like 'id*') { New-SshResult 1 }
                elseif ($Command -like 'getent group*') { New-SshResult 1 }
                elseif ($Command -like '*chpasswd*') {
                    New-SshResult 1 @() 'Authentication token manipulation error'
                }
                else { New-SshResult 0 }
            }
            { Invoke-UserReconciliation -SessionId 1 -VmName 'node-01' `
                -User (New-User 'u-deploy' -Password 's3cret') } |
                Should -Throw -ExpectedMessage '*chpasswd failed*'
        }
    }
}
