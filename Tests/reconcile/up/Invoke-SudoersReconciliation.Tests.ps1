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

    . "$PSScriptRoot\..\..\..\hyper-v\ubuntu\reconcile\up\Invoke-SudoersReconciliation.ps1"

    function New-SshResult([int] $ExitStatus, [string[]] $Output = @(), [string] $Err = '') {
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = $Err }
    }

    function New-User([string] $Username, [string[]] $SudoersRules = @()) {
        [PSCustomObject]@{ username = $Username; sudoersRules = $SudoersRules }
    }
}

Describe 'Invoke-SudoersReconciliation' {

    # ------------------------------------------------------------------
    Context 'user object has no sudoersRules property' {
    # ------------------------------------------------------------------

        It 'treats a missing sudoersRules property as an empty list and does nothing when no file present' {
            # ConvertFrom-VmUsersConfigJson does not require sudoersRules, so a
            # user entry without it produces an object with no sudoersRules key.
            # reconcile-sudoers.ps1 uses Get-Member to guard the read, defaulting
            # to an empty array, so the function must behave identically to a
            # user with sudoersRules = @() when no sudoers file is present.
            Mock Invoke-SshClientCommand {
                New-SshResult 0 @('absent')  # test -f: file absent
            }
            $userWithNoRulesProperty = [PSCustomObject]@{ username = 'u-deploy' }
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User $userWithNoRulesProperty } | Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*tee*' -or $Command -like '*mv*' -or $Command -like '*rm*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'no rules desired, no file present' {
    # ------------------------------------------------------------------

        It 'does nothing' {
            Mock Invoke-SshClientCommand {
                # test -f: file absent
                New-SshResult 0 @('absent')
            }
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User (New-User 'u-deploy') } | Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*tee*' -or $Command -like '*mv*' -or $Command -like '*rm*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'no rules desired, file exists' {
    # ------------------------------------------------------------------

        It 'removes the file' {
            Mock Invoke-SshClientCommand {
                if ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                else                            { New-SshResult 0 }
            }
            Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User (New-User 'u-deploy')
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*rm '/etc/sudoers.d/u-deploy'*"
            }
        }

        It 'throws when rm fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                else                            { New-SshResult 1 @() 'permission denied' }
            }
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User (New-User 'u-deploy') } |
                Should -Throw -ExpectedMessage '*Failed to remove sudoers*'
        }
    }

    # ------------------------------------------------------------------
    Context 'rules desired, file absent (first write)' {
    # ------------------------------------------------------------------

        BeforeEach {
            # Sequence: test (absent), tee, chmod, visudo, mv - all succeed.
            $script:_callIndex = 0
            Mock Invoke-SshClientCommand {
                $script:_callIndex++
                switch ($script:_callIndex) {
                    1 { New-SshResult 0 @('absent') }  # test -f
                    2 { New-SshResult 0 }               # tee
                    3 { New-SshResult 0 }               # chmod
                    4 { New-SshResult 0 }               # visudo
                    5 { New-SshResult 0 }               # mv
                }
            }
        }

        It 'writes the file via the full tee/chmod/visudo/mv pipeline' {
            $user = New-User 'u-deploy' @('u-deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl')
            Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*tee*'
            }
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*chmod 0440*'
            }
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*visudo -c -f*'
            }
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like "*mv*sudoers.d/u-deploy*"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'rules desired, file present - no drift' {
    # ------------------------------------------------------------------

        It 'does not rewrite the file when rules are unchanged' {
            $rule = 'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl'
            Mock Invoke-SshClientCommand {
                if ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                else                            { New-SshResult 0 @($rule) }
            }
            Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User (New-User 'u-deploy' @($rule))
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*tee*' -or $Command -like '*mv*'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'rules desired, file present - drift' {
    # ------------------------------------------------------------------

        It 'rewrites the file when rules have changed' {
            Mock Invoke-SshClientCommand {
                if      ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                elseif  ($Command -like '*cat*')     { New-SshResult 0 @('old rule') }
                else                                 { New-SshResult 0 }
            }
            $user = New-User 'u-deploy' @('new rule')
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user } |
                Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -like "*mv*sudoers*"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'rule ordering and normalisation' {
    # ------------------------------------------------------------------

        It 'treats rules in a different order as drift' {
            # Rule precedence depends on order so the comparison is order-sensitive.
            # The same rules in a different sequence must trigger a rewrite so
            # that the on-disk file always matches the config's intended order.
            Mock Invoke-SshClientCommand {
                if      ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                elseif  ($Command -like '*cat*')     {
                    New-SshResult 0 @(
                        'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/journalctl',
                        'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl'
                    )
                }
                else { New-SshResult 0 }
            }
            $rules = @(
                'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl',
                'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/journalctl'
            )
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User (New-User 'u-deploy' $rules) } | Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -like "*mv*sudoers*"
            }
        }

        It 'does not rewrite when existing file has trailing blank lines but content matches' {
            # The cat output is normalised (trimmed, blank lines dropped) before
            # comparison, so a trailing newline in the file must not cause drift.
            $rule = 'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl'
            Mock Invoke-SshClientCommand {
                if      ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                elseif  ($Command -like '*cat*')     { New-SshResult 0 @($rule, '', '  ') }
                else                                 { New-SshResult 0 }
            }
            Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User (New-User 'u-deploy' @($rule))
            Should -Invoke Invoke-SshClientCommand -Times 0 -ParameterFilter {
                $Command -like '*tee*' -or $Command -like '*mv*'
            }
        }

        It 'rewrites the file when test -f fails (pins current behaviour: treat as absent)' {
            # KNOWN BEHAVIOUR: the exit status of "sudo test -f ... && echo exists
            # || echo absent" is not checked. If the SSH command itself fails
            # (e.g. sudo permission denied before the shell gets to run test),
            # Output is empty, $fileExists silently becomes $false, and any
            # desired rules trigger the full write pipeline as if the file were
            # absent. Add an ExitStatus check before reading Output if this
            # silent false-absent ever causes problems in production.
            Mock Invoke-SshClientCommand {
                if      ($Command -like '*test -f*') { New-SshResult 1 }  # SSH fails
                else                                 { New-SshResult 0 }
            }
            $user = New-User 'u-deploy' @('u-deploy ALL=(ALL) NOPASSWD: ALL')
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user } |
                Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -like "*mv*sudoers*"
            }
        }

        It 'rewrites the file when cat fails (pins current behaviour: treat as empty)' {
            # KNOWN BEHAVIOUR: cat exit status is not checked. A failing cat
            # produces an empty $currentRules array, which differs from any
            # non-empty desired rules, so the file is always rewritten silently.
            # If this ever becomes a problem (e.g. cat fails due to permissions
            # on the live file), add an ExitStatus check before the comparison.
            Mock Invoke-SshClientCommand {
                if      ($Command -like '*test -f*') { New-SshResult 0 @('exists') }
                elseif  ($Command -like '*cat*')     { New-SshResult 1 }
                else                                 { New-SshResult 0 }
            }
            $user = New-User 'u-deploy' @('u-deploy ALL=(ALL) NOPASSWD: ALL')
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user } |
                Should -Not -Throw
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                $Command -like "*mv*sudoers*"
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'multiple rules' {
    # ------------------------------------------------------------------

        It 'writes all rules joined by newlines' {
            Mock Invoke-SshClientCommand {
                if      ($Command -like '*test -f*') { New-SshResult 0 @('absent') }
                else                                 { New-SshResult 0 }
            }
            $rules = @(
                'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl',
                'u-deploy ALL=(ALL) NOPASSWD: /usr/bin/journalctl'
            )
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' `
                -User (New-User 'u-deploy' $rules) } | Should -Not -Throw
            # Both rules must appear in the base64-encoded tee command. Verify
            # by decoding the b64 payload from the captured command.
            $script:_teeCommand = $null
            Should -Invoke Invoke-SshClientCommand -ParameterFilter {
                if ($Command -like "*tee*") { $script:_teeCommand = $Command }
                $Command -like "*tee*"
            }
            $b64 = [regex]::Match($script:_teeCommand, "echo '([^']+)'").Groups[1].Value
            $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
            $decoded | Should -Match 'systemctl'
            $decoded | Should -Match 'journalctl'
        }
    }

    # ------------------------------------------------------------------
    Context 'write pipeline failures' {
    # ------------------------------------------------------------------

        It 'throws when tee fails' {
            Mock Invoke-SshClientCommand {
                if ($Command -like '*test -f*') { New-SshResult 0 @('absent') }
                else                            { New-SshResult 1 @() 'no space left' }
            }
            $user = New-User 'u-deploy' @('u-deploy ALL=(ALL) NOPASSWD: ALL')
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user } |
                Should -Throw -ExpectedMessage '*Failed to write temp sudoers*'
        }

        It 'throws and cleans up temp file when chmod fails' {
            $script:_callIndex = 0
            Mock Invoke-SshClientCommand {
                $script:_callIndex++
                switch ($script:_callIndex) {
                    1 { New-SshResult 0 @('absent') }  # test -f
                    2 { New-SshResult 0 }               # tee
                    3 { New-SshResult 1 @() 'denied' }  # chmod fails
                    4 { New-SshResult 0 }               # rm cleanup
                }
            }
            $user = New-User 'u-deploy' @('u-deploy ALL=(ALL) NOPASSWD: ALL')
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user } |
                Should -Throw -ExpectedMessage '*chmod failed*'
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*rm -f*'
            }
        }

        It 'throws and cleans up temp file when visudo fails' {
            $script:_callIndex = 0
            Mock Invoke-SshClientCommand {
                $script:_callIndex++
                switch ($script:_callIndex) {
                    1 { New-SshResult 0 @('absent') }                    # test -f
                    2 { New-SshResult 0 }                                 # tee
                    3 { New-SshResult 0 }                                 # chmod
                    4 { New-SshResult 1 @('syntax error near line 1') }  # visudo fails
                    5 { New-SshResult 0 }                                 # rm cleanup
                }
            }
            $user = New-User 'u-deploy' @('bad rule')
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user } |
                Should -Throw -ExpectedMessage '*visudo validation failed*'
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*rm -f*'
            }
        }

        It 'throws and cleans up temp file when mv fails' {
            $script:_callIndex = 0
            Mock Invoke-SshClientCommand {
                $script:_callIndex++
                switch ($script:_callIndex) {
                    1 { New-SshResult 0 @('absent') }  # test -f
                    2 { New-SshResult 0 }               # tee
                    3 { New-SshResult 0 }               # chmod
                    4 { New-SshResult 0 }               # visudo
                    5 { New-SshResult 1 @() 'denied' }  # mv fails
                    6 { New-SshResult 0 }               # rm cleanup
                }
            }
            $user = New-User 'u-deploy' @('u-deploy ALL=(ALL) NOPASSWD: ALL')
            { Invoke-SudoersReconciliation -SshClient ([PSCustomObject]@{}) -VmName 'node-01' -User $user } |
                Should -Throw -ExpectedMessage '*Failed to install sudoers*'
            Should -Invoke Invoke-SshClientCommand -Times 1 -Exactly -ParameterFilter {
                $Command -like '*rm -f*'
            }
        }
    }
}
