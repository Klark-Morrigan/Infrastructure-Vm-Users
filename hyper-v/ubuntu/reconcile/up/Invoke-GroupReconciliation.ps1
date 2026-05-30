<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    create-users.ps1 after PowerShell.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-GroupReconciliation
#   Ensures all groups for a VM exist on the remote host with the correct GID.
#
#   Two passes are made:
#   1. Declared groups - from the 'groups' config array. Support optional GID
#      pinning and description. GID conflicts throw; silent renumbering would
#      break ownership of files on disk.
#   2. Implicit groups - referenced in users[].groups but absent from the
#      declared list. Created with no GID pinning as a convenience fallback
#      for simple configs.
#
#   Must be called before Invoke-UserReconciliation: useradd/usermod fail if
#   a referenced group does not yet exist.
# ---------------------------------------------------------------------------

function Invoke-GroupReconciliation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # Pre-extracted from entry.groups. Pass @() when the property is absent.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $DeclaredGroups,

        # Full users array - used to collect implicitly referenced group names.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Users
    )

    # Track declared names so the implicit pass skips them.
    $declaredGroupNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    # -------------------------------------------------------------------
    # Pass 1: explicitly declared groups
    # -------------------------------------------------------------------

    foreach ($group in $DeclaredGroups) {
        $groupName = $group.groupName

        # gid is optional - guard the property before accessing it.
        $groupMembers = $group.PSObject.Properties.Name
        $gid          = if ($groupMembers -contains 'gid') { $group.gid } else { $null }

        $null = $declaredGroupNames.Add($groupName)

        $getentResult = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "getent group '$groupName'" `
            -ErrorAction Stop

        if ($getentResult.ExitStatus -ne 0) {
            # Group absent - create it, optionally with a pinned GID.
            $createCmd = 'sudo groupadd'
            if ($null -ne $gid -and "$gid" -ne '') {
                $createCmd += " -g $gid"
            }
            $createCmd += " '$groupName'"

            $r = Invoke-SshClientCommand `
                -SshClient $SshClient `
                -Command   $createCmd `
                -ErrorAction Stop

            if ($r.ExitStatus -ne 0) {
                throw "[$VmName] groupadd failed for '$groupName': $($r.Error)"
            }

            Write-Host "[$VmName] group '$groupName': created" -ForegroundColor Green
        }
        else {
            # Group exists - check GID if one was declared.
            if ($null -ne $gid -and "$gid" -ne '') {
                # getent group output format: name:password:gid:members
                $currentGid = (($getentResult.Output -join '').Trim() -split ':')[2]

                if ($currentGid -ne "$gid") {
                    throw (
                        "[$VmName] group '$groupName' exists with GID $currentGid " +
                        "but config requires GID $gid. Correct manually: " +
                        "sudo groupmod -g $gid '$groupName' " +
                        "(verify no files are owned by GID $currentGid first: " +
                        "find / -gid $currentGid 2>/dev/null)"
                    )
                }
            }

            Write-Host "[$VmName] group '$groupName': ok" -ForegroundColor Green
        }
    }

    # -------------------------------------------------------------------
    # Pass 2: implicit groups referenced in users[].groups
    # -------------------------------------------------------------------

    $allReferencedGroups = @(
        $Users |
        ForEach-Object { @($_.groups) } |
        Where-Object   { $_ -ne '' } |
        Sort-Object -Unique
    )

    foreach ($groupName in $allReferencedGroups) {
        if ($declaredGroupNames.Contains($groupName)) {
            continue  # Already handled in pass 1.
        }

        $getentResult = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "getent group '$groupName'" `
            -ErrorAction Stop

        if ($getentResult.ExitStatus -ne 0) {
            $r = Invoke-SshClientCommand `
                -SshClient $SshClient `
                -Command   "sudo groupadd '$groupName'" `
                -ErrorAction Stop

            if ($r.ExitStatus -ne 0) {
                throw "[$VmName] groupadd failed for '$groupName': $($r.Error)"
            }

            Write-Host "[$VmName] group '$groupName': created (implicit)" `
                -ForegroundColor Green
        }
        else {
            Write-Host "[$VmName] group '$groupName': ok" -ForegroundColor Green
        }
    }
}
