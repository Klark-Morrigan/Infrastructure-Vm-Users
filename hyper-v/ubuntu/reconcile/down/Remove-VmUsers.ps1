<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    remove-users.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Remove-VmUsers
#   Deletes a single OS user account and its home directory from the remote VM.
#   Always called after Remove-VmSudoers so elevated access is revoked first.
#
#   An already-absent user is silently skipped and is not an error.
# ---------------------------------------------------------------------------

function Remove-VmUsers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [object] $User
    )

    $username = $User.username

    # 'id' exits 0 when the user exists, non-zero otherwise.
    $idResult = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "id '$username'" `
        -ErrorAction Stop

    if ($idResult.ExitStatus -ne 0) {
        Write-Host "[$VmName] user '$username': absent - skipping." -ForegroundColor Green
        return
    }

    # -r removes the home directory and mail spool along with the account.
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo userdel -r '$username'" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] userdel failed for '$username': $($r.Error)"
    }

    Write-Host "[$VmName] user '$username': removed." -ForegroundColor Green
}
