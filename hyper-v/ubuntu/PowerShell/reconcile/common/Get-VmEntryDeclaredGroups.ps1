<#
.NOTES
    Do not run this file directly. It is dot-sourced by create-users.ps1 and
    remove-users.ps1 (consumed by their per-VM reconcile helpers) after
    Common.PowerShell is loaded.
#>

# ---------------------------------------------------------------------------
# Get-VmEntryDeclaredGroups
#   Returns the optional 'groups' array declared on a VmUsersConfig entry, or
#   an empty array when the entry omits it. Both lifecycle directions need the
#   identical guard - the create path must create declared groups before users
#   reference them, the remove path must delete them after users are gone - so
#   the presence check and its array normalisation live here once rather than
#   being copied into each per-VM helper.
# ---------------------------------------------------------------------------

function Get-VmEntryDeclaredGroups {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        # A VM entry object from VmUsersConfig (vmName, users, optional groups).
        [Parameter(Mandatory)]
        [object] $Entry
    )

    # Guard the optional 'groups' property before accessing it. @(...) collects
    # the if-expression output into an array; when 'groups' is absent nothing is
    # emitted and the result is @() rather than $null. The unary comma wraps the
    # array so a single-group entry survives the function-return unroll as a
    # one-element array rather than a bare scalar.
    $entryMembers = $Entry.PSObject.Properties.Name
    return , @(if ($entryMembers -contains 'groups') { $Entry.groups })
}
