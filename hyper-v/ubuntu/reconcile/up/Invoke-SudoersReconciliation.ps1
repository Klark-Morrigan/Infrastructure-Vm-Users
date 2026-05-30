<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    create-users.ps1 after PowerShell.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-SudoersReconciliation
#   Ensures /etc/sudoers.d/{username} matches the desired rules for a user.
#
#   Each user gets its own file under /etc/sudoers.d so edits are isolated
#   per user. The write pipeline is:
#     1. Base64-encode content (preserves wildcards, slashes, parentheses)
#     2. Write to a temp file via base64 decode
#     3. chmod 0440
#     4. visudo -c -f to validate syntax
#     5. mv to the live path only if validation passed
#
#   The live file is never touched if validation fails, so a bad rule cannot
#   lock out sudo. The temp file is always cleaned up on failure.
# ---------------------------------------------------------------------------

function Invoke-SudoersReconciliation {
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

    # sudoersRules is optional in the config schema - guard the property
    # before accessing it. NOTE: do not use the if/else expression form here.
    # An empty @() in a pipeline expression collapses to $null, causing
    # .Count to throw under StrictMode. Separate assignments preserve the
    # typed empty array.
    $userMembers = $User.PSObject.Properties.Name
    # @() ensures an array type regardless of element count.
    if ($userMembers -contains 'sudoersRules') {
        $desiredRules = @($User.sudoersRules)
    } else {
        $desiredRules = @()
    }
    $sudoersPath  = "/etc/sudoers.d/$username"
    $tmpPath      = "/tmp/.sudoers_tmp_$username"

    # Read current rules; treat an absent file as empty.
    $existsResult = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   "sudo test -f '$sudoersPath' && echo exists || echo absent" `
        -ErrorAction Stop

    $fileExists   = ($existsResult.Output -join '').Trim() -eq 'exists'
    $currentRules = @()

    if ($fileExists) {
        $catResult = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "sudo cat '$sudoersPath'" `
            -ErrorAction Stop

        # Normalise to a clean string array: trim each line, drop blank lines
        # that may result from a trailing newline.
        $currentRules = @(
            ($catResult.Output -join "`n") -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ -ne '' }
        )
    }

    if ($desiredRules.Count -eq 0 -and -not $fileExists) {
        # No rules desired, no file present - nothing to do.
        Write-Host "[$VmName] user '$username': sudoers ok" -ForegroundColor Green
    }
    elseif ($desiredRules.Count -eq 0 -and $fileExists) {
        # Rules were removed from config - delete the file.
        $r = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "sudo rm '$sudoersPath'" `
            -ErrorAction Stop

        if ($r.ExitStatus -ne 0) {
            throw "[$VmName] Failed to remove sudoers file for '$username': $($r.Error)"
        }

        Write-Host "[$VmName] user '$username': sudoers removed" -ForegroundColor Yellow
    }
    else {
        # Compare current vs desired. Order is preserved: the file is written
        # in the same order as the config array so that rule precedence matches
        # the author's intent.
        $rulesDrifted = ($currentRules -join "`n") -ne ($desiredRules -join "`n")

        if (-not $rulesDrifted) {
            Write-Host "[$VmName] user '$username': sudoers ok" -ForegroundColor Green
        }
        else {
            # Build file content: one rule per line, trailing newline.
            # Base64-encode so that special characters in rules (wildcards,
            # slashes, parentheses) survive the SSH command string unmodified.
            $content = ($desiredRules -join "`n") + "`n"
            $b64     = [Convert]::ToBase64String(
                           [Text.Encoding]::UTF8.GetBytes($content))

            # Write content to a temp file via base64 decode.
            $r = Invoke-SshClientCommand `
                -SshClient $SshClient `
                -Command   "echo '$b64' | base64 -d | sudo tee '$tmpPath' > /dev/null" `
                -ErrorAction Stop

            if ($r.ExitStatus -ne 0) {
                throw "[$VmName] Failed to write temp sudoers for '$username': $($r.Error)"
            }

            # chmod before visudo: some versions warn on world-readable files
            # even during a -c -f check.
            $r = Invoke-SshClientCommand `
                -SshClient $SshClient `
                -Command   "sudo chmod 0440 '$tmpPath'" `
                -ErrorAction Stop

            if ($r.ExitStatus -ne 0) {
                Invoke-SshClientCommand -SshClient $SshClient `
                    -Command "sudo rm -f '$tmpPath'" | Out-Null
                throw "[$VmName] chmod failed on temp sudoers for '$username': $($r.Error)"
            }

            # Validate syntax. If this fails, remove the temp file and abort -
            # the live sudoers file is untouched.
            $r = Invoke-SshClientCommand `
                -SshClient $SshClient `
                -Command   "sudo visudo -c -f '$tmpPath'" `
                -ErrorAction Stop

            if ($r.ExitStatus -ne 0) {
                Invoke-SshClientCommand -SshClient $SshClient `
                    -Command "sudo rm -f '$tmpPath'" | Out-Null
                throw "[$VmName] visudo validation failed for '$username': $($r.Output -join ' ')"
            }

            # Validation passed - move the temp file into place.
            $r = Invoke-SshClientCommand `
                -SshClient $SshClient `
                -Command   "sudo mv '$tmpPath' '$sudoersPath'" `
                -ErrorAction Stop

            if ($r.ExitStatus -ne 0) {
                Invoke-SshClientCommand -SshClient $SshClient `
                    -Command "sudo rm -f '$tmpPath'" | Out-Null
                throw "[$VmName] Failed to install sudoers for '$username': $($r.Error)"
            }

            Write-Host "[$VmName] user '$username': sudoers updated" -ForegroundColor Yellow
        }
    }
}
