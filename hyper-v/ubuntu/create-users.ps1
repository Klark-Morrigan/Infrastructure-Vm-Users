<#
.SYNOPSIS
    Reconciles OS users on Ubuntu VMs against the desired state in the
    VmUsers vault.

.DESCRIPTION
    Reads VM connection details (IP, admin credentials) from the existing
    VmProvisioner vault and the desired user list from the VmUsers vault.
    Joins the two by vmName, then for each reachable VM reconciles OS users
    and sudoers rules via SSH.

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable.
    - Posh-SSH is installed, or an internet connection is available so this
      script can install it from PSGallery automatically.

.EXAMPLE
    .\create-users.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Infrastructure.Secrets must already be installed by setup-secrets.ps1.
# We import here rather than install - missing module means setup has not
# been run yet, which is a prerequisite, not a condition we should silently
# fix.
Import-Module Infrastructure.Secrets                    -ErrorAction Stop
Import-Module Microsoft.PowerShell.SecretManagement    -ErrorAction Stop

# Posh-SSH provides New-SSHSession / Invoke-SSHCommand for password-based
# SSH from Windows PowerShell. The provisioner does not set up key-based
# auth, so we authenticate with the admin username/password from the vault.
# Unlike Infrastructure.Secrets (one-time setup), Posh-SSH is a runtime
# dependency - auto-install keeps the operational workflow self-contained.
$poshSsh = Get-Module -ListAvailable -Name Posh-SSH |
    Sort-Object Version -Descending | Select-Object -First 1

if (-not $poshSsh) {
    Write-Host "Installing Posh-SSH from PSGallery ..." -ForegroundColor Cyan
    Install-Module Posh-SSH -Scope CurrentUser -Force
}
Import-Module Posh-SSH -Force -ErrorAction Stop

. "$PSScriptRoot\common.ps1"

# ---------------------------------------------------------------------------
# 1. Read VmProvisionerConfig from the VmProvisioner vault
#    Fields used: vmName, ipAddress, username, password (admin SSH creds).
#    All other provisioner fields (cpuCount, ramGB, etc.) are irrelevant here
#    and intentionally ignored.
# ---------------------------------------------------------------------------

Write-Host "Reading VmProvisionerConfig from VmProvisioner vault ..." `
    -ForegroundColor Cyan

$provisionerJson = Get-Secret `
    -Vault VmProvisioner `
    -Name  VmProvisionerConfig `
    -AsPlainText `
    -ErrorAction Stop

# @() normalises PS 5.1 single-element JSON unwrapping to a consistent array.
$provisionerVms = @($provisionerJson | ConvertFrom-Json)

Write-Host "OK - $($provisionerVms.Count) VM(s) in VmProvisionerConfig." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Read VmUsersConfig from the VmUsers vault
#    ConvertFrom-VmUsersConfigJson validates structure and emits each entry
#    to the pipeline; @() collects all of them.
# ---------------------------------------------------------------------------

Write-Host "Reading VmUsersConfig from VmUsers vault ..." `
    -ForegroundColor Cyan

$usersJson = Get-Secret `
    -Vault VmUsers `
    -Name  VmUsersConfig `
    -AsPlainText `
    -ErrorAction Stop

$userEntries = @(ConvertFrom-VmUsersConfigJson -Json $usersJson)

Write-Host "OK - $($userEntries.Count) VM entry/entries in VmUsersConfig." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Join by vmName
#    Build a hashtable index from the provisioner list for O(1) lookup, then
#    match each users entry. Unmatched entries are warned and skipped - they
#    likely reference a VM not yet provisioned or contain a typo in vmName.
# ---------------------------------------------------------------------------

$provisionerIndex = @{}
foreach ($vm in $provisionerVms) {
    $provisionerIndex[$vm.vmName] = $vm
}

# Each element is a hashtable pairing the users entry with its provisioner
# counterpart so downstream phases have both in one place.
$targets = [System.Collections.Generic.List[hashtable]]::new()

