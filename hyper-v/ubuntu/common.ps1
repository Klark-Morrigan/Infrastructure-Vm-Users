<#
.SYNOPSIS
    Shared helpers dot-sourced by setup-secrets.ps1 and create-users.ps1.

.NOTES
    Do not run this file directly. It is intended to be dot-sourced:
        . "$PSScriptRoot\common.ps1"
    Infrastructure.Common must be imported before dot-sourcing this file.
#>

# ---------------------------------------------------------------------------
# ConvertFrom-VmUsersConfigJson
#   Parses a VmUsersConfig JSON string and validates its structure.
#   Throws a descriptive error on any problem.
#
#   Outputs each validated VM entry object to the pipeline. Callers must
#   wrap the call in @() to collect the result as an array:
#       $entries = @(ConvertFrom-VmUsersConfigJson -Json $json)
#
#   Centralised here so the required-field list has a single source of
#   truth - update it once when the config schema changes.
# ---------------------------------------------------------------------------

function ConvertFrom-VmUsersConfigJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Json
    )

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON: $_"
    }

    # In PS 5.1, ConvertFrom-Json unwraps single-element JSON arrays into a
    # bare PSCustomObject. @() normalises the result to an array in both cases.
    $entries = @($parsed)

    if ($entries.Count -eq 0) {
        throw "Config must be a non-empty JSON array of VM user entries."
    }

    $userRequiredFields = @('username', 'shell', 'homeDir')

    # Assert-RequiredProperties is provided by Infrastructure.Common.
    # It handles the PS 5.1-compatible Get-Member loop and IsNullOrWhiteSpace
    # cast so this file does not need to duplicate that logic.
    foreach ($entry in $entries) {
        # Assert-RequiredProperties handles arrays correctly (count-based check)
        # so users can be included alongside the scalar vmName.
        Assert-RequiredProperties `
            -Object     $entry `
            -Properties @('vmName', 'users') `
            -Context    "VM entry"

        # Validate the optional groups array when present.
        # 'groups' is not in the required properties list above because omitting
        # it is valid - it means no groups need to be explicitly declared for
        # this VM. Get-Member is used to check presence without triggering
        # StrictMode on a missing property.
        $entryMembers = (Get-Member -InputObject $entry -MemberType NoteProperty).Name
        if ($entryMembers -contains 'groups') {
            # In PS 5.1 a single-element array in JSON is unwrapped to a bare
            # object by ConvertFrom-Json. @() normalises to array.
            $groups = @($entry.groups)
            foreach ($group in $groups) {
                Assert-RequiredProperties `
                    -Object     $group `
                    -Properties @('groupName') `
                    -Context    "Group in VM '$($entry.vmName)'"
            }
        }

        # @() normalises the PS 5.1 single-element unwrap (see groups above).
        $users = @($entry.users)

        if ($users.Count -eq 0) {
            throw "VM entry '$($entry.vmName)' must have at least one user."
        }

        foreach ($user in $users) {
            Assert-RequiredProperties `
                -Object     $user `
                -Properties $userRequiredFields `
                -Context    "User in VM '$($entry.vmName)'"
        }

        Write-Output $entry
    }
}
