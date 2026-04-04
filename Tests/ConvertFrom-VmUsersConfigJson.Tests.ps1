BeforeAll {
    # Stub Assert-RequiredProperties before dot-sourcing common.ps1 so the
    # function exists when common.ps1 is loaded. The real implementation lives
    # in Infrastructure.Common, which is not required in the test environment.
    function Assert-RequiredProperties {
        param($Object, $Properties, $Context)
    }

    . "$PSScriptRoot\..\hyper-v\ubuntu\common.ps1"

    # Builds a minimal valid VM entry with all required fields populated.
    # Individual tests override specific fields as needed.
    function New-ValidEntryJson([string] $vmName = 'node-01') {
        @"
{
    "vmName": "$vmName",
    "users": [
        {
            "username": "u-deploy",
            "shell":    "/bin/bash",
            "homeDir":  "/home/u-deploy"
        }
    ]
}
"@
    }

    # Wraps one or more entry JSON strings into a JSON array string.
    function Wrap-Array([string[]] $items) {
        '[' + ($items -join ', ') + ']'
    }
}

Describe 'ConvertFrom-VmUsersConfigJson' {

    # ------------------------------------------------------------------
    Context 'valid input' {
    # ------------------------------------------------------------------

        It 'returns a VM entry for a single-element JSON array' {
            $result = @(ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson)))
            $result | Should -HaveCount 1
            $result[0].vmName | Should -Be 'node-01'
        }

        It 'normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)' {
            # ConvertFrom-Json in PS 5.1 unwraps a single-element JSON array
            # into a bare PSCustomObject. @() in the function normalises this
            # so callers always receive an array.
            $result = @(ConvertFrom-VmUsersConfigJson -Json (New-ValidEntryJson))
            $result | Should -HaveCount 1
        }

        It 'returns all entries for a multi-VM JSON array' {
            $json = Wrap-Array (New-ValidEntryJson 'node-01'), (New-ValidEntryJson 'node-02')
            $result = @(ConvertFrom-VmUsersConfigJson -Json $json)
            $result | Should -HaveCount 2
            $result[0].vmName | Should -Be 'node-01'
            $result[1].vmName | Should -Be 'node-02'
        }

        It 'accepts an entry with a groups array' {
            $json = @'
[{
    "vmName": "node-01",
    "groups": [{ "groupName": "docker" }],
    "users":  [{ "username": "u-deploy", "shell": "/bin/bash", "homeDir": "/home/u-deploy" }]
}]
'@
            { @(ConvertFrom-VmUsersConfigJson -Json $json) } | Should -Not -Throw
        }

        It 'accepts an entry without a groups property' {
            # groups is optional - omitting it entirely must not throw.
            { @(ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson))) } |
                Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid JSON' {
    # ------------------------------------------------------------------

        It 'throws "Invalid JSON" for a malformed JSON string' {
            { ConvertFrom-VmUsersConfigJson -Json '{not valid json' } |
                Should -Throw -ExpectedMessage '*Invalid JSON*'
        }

        It 'throws on an empty string' {
            # PS 5.1 rejects an empty [string] parameter before the function
            # body runs, so the error comes from parameter binding rather than
            # the "Invalid JSON" catch block. The function still throws - this
            # test pins that boundary behaviour.
            { ConvertFrom-VmUsersConfigJson -Json '' } |
                Should -Throw -ExpectedMessage '*empty string*'
        }
    }

    # ------------------------------------------------------------------
    Context 'empty config' {
    # ------------------------------------------------------------------

        It 'throws when the JSON array is empty' {
            { ConvertFrom-VmUsersConfigJson -Json '[]' } |
                Should -Throw -ExpectedMessage '*non-empty JSON array*'
        }
    }

    # ------------------------------------------------------------------
    Context 'VM-level field validation' {
    # ------------------------------------------------------------------

        It 'calls Assert-RequiredProperties for vmName and users on each VM' {
            Mock Assert-RequiredProperties {}
            $json = Wrap-Array (New-ValidEntryJson 'node-01'), (New-ValidEntryJson 'node-02')
            @(ConvertFrom-VmUsersConfigJson -Json $json)
            # Once per VM entry (vmName + users check), once per user (username,
            # shell, homeDir check) - 2 VMs x 2 calls each = 4 total.
            Should -Invoke Assert-RequiredProperties -Times 4 -Exactly
        }

        It 'passes vmName and users in the Properties for the VM-level call' {
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson)))
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'vmName' -and $Properties -contains 'users'
            }
        }

        It 'throws when Assert-RequiredProperties throws for a VM entry' {
            Mock Assert-RequiredProperties { throw "VM entry is missing required property 'vmName'." }
            { ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson)) } |
                Should -Throw -ExpectedMessage "*missing required property*"
        }

        It 'throws when the users array is empty' {
            $json = '[{ "vmName": "node-01", "users": [] }]'
            { ConvertFrom-VmUsersConfigJson -Json $json } |
                Should -Throw -ExpectedMessage "*at least one user*"
        }
    }

    # ------------------------------------------------------------------
    Context 'user-level field validation' {
    # ------------------------------------------------------------------

        It 'calls Assert-RequiredProperties once per user' {
            Mock Assert-RequiredProperties {}
            $json = @'
[{
    "vmName": "node-01",
    "users": [
        { "username": "u-deploy", "shell": "/bin/bash", "homeDir": "/home/u-deploy" },
        { "username": "u-runner", "shell": "/bin/bash", "homeDir": "/home/u-runner" }
    ]
}]
'@
            @(ConvertFrom-VmUsersConfigJson -Json $json)
            # 1 VM-level call + 2 user-level calls = 3 total.
            Should -Invoke Assert-RequiredProperties -Times 3 -Exactly
        }

        It 'passes username, shell, and homeDir in the Properties for user-level calls' {
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson)))
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'username' -and
                $Properties -contains 'shell'    -and
                $Properties -contains 'homeDir'
            }
        }

        It 'includes the vmName in the Context for user-level calls' {
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson 'node-01')))
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'username' -and $Context -like "*node-01*"
            }
        }

        It 'throws when Assert-RequiredProperties throws for a user' {
            $script:_vmCallDone = $false
            Mock Assert-RequiredProperties {
                # Let the VM-level call pass; fail on the user-level call.
                if ($script:_vmCallDone) {
                    throw "User in VM 'node-01' is missing required property 'shell'."
                }
                $script:_vmCallDone = $true
            }
            { ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson)) } |
                Should -Throw -ExpectedMessage "*missing required property 'shell'*"
        }
    }

    # ------------------------------------------------------------------
    Context 'group-level field validation' {
    # ------------------------------------------------------------------

        It 'calls Assert-RequiredProperties once per group' {
            Mock Assert-RequiredProperties {}
            $json = @'
[{
    "vmName": "node-01",
    "groups": [
        { "groupName": "docker" },
        { "groupName": "runners" }
    ],
    "users": [{ "username": "u-deploy", "shell": "/bin/bash", "homeDir": "/home/u-deploy" }]
}]
'@
            @(ConvertFrom-VmUsersConfigJson -Json $json)
            # 1 VM-level + 2 group-level + 1 user-level = 4 total.
            Should -Invoke Assert-RequiredProperties -Times 4 -Exactly
        }

        It 'passes groupName in the Properties for group-level calls' {
            Mock Assert-RequiredProperties {}
            $json = @'
[{
    "vmName": "node-01",
    "groups": [{ "groupName": "docker" }],
    "users":  [{ "username": "u-deploy", "shell": "/bin/bash", "homeDir": "/home/u-deploy" }]
}]
'@
            @(ConvertFrom-VmUsersConfigJson -Json $json)
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'groupName'
            }
        }

        It 'includes the vmName in the Context for group-level calls' {
            Mock Assert-RequiredProperties {}
            $json = @'
[{
    "vmName": "node-01",
    "groups": [{ "groupName": "docker" }],
    "users":  [{ "username": "u-deploy", "shell": "/bin/bash", "homeDir": "/home/u-deploy" }]
}]
'@
            @(ConvertFrom-VmUsersConfigJson -Json $json)
            Should -Invoke Assert-RequiredProperties -Times 1 -Exactly -ParameterFilter {
                $Properties -contains 'groupName' -and $Context -like "*node-01*"
            }
        }

        It 'skips group validation when groups property is absent' {
            Mock Assert-RequiredProperties {}
            @(ConvertFrom-VmUsersConfigJson -Json (Wrap-Array (New-ValidEntryJson)))
            # Only the VM-level and user-level calls - no group calls.
            Should -Invoke Assert-RequiredProperties -Times 0 -Exactly -ParameterFilter {
                $Properties -contains 'groupName'
            }
        }
    }
}
