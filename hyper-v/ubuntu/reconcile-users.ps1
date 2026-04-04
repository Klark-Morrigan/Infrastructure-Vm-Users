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
#   Create path: useradd -m -d -s [-G] username
#   Update path: usermod -s -G username (replaces full supplementary list)
#
#   homeDir is intentionally not reconciled on existing users: moving a home
#   directory risks data loss and is left as a manual operation.
# ---------------------------------------------------------------------------

function Invoke-UserReconciliation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int] $SessionId,

        [Parameter(Mandatory)]
        [string] $VmName,

        [Parameter(Mandatory)]
        [object] $User
    )

    $username = $User.username
    $shell    = $User.shell
    $homeDir  = $User.homeDir

    # groups is optional in the config schema - guard with Get-Member so that
    # user objects without the property do not throw under StrictMode.
    $userMembers = (Get-Member -InputObject $User -MemberType NoteProperty).Name
    # @() normalises PS 5.1 single-element JSON unwrapping to an array.
    $groups      = if ($userMembers -contains 'groups') { @($User.groups) } else { @() }

    # 'id' exits 0 if the user exists, non-zero otherwise.
    $idResult = Invoke-SSHCommand `
        -SessionId $SessionId `
        -Command   "id '$username'" `
        -ErrorAction Stop

    if ($idResult.ExitStatus -ne 0) {
        # -------------------------------------------------------------------
        # User does not exist - create with useradd.
        #   -m : create home directory if it does not exist
        #   -d : home directory path
        #   -s : login shell
        #   -G : supplementary groups (omitted when list is empty to avoid
        #        an error on an empty group argument)
        # -------------------------------------------------------------------

        $cmd = "sudo useradd -m -d '$homeDir' -s '$shell'"
        if ($groups.Count -gt 0) {
            $cmd += " -G '$($groups -join ',')'"
        }
        $cmd += " '$username'"

        $r = Invoke-SSHCommand `
            -SessionId $SessionId `
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
        # handles LDAP/NIS accounts.
        $shellResult = Invoke-SSHCommand `
            -SessionId $SessionId `
            -Command   "getent passwd '$username' | cut -d: -f7" `
            -ErrorAction Stop

        $currentShell = ($shellResult.Output -join '').Trim()

        # id -Gn returns all groups including the primary group (same name as
        # username on Ubuntu). Strip it to isolate supplementary groups, then
        # sort for a stable string comparison.
        $gnResult = Invoke-SSHCommand `
            -SessionId $SessionId `
            -Command   "id -Gn '$username'" `
            -ErrorAction Stop

        $currentGroups = @(
            ($gnResult.Output -join '').Trim() -split '\s+' |
            Where-Object { $_ -ne $username } |
            Sort-Object
        )
        $desiredGroups = @($groups | Sort-Object)

        $shellDrifted = $currentShell -ne $shell
        # Join sorted arrays as comma strings for a simple equality check
        # that handles empty arrays correctly in PS 5.1.
        $groupsDrifted = ($currentGroups -join ',') -ne ($desiredGroups -join ',')

        if ($shellDrifted -or $groupsDrifted) {
            # usermod -G replaces the full supplementary group list.
            # An empty string removes all supplementary groups.
            $groupArg  = $groups -join ','
            $updateCmd = "sudo usermod -s '$shell' -G '$groupArg' '$username'"

            $r = Invoke-SSHCommand `
                -SessionId $SessionId `
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
}
