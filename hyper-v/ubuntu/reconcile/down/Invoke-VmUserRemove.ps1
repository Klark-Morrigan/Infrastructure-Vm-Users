<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    remove-users.ps1 after PowerShell.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmUserRemove
#   Removes all users, their sudoers files, and declared groups for a single
#   VM over an existing SSH connection. Called once per reachable VM by
#   remove-users.ps1. The caller owns the SSH connection lifecycle.
#
#   Sequence:
#     1. Remove-VmSudoers  - per user: revoke elevated access first.
#     2. Remove-VmUsers    - per user: delete account and home directory.
#     3. Remove-VmGroups   - once per VM: delete declared groups after all
#                            users are gone so groupdel finds no members.
# ---------------------------------------------------------------------------

function Invoke-VmUserRemove {
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

    # Guards the optional 'groups' property before accessing it. @(...) collects
    # the if-expression output into an array; when 'groups' is absent nothing
    # is emitted and the result is @() rather than $null.
    $entryMembers   = $Entry.PSObject.Properties.Name
    $declaredGroups = @(if ($entryMembers -contains 'groups') { $Entry.groups })

    foreach ($user in $users) {
        Write-Host "[$VmName] Removing user '$($user.username)' ..." -ForegroundColor Cyan

        # Step 1: revoke sudo access before the account is deleted.
        Remove-VmSudoers `
            -SshClient $SshClient `
            -VmName    $VmName `
            -User      $user

        # Step 2: delete the account and home directory.
        Remove-VmUsers `
            -SshClient $SshClient `
            -VmName    $VmName `
            -User      $user
    }

    # Step 3: remove declared groups after all users are gone. Implicit groups
    # (named after the username) were already removed by userdel in step 2.
    Remove-VmGroups `
        -SshClient      $SshClient `
        -VmName         $VmName `
        -DeclaredGroups $declaredGroups
}
