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
    - OpenSSH client is installed (ssh.exe on PATH).

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
# TODO: Step 4 - user reconciliation via SSH (create / update each user)
# TODO: Step 5 - sudoers reconciliation (/etc/sudoers.d/{username})
# ---------------------------------------------------------------------------
