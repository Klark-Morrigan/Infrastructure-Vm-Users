<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    remove-users.ps1 after PowerShell.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Remove-VmGroups
#   Deletes declared groups from the remote VM after users have been removed.
#   Only groups listed in the config's 'groups' array are touched - implicit
#   groups (auto-created by useradd, named after the user) are removed
#   automatically by userdel and do not need explicit handling here.
#
#   A group with remaining members is warned and skipped: another user outside
#   this config may still belong to it, and groupdel would fail anyway.
#   An already-absent group is silently skipped and is not an error.
# ---------------------------------------------------------------------------

function Remove-VmGroups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # Declared groups from the config entry's 'groups' array.
        # Pass @() when the property is absent - nothing to remove.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $DeclaredGroups
    )

    foreach ($group in $DeclaredGroups) {
        $groupName = $group.groupName

        $getentResult = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "getent group '$groupName'" `
            -ErrorAction Stop

        if ($getentResult.ExitStatus -ne 0) {
            Write-Host "[$VmName] group '$groupName': absent - skipping." `
                -ForegroundColor Green
            continue
        }

        # getent group format: name:password:gid:member1,member2,...
        # Field 4 (index 3) is the comma-separated member list; empty means
        # no members.
        $members = (($getentResult.Output -join '').Trim() -split ':')[3]

        if ($members -ne '') {
            Write-Warning ("[$VmName] group '$groupName': still has members " +
                "($members) - skipping.")
            continue
        }

        $r = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "sudo groupdel '$groupName'" `
            -ErrorAction Stop

        if ($r.ExitStatus -ne 0) {
            throw "[$VmName] groupdel failed for '$groupName': $($r.Error)"
        }

        Write-Host "[$VmName] group '$groupName': removed." -ForegroundColor Green
    }
}
