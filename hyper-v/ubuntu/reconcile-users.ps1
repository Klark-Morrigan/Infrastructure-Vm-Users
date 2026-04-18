<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    create-users.ps1 after Infrastructure.Common and common.ps1 are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-UserReconciliation
#   Ensures a single OS user exists on the remote host with the correct shell
#   and supplementary group membership.
#
#   Create path: useradd -m -d -s [-g] [-G] username
#   Update path: usermod -s -G username (replaces full supplementary list)
#
#   homeDir is intentionally not reconciled on existing users: moving a home
#   directory risks data loss and is left as a manual operation.
# ---------------------------------------------------------------------------

function Invoke-UserReconciliation {
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
    $shell    = $User.shell
    $homeDir  = $User.homeDir

    # groups and password are optional in the config schema - guard with
    # Get-Member so objects without these properties do not throw under
    # StrictMode. NOTE: do not use the if/else expression form here - see
    # reconcile-sudoers.ps1 for the reason (empty @() collapses to $null
    # in a pipeline expression).
    $userMembers = (Get-Member -InputObject $User -MemberType NoteProperty).Name
    # @() normalises PS 5.1 single-element JSON unwrapping to an array.
    if ($userMembers -contains 'groups') {
        $groups = @($User.groups)
    } else {
        $groups = @()
    }
    $hasPassword = $userMembers -contains 'password'

    # 'id' exits 0 if the user exists, non-zero otherwise.
    $idResult = Invoke-SshCommand `
        -SshClient $SshClient `
        -Command   "id '$username'" `
        -ErrorAction Stop

    if ($idResult.ExitStatus -ne 0) {
        # -------------------------------------------------------------------
        # User does not exist - create with useradd.
        #   -m : create home directory if it does not exist
        #   -d : home directory path
        #   -s : login shell
        #   -g : primary group - only passed when a group with the same name
        #        as the user already exists (e.g. declared in the groups
        #        config). Without -g, useradd auto-creates the primary group;
        #        if that group already exists the command fails.
        #   -G : supplementary groups (omitted when list is empty to avoid
        #        an error on an empty group argument)
        # -------------------------------------------------------------------

        # On Linux the convention is to name the primary group after the user.
        $primaryGroupName = $username

        $primaryGroupResult = Invoke-SshCommand `
            -SshClient $SshClient `
            -Command   "getent group '$primaryGroupName'" `
            -ErrorAction Stop

        $cmd = "sudo useradd -m -d '$homeDir' -s '$shell'"
        if ($primaryGroupResult.ExitStatus -eq 0) {
            # Primary group pre-exists - adopt it explicitly.
            $cmd += " -g '$primaryGroupName'"
        } # else: primary group absent - useradd creates it automatically.
        
        if ($groups.Count -gt 0) {
            $cmd += " -G '$($groups -join ',')'"
        }
        $cmd += " '$username'"

        $r = Invoke-SshCommand `
            -SshClient $SshClient `
            -Command   $cmd `
            -ErrorAction Stop

        if ($r.ExitStatus -ne 0) {
            throw "[$VmName] useradd failed for '$username': $($r.Error)"
        }

        Write-Host "[$VmName] user '$username': created" -ForegroundColor Green
    }
    else {
        # -------------------------------------------------------------------
        # User exists - reconcile shell and supplementary groups.
        # -------------------------------------------------------------------

        # getent passwd is preferred over parsing /etc/passwd because it also
        # handles LDAP/NIS accounts. Read the full entry in one SSH round
        # trip so both shell (field 7) and homeDir (field 6) can be checked.
        $passwdResult = Invoke-SshCommand `
            -SshClient $SshClient `
            -Command   "getent passwd '$username'" `
            -ErrorAction Stop

        # If the command fails or returns unexpected output, default to empty
        # string - the comparisons below will treat this as drift and act
        # accordingly (same as the existing behaviour for a failed getent).
        $passwdFields   = ($passwdResult.Output -join '').Trim() -split ':'
        $currentShell   = if ($passwdFields.Count -ge 7) { $passwdFields[6] } else { '' }
        $currentHomeDir = if ($passwdFields.Count -ge 7) { $passwdFields[5] } else { '' }

        # id -Gn returns all groups including the primary group (same name as
        # username on Ubuntu). Strip it to isolate supplementary groups, then
        # sort for a stable string comparison.
        $gnResult = Invoke-SshCommand `
            -SshClient $SshClient `
            -Command   "id -Gn '$username'" `
            -ErrorAction Stop

        $currentGroups = @(
            ($gnResult.Output -join '').Trim() -split '\s+' |
            Where-Object { $_ -ne $username } |
            Sort-Object
        )
        $desiredGroups = @($groups | Sort-Object)

        $shellDrifted  = $currentShell -ne $shell
        # Join sorted arrays as comma strings for a simple equality check
        # that handles empty arrays correctly in PS 5.1.
        $groupsDrifted = ($currentGroups -join ',') -ne ($desiredGroups -join ',')

        # homeDir is intentionally not reconciled - moving a home directory
        # risks data loss (owned files stay at the old path). Warn so the
        # operator knows the VM and config disagree rather than silently
        # leaving them out of sync.
        if ($currentHomeDir -ne $homeDir) {
            Write-Warning ("[$VmName] user '$username': homeDir has drifted " +
                "(current: '$currentHomeDir', desired: '$homeDir'). " +
                "Moving a home directory risks data loss - update manually.")
        }

        if ($shellDrifted -or $groupsDrifted) {
            # usermod -G replaces the full supplementary group list.
            # An empty string removes all supplementary groups.
            $groupArg  = $groups -join ','
            $updateCmd = "sudo usermod -s '$shell' -G '$groupArg' '$username'"

            $r = Invoke-SshCommand `
                -SshClient $SshClient `
                -Command   $updateCmd `
                -ErrorAction Stop

            if ($r.ExitStatus -ne 0) {
                throw "[$VmName] usermod failed for '$username': $($r.Error)"
            }

            $changes = @()
            if ($shellDrifted) {
                $changes += "shell: '$currentShell' -> '$shell'"
            }
            if ($groupsDrifted) {
                $changes += "groups: [$($currentGroups -join ', ')] -> [$($desiredGroups -join ', ')]"
            }

            Write-Host "[$VmName] user '$username': updated ($($changes -join '; '))" `
                -ForegroundColor Yellow
        }
        else {
            Write-Host "[$VmName] user '$username': ok" -ForegroundColor Green
        }
    }

    # -----------------------------------------------------------------------
    # Password - always set when present in config, regardless of whether
    # the user was just created or already existed.
    #
    # Comparison against the stored hash is not possible (Unix stores a
    # one-way hash, not the plaintext), so overwriting on every run is the
    # only safe approach. This vault entry is the authoritative source;
    # consuming repos read from here.
    #
    # The password is piped via stdin so it does not appear in the SSH
    # command's argument list (visible in ps aux on the remote host).
    # It must not appear in console output or error messages - only
    # vmName and username are safe to log.
    # -----------------------------------------------------------------------
    if ($hasPassword) {
        $r = Invoke-SshCommand `
            -SshClient $SshClient `
            -Command   "echo '${username}:$($User.password)' | sudo chpasswd" `
            -ErrorAction Stop

        if ($r.ExitStatus -ne 0) {
            throw "[$VmName] chpasswd failed for '$username': $($r.Error)"
        }
    }
}