foreach ($entry in $userEntries) {
    $name = $entry.vmName

    if (-not $provisionerIndex.ContainsKey($name)) {
        Write-Warning "[$name] No matching entry in VmProvisionerConfig - skipping."
        continue
    }

    $targets.Add(@{
        Entry       = $entry
        Provisioner = $provisionerIndex[$name]
    })
}

Write-Host "Matched $($targets.Count) of $($userEntries.Count) VM entry/entries." `
    -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 4. Ping each matched VM
#    Test-Connection -Quiet returns $true/$false without throwing.
#    -Count 1 keeps it fast; a single echo reply is enough to confirm the VM
#    is up and the host can reach it.
# ---------------------------------------------------------------------------

$reachable = [System.Collections.Generic.List[hashtable]]::new()

foreach ($t in $targets) {
    $name = $t.Entry.vmName
    $ip   = $t.Provisioner.ipAddress

    Write-Host "[$name] Pinging $ip ..." -ForegroundColor Cyan

    if (Test-Connection -ComputerName $ip -Count 1 -Quiet) {
        Write-Host "[$name] Reachable." -ForegroundColor Green
        $reachable.Add($t)
    }
    else {
        Write-Warning "[$name] Unreachable at $ip - skipping."
    }
}

Write-Host "$($reachable.Count) of $($targets.Count) matched VM(s) reachable." `
    -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 5. User reconciliation via SSH
#    For each reachable VM, open one SSH session and process all users in it.
#    The session is always closed in the finally block, even if a user
#    operation throws.
#
#    Security note: -AcceptKey auto-trusts the host key on first connection
#    without verifying a fingerprint. This is acceptable on an internal
#    Hyper-V network with statically provisioned IPs. Do NOT use -AcceptKey
#    against untrusted or shared networks.
#
#    Sudo assumption: cloud-init adds the provisioned admin user to the
#    sudo group with NOPASSWD via /etc/sudoers.d/90-cloud-init-users (Ubuntu
#    default). If your image disables passwordless sudo, add -sudo-password
#    handling before the useradd/usermod calls.
# ---------------------------------------------------------------------------

