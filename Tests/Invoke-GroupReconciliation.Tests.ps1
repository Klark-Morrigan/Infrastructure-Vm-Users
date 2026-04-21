BeforeAll {
    # Stub Invoke-SshClientCommand before dot-sourcing so the function reference
    # resolves at load time. Tests override it per-context with Mock.
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    . "$PSScriptRoot\..\hyper-v\ubuntu\reconcile\reconcile-groups.ps1"

    # Builds a fake Invoke-SshClientCommand result.
    #   -ExitStatus 0  : command succeeded (group found / operation ok)
    #   -ExitStatus 1  : command failed   (group absent / operation error)
    function New-SshResult([int] $ExitStatus, [string[]] $Output = @(), [string] $Err = '') {
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = $Err }
    }

    # Minimal declared group object with only groupName (no gid, no description).
    function New-Group([string] $GroupName) {
        [PSCustomObject]@{ groupName = $GroupName }
    }

    # Declared group with an optional GID.
    function New-GroupWithGid([string] $GroupName, [int] $Gid) {
        [PSCustomObject]@{ groupName = $GroupName; gid = $Gid }
    }

    # Minimal user object for implicit-group detection.
    function New-User([string] $Username, [string[]] $Groups = @()) {
        [PSCustomObject]@{ username = $Username; groups = $Groups }
    }
}

Describe 'Invoke-GroupReconciliation' {

    # ------------------------------------------------------------------
    Context 'declared group - does not exist on host' {
    # ------------------------------------------------------------------

        It 'creates the group when absent' {
            Mock Invoke-SshClientCommand {
                # First call: getent (not found). Second call: groupadd (ok).
                if ($Command -like 'getent*') { New-SshResult 1 }
                else                          { New-SshResult 0 }
            }
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker') -Users @() } |
                Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*groupadd*docker*'
            }
        }

        It 'creates the group with a pinned GID when gid is declared' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*') { New-SshResult 1 }
                else                          { New-SshResult 0 }
            }
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @(New-GroupWithGid 'docker' 999) -Users @()
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*groupadd*-g 999*docker*'
            }
        }

        It 'throws when groupadd fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*') { New-SshResult 1 }
                else                          { New-SshResult 1 @() 'permission denied' }
            }
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker') -Users @() } |
                Should -Throw -ExpectedMessage '*groupadd failed*'
        }

        It 'sets the description via gpasswd -c when description is declared' {
            $group = [PSCustomObject]@{ groupName = 'docker'; description = 'Container runtime' }
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*')   { New-SshResult 1 }
                else                            { New-SshResult 0 }
            }
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @($group) -Users @()
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*gpasswd -c*Container runtime*docker*"
            }
        }

        It 'throws when gpasswd -c fails' {
            $group = [PSCustomObject]@{ groupName = 'docker'; description = 'Container runtime' }
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*')         { New-SshResult 1 }
                elseif ($Command -like '*groupadd*')  { New-SshResult 0 }
                else                                  { New-SshResult 1 @() 'permission denied' }
            }
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @($group) -Users @() } |
                Should -Throw -ExpectedMessage '*gpasswd -c failed*'
        }
    }

    # ------------------------------------------------------------------
    Context 'declared group - already exists on host' {
    # ------------------------------------------------------------------

        It 'does not call groupadd when the group already exists' {
            Mock Invoke-SshClientCommand { New-SshResult 0 @('docker:x:999:') }
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker') -Users @()
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*groupadd*'
            }
        }

        It 'does not throw when the existing GID matches the declared GID' {
            Mock Invoke-SshClientCommand { New-SshResult 0 @('docker:x:999:') }
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @(New-GroupWithGid 'docker' 999) -Users @() } |
                Should -Not -Throw
        }

        It 'throws when the existing GID conflicts with the declared GID' {
            Mock Invoke-SshClientCommand { New-SshResult 0 @('docker:x:123:') }
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @(New-GroupWithGid 'docker' 999) -Users @() } |
                Should -Throw -ExpectedMessage '*GID*'
        }

        It 'does not set description when the group already exists' {
            # KNOWN BEHAVIOUR: gpasswd -c is only called during group creation.
            # If the group is already present on the host, its description in
            # /etc/gshadow is not reconciled. A pre-existing group that has a
            # different (or no) description will not be updated.
            # To change the description of an existing group, run gpasswd -c manually.
            $group = [PSCustomObject]@{ groupName = 'docker'; description = 'Container runtime' }
            Mock Invoke-SshClientCommand { New-SshResult 0 @('docker:x:999:') }
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @($group) -Users @()
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*gpasswd*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'implicit groups (referenced in users but not declared)' {
    # ------------------------------------------------------------------

        It 'creates an implicit group when absent' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*') { New-SshResult 1 }
                else                          { New-SshResult 0 }
            }
            $users = @(New-User 'u-deploy' @('docker'))
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @() -Users $users
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*groupadd*docker*"
            }
        }

        It 'does not create an implicit group that is already declared' {
            # docker is in DeclaredGroups and exists - the implicit pass must
            # not issue a second groupadd for it.
            Mock Invoke-SshClientCommand { New-SshResult 0 @('docker:x:999:') }
            $users = @(New-User 'u-deploy' @('docker'))
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @(New-Group 'docker') -Users $users
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*groupadd*'
            }
        }

        It 'does not call groupadd when the implicit group already exists on host' {
            # Idempotency: if the group is already present on the host (getent
            # succeeds) the implicit pass must not attempt to create it again.
            Mock Invoke-SshClientCommand { New-SshResult 0 @('docker:x:999:') }
            $users = @(New-User 'u-deploy' @('docker'))
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @() -Users $users
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*groupadd*'
            }
        }

        It 'issues only one getent when multiple users reference the same implicit group' {
            # Sort-Object -Unique deduplicates the referenced group list so the
            # same group is not checked (and potentially created) more than once.
            #
            # Each New-User call must be wrapped in parentheses. Without them,
            # PowerShell's command-mode parsing treats the comma as part of the
            # first call's argument list, passing the second function call's name
            # as a string into $Groups - adding a phantom group to the test data.
            Mock Invoke-SshClientCommand { New-SshResult 0 @('docker:x:999:') }
            $users = @(
                (New-User 'u-deploy' @('docker')),
                (New-User 'u-runner' @('docker'))
            )
            Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @() -Users $users
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*getent*docker*"
            }
        }

        It 'throws when implicit groupadd fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -like 'getent*') { New-SshResult 1 }
                else                          { New-SshResult 1 @() 'permission denied' }
            }
            $users = @(New-User 'u-deploy' @('docker'))
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @() -Users $users } |
                Should -Throw -ExpectedMessage '*groupadd failed*'
        }

        It 'skips empty group strings from users with no groups' {
            # A user with no groups produces an empty string in the pipeline;
            # that must not trigger a groupadd for an empty name.
            Mock Invoke-SshClientCommand {}
            $users = @(New-User 'u-deploy' @())
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @() -Users $users } | Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'no groups at all' {
    # ------------------------------------------------------------------

        It 'does nothing when DeclaredGroups is empty and Users have no groups' {
            Mock Invoke-SshClientCommand {}
            { Invoke-GroupReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -DeclaredGroups @() -Users @(New-User 'u-deploy') } |
                Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -Times 0
        }
    }
}
