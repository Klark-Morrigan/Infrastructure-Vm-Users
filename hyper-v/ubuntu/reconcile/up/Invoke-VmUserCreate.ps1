<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    create-users.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmUserCreate
#   Reconciles all groups, users, and sudoers rules for a single VM over an
#   existing SSH connection. Called once per reachable VM by create-users.ps1.
#   The caller owns the SSH connection lifecycle.
#
#   Sequence:
#     1. Invoke-GroupReconciliation  - declared and implicit groups.
#     2. Invoke-UserReconciliation   - per user: create or update.
#     3. Invoke-SudoersReconciliation - per user: write or remove rules.
#
#   Groups are reconciled once per VM before users because useradd/usermod
#   fail when a referenced group does not yet exist.
# ---------------------------------------------------------------------------

function Invoke-VmUserCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The VM entry object from VmUsersConfig (vmName, users, optional groups).
        [Parameter(Mandatory)]
        [object] $Entry
    )

    $users = @($Entry.users)

    # Get-Member guards the optional 'groups' property without triggering
    # StrictMode on a missing key.
    $entryMembers   = (Get-Member -InputObject $Entry -MemberType NoteProperty).Name
    $declaredGroups = if ($entryMembers -contains 'groups') {
        @($Entry.groups)
    } else {
        @()
    }

    # Step 1: groups must exist before users reference them in useradd/usermod.
    Invoke-GroupReconciliation `
        -SshClient      $SshClient `
        -VmName         $VmName `
        -DeclaredGroups $declaredGroups `
        -Users          $users

    foreach ($user in $users) {
        # Step 2: ensure the user exists with the correct shell and groups.
        Invoke-UserReconciliation `
            -SshClient $SshClient `
            -VmName    $VmName `
            -User      $user

        # Step 3: ensure the sudoers file matches the desired rules.
        Invoke-SudoersReconciliation `
            -SshClient $SshClient `
            -VmName    $VmName `
            -User      $user
    }
}