foreach ($t in $reachable) {
    $name  = $t.Entry.vmName
    $users = @($t.Entry.users)
    $prov  = $t.Provisioner

    Write-Host ""
    Write-Host "[$name] Connecting to $($prov.ipAddress) as '$($prov.username)' ..." `
        -ForegroundColor Cyan

    $credential = [PSCredential]::new(
        $prov.username,
        ($prov.password | ConvertTo-SecureString -AsPlainText -Force)
    )

    $session = New-SSHSession `
        -ComputerName $prov.ipAddress `
        -Credential   $credential `
        -AcceptKey `
        -ErrorAction  Stop

    try {
        foreach ($user in $users) {
            $username = $user.username
            $shell    = $user.shell
            $homeDir  = $user.homeDir
            # @() normalises PS 5.1 single-element JSON unwrapping to array.
            $groups   = @($user.groups)

            # -----------------------------------------------------------
            # 5a. Check if the user already exists
            #     'id' exits 0 if the user exists, non-zero otherwise.
            # -----------------------------------------------------------

            $idResult = Invoke-SSHCommand `
                -SessionId $session.SessionId `
                -Command   "id '$username'" `
                -ErrorAction Stop

            if ($idResult.ExitStatus -ne 0) {
                # -------------------------------------------------------
                # User does not exist - create with useradd.
                #   -m : create home directory if it does not exist
                #   -d : home directory path
                #   -s : login shell
                #   -G : supplementary groups (omitted when list is empty
                #        to avoid an error on an empty group argument)
                # -------------------------------------------------------

                $cmd = "sudo useradd -m -d '$homeDir' -s '$shell'"
                if ($groups.Count -gt 0) {
                    $cmd += " -G '$($groups -join ',')'"
                }
                $cmd += " '$username'"

                $r = Invoke-SSHCommand `
                    -SessionId $session.SessionId `
                    -Command   $cmd `
                    -ErrorAction Stop

                if ($r.ExitStatus -ne 0) {
                    throw "[$name] useradd failed for '$username': $($r.Error)"
                }

                Write-Host "[$name] user '$username': created" `
                    -ForegroundColor Green
            }
            else {
                # -------------------------------------------------------
                # User exists - reconcile shell and supplementary groups.
                # homeDir is not reconciled: moving a home directory risks
                # data loss and is intentionally left as a manual step.
                # -------------------------------------------------------

                # getent passwd is preferred over parsing /etc/passwd
                # because it also handles LDAP/NIS accounts.
                $shellResult = Invoke-SSHCommand `
                    -SessionId $session.SessionId `
                    -Command   "getent passwd '$username' | cut -d: -f7" `
                    -ErrorAction Stop

                $currentShell = ($shellResult.Output -join '').Trim()

                # id -Gn returns all groups including the primary group
                # (which has the same name as the username on Ubuntu).
                # Strip the primary group to isolate supplementary groups,
                # then sort for a stable string comparison.
                $gnResult = Invoke-SSHCommand `
                    -SessionId $session.SessionId `
                    -Command   "id -Gn '$username'" `
                    -ErrorAction Stop

                $currentGroups = @(
                    ($gnResult.Output -join '').Trim() -split '\s+' |
                    Where-Object { $_ -ne $username } |
                    Sort-Object
                )
                $desiredGroups = @($groups | Sort-Object)

                $shellDrifted  = $currentShell -ne $shell
                # Join sorted arrays as comma strings for a simple equality
                # check that handles empty arrays correctly in PS 5.1.
                $groupsDrifted = ($currentGroups -join ',') -ne ($desiredGroups -join ',')

                if ($shellDrifted -or $groupsDrifted) {
                    # usermod -G replaces the full supplementary group list.
                    # An empty string removes all supplementary groups.
                    $groupArg  = $groups -join ','
                    $updateCmd = "sudo usermod -s '$shell' -G '$groupArg' '$username'"

                    $r = Invoke-SSHCommand `
                        -SessionId $session.SessionId `
                        -Command   $updateCmd `
                        -ErrorAction Stop

                    if ($r.ExitStatus -ne 0) {
                        throw "[$name] usermod failed for '$username': $($r.Error)"
                    }

                    $changes = @()
                    if ($shellDrifted) {
                        $changes += "shell: '$currentShell' -> '$shell'"
                    }
                    if ($groupsDrifted) {
                        $changes += "groups: [$($currentGroups -join ', ')] -> [$($desiredGroups -join ', ')]"
                    }

                    Write-Host "[$name] user '$username': updated ($($changes -join '; '))" `
                        -ForegroundColor Yellow
                }
                else {
                    Write-Host "[$name] user '$username': ok" -ForegroundColor Green
                }
            }

            # -----------------------------------------------------------
            # 5b. Sudoers reconciliation
            #     Each user gets its own /etc/sudoers.d/{username} file so
            #     edits are isolated per user. We write to a temp file,
            #     chmod, and validate with visudo before moving it into
            #     place. The live file is never touched if the new content
            #     fails validation, so a broken rule cannot lock out sudo.
            # -----------------------------------------------------------

            # @() normalises PS 5.1 single-element JSON unwrapping to array.
            $desiredRules = @($user.sudoersRules)
            $sudoersPath  = "/etc/sudoers.d/$username"
            $tmpPath      = "/tmp/.sudoers_tmp_$username"

            # Read current rules; treat an absent file as empty.
            $existsResult = Invoke-SSHCommand `
                -SessionId $session.SessionId `
                -Command   "sudo test -f '$sudoersPath' && echo exists || echo absent" `
                -ErrorAction Stop

            $fileExists   = ($existsResult.Output -join '').Trim() -eq 'exists'
            $currentRules = @()

            if ($fileExists) {
                $catResult = Invoke-SSHCommand `
                    -SessionId $session.SessionId `
                    -Command   "sudo cat '$sudoersPath'" `
                    -ErrorAction Stop

                # Normalise to a clean string array: trim each line, drop
                # blank lines that may result from a trailing newline.
                $currentRules = @(
                    ($catResult.Output -join "`n") -split "`n" |
                    ForEach-Object { $_.Trim() } |
                    Where-Object   { $_ -ne '' }
                )
            }

            if ($desiredRules.Count -eq 0 -and -not $fileExists) {
                # No rules desired, no file present - nothing to do.
                Write-Host "[$name] user '$username': sudoers ok" `
                    -ForegroundColor Green
            }
            elseif ($desiredRules.Count -eq 0 -and $fileExists) {
                # Rules were removed from config - delete the file.
                $r = Invoke-SSHCommand `
                    -SessionId $session.SessionId `
                    -Command   "sudo rm '$sudoersPath'" `
                    -ErrorAction Stop

                if ($r.ExitStatus -ne 0) {
                    throw "[$name] Failed to remove sudoers file for '$username': $($r.Error)"
                }

                Write-Host "[$name] user '$username': sudoers removed" `
                    -ForegroundColor Yellow
            }
            else {
                # Compare current vs desired. Order is preserved: the file
                # is written in the same order as the config array so that
                # rule precedence matches the author's intent.
                $rulesDrifted = ($currentRules -join "`n") -ne ($desiredRules -join "`n")

                if (-not $rulesDrifted) {
                    Write-Host "[$name] user '$username': sudoers ok" `
                        -ForegroundColor Green
                }
                else {
                    # Build file content: one rule per line, trailing newline.
                    # Base64-encode so that special characters in rules
                    # (wildcards, slashes, parentheses) survive the SSH
                    # command string unmodified.
                    $content = ($desiredRules -join "`n") + "`n"
                    $b64     = [Convert]::ToBase64String(
                                   [Text.Encoding]::UTF8.GetBytes($content))

                    # Write content to a temp file via base64 decode.
                    $r = Invoke-SSHCommand `
                        -SessionId $session.SessionId `
                        -Command   "echo '$b64' | base64 -d | sudo tee '$tmpPath' > /dev/null" `
                        -ErrorAction Stop

                    if ($r.ExitStatus -ne 0) {
                        throw "[$name] Failed to write temp sudoers for '$username': $($r.Error)"
                    }

                    # chmod before visudo: some versions warn on world-readable
                    # files even during a -c -f check.
                    $r = Invoke-SSHCommand `
                        -SessionId $session.SessionId `
                        -Command   "sudo chmod 0440 '$tmpPath'" `
                        -ErrorAction Stop

                    if ($r.ExitStatus -ne 0) {
                        Invoke-SSHCommand -SessionId $session.SessionId `
                            -Command "sudo rm -f '$tmpPath'" | Out-Null
                        throw "[$name] chmod failed on temp sudoers for '$username': $($r.Error)"
                    }

                    # Validate syntax. If this fails, remove the temp file and
                    # abort - the live sudoers file is untouched.
                    $r = Invoke-SSHCommand `
                        -SessionId $session.SessionId `
                        -Command   "sudo visudo -c -f '$tmpPath'" `
                        -ErrorAction Stop

                    if ($r.ExitStatus -ne 0) {
                        Invoke-SSHCommand -SessionId $session.SessionId `
                            -Command "sudo rm -f '$tmpPath'" | Out-Null
                        throw "[$name] visudo validation failed for '$username': $($r.Output -join ' ')"
                    }

                    # Validation passed - move the temp file into place.
                    $r = Invoke-SSHCommand `
                        -SessionId $session.SessionId `
                        -Command   "sudo mv '$tmpPath' '$sudoersPath'" `
                        -ErrorAction Stop

                    if ($r.ExitStatus -ne 0) {
                        Invoke-SSHCommand -SessionId $session.SessionId `
                            -Command "sudo rm -f '$tmpPath'" | Out-Null
                        throw "[$name] Failed to install sudoers for '$username': $($r.Error)"
                    }

                    Write-Host "[$name] user '$username': sudoers updated" `
                        -ForegroundColor Yellow
                }
            }
        }
    }
    finally {
        # Always close the session to release the TCP connection, even if
        # an operation above threw.
        Remove-SSHSession -SessionId $session.SessionId | Out-Null
    }
}
