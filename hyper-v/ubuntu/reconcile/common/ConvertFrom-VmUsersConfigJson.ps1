<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    setup-secrets.ps1 and create-users.ps1 after Infrastructure.Common
    is loaded.
#>

# ---------------------------------------------------------------------------
# ConvertFrom-VmUsersConfigJson
#   Parses a VmUsersConfig JSON string and validates its structure.
#   Throws a descriptive error on any problem.
#
#   Outputs each validated VM entry object to the pipeline. Callers must
#   use ConvertTo-Array to collect the result as an array:
#       $entries = ConvertTo-Array (ConvertFrom-VmUsersConfigJson -Json $json)
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

    $entries = ConvertTo-Array $parsed

    if ($entries.Count -eq 0) {
        throw "Config must be a non-empty JSON array of VM user entries."
    }

    $userRequiredFields = @('username', 'shell', 'homeDir')

    # Assert-RequiredProperties is provided by Infrastructure.Common.
    # It handles the IsNullOrWhiteSpace cast so this file does not need
    # to duplicate that logic.
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
        $entryMembers = $entry.PSObject.Properties.Name
        if ($entryMembers -contains 'groups') {
            $groups = ConvertTo-Array $entry.groups
            foreach ($group in $groups) {
                Assert-RequiredProperties `
                    -Object     $group `
                    -Properties @('groupName') `
                    -Context    "Group in VM '$($entry.vmName)'"
            }
        }

        $users = ConvertTo-Array $entry.users

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
