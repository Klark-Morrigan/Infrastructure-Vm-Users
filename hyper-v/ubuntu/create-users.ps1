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

# Bootstrap Infrastructure.Common first - it provides Invoke-ModuleInstall
# used for all subsequent module installs. Infrastructure.Secrets and
# Posh-SSH are prerequisites (setup-secrets.ps1 installs the former; the
# latter is auto-installed below), so we do not silently install them here.
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'1.0.0') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# Dot-source helpers after Infrastructure.Common is loaded so
# Assert-RequiredProperties is available inside their function bodies.
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\reconcile-groups.ps1"
. "$PSScriptRoot\reconcile-users.ps1"
. "$PSScriptRoot\reconcile-sudoers.ps1"

# Infrastructure.Secrets must already be installed by setup-secrets.ps1.
Import-Module Infrastructure.Secrets                    -ErrorAction Stop
Import-Module Microsoft.PowerShell.SecretManagement    -ErrorAction Stop

# Posh-SSH provides New-SSHSession / Invoke-SSHCommand for password-based
# SSH from Windows PowerShell. The provisioner does not set up key-based
# auth, so we authenticate with the admin username/password from the vault.
# Unlike Infrastructure.Secrets (one-time setup), Posh-SSH is a runtime
# dependency - Invoke-ModuleInstall keeps the operational workflow
# self-contained.
Invoke-ModuleInstall -ModuleName 'Posh-SSH' -MinimumVersion '3.0.0'

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
# 5. Reconciliation via SSH
#    For each reachable VM, open one SSH session and reconcile groups, users,
#    and sudoers rules within it. The session is always closed in the finally
#    block, even if an operation throws.
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
        # Get-Member is used to check for the optional 'groups' property
        # without triggering StrictMode on a missing key.
        $entryMembers   = (Get-Member -InputObject $t.Entry -MemberType NoteProperty).Name
        $declaredGroups = if ($entryMembers -contains 'groups') {
            @($t.Entry.groups)
        } else {
            @()
        }

        # 5a. Groups must exist before users reference them in useradd/usermod.
        Invoke-GroupReconciliation `
            -SessionId      $session.SessionId `
            -VmName         $name `
            -DeclaredGroups $declaredGroups `
            -Users          $users

        foreach ($user in $users) {
            # 5b. Ensure the user exists with the correct shell and groups.
            Invoke-UserReconciliation `
                -SessionId $session.SessionId `
                -VmName    $name `
                -User      $user

            # 5c. Ensure the sudoers file matches desired rules.
            Invoke-SudoersReconciliation `
                -SessionId $session.SessionId `
                -VmName    $name `
                -User      $user
        }
    }
    finally {
        # Always close the session to release the TCP connection, even if
        # an operation above threw.
        Remove-SSHSession -SessionId $session.SessionId | Out-Null
    }
}
