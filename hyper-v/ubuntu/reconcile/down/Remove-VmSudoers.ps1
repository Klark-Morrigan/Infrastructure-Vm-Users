<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    remove-users.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Remove-VmSudoers
#   Removes /etc/sudoers.d/{username} for a single user if the file exists.
#   Always called before Remove-VmUsers so elevated access is revoked before
#   the account is deleted.
#
#   An already-absent file is silently skipped and is not an error.
# ---------------------------------------------------------------------------

function Remove-VmSudoers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [object] $User
    )

    $username    = $User.username
    $sudoersPath = "/etc/sudoers.d/$username"

    $existsResult = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo test -f '$sudoersPath' && echo exists || echo absent" `
        -ErrorAction Stop

    $fileExists = ($existsResult.Output -join '').Trim() -eq 'exists'

    if (-not $fileExists) {
        Write-Host "[$VmName] user '$username': sudoers absent - skipping." `
            -ForegroundColor Green
        return
    }

    $r = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo rm '$sudoersPath'" `
        -ErrorAction Stop

    if ($r.ExitStatus -ne 0) {
        throw "[$VmName] Failed to remove sudoers file for '$username': $($r.Error)"
    }

    Write-Host "[$VmName] user '$username': sudoers removed." -ForegroundColor Green
}
