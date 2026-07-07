<#
.SYNOPSIS
    Removes OS users provisioned by create-users.ps1 from Ubuntu VMs.

.DESCRIPTION
    Reads VM connection details (IP, admin credentials) from the existing
    VmProvisioner vault and the desired user list from the VmUsers vault.
    Joins the two by vmName, then for each reachable VM removes sudoers
    files, user accounts, and declared groups via SSH.

    The same VmUsersConfig that drives create-users.ps1 drives this script -
    every user and declared group in the config is removed.

    The whole two-vault read, router resolution, SSH probe, and per-VM
    session lifecycle live in the shared Invoke-VmUserReconcileRun orchestrator
    (reconcile/common); this entry script only supplies the remove direction:
    its final-phase label and a per-VM action that calls Invoke-VmUserRemove.

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable.
    - Posh-SSH is installed, or an internet connection is available so this
      script can install it from PSGallery automatically.

    Unreachable VMs are warned and skipped. Re-run once the VM is reachable,
    or remove the users manually.

.EXAMPLE
    .\remove-users.ps1 -SecretSuffix Production
#>

[CmdletBinding()]
param(
    # Required. See create-users.ps1 for the suffix contract.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install / import every required PowerShell module. The helper owns the
# dependency list for this repo so each entry-point script does not repeat
# the bootstrap block.
. "$PSScriptRoot\..\shared\Install-ModuleDependencies.ps1"

# Dot-source helpers after the modules are loaded so Assert-RequiredProperties
# (Common.PowerShell) and the SSH helpers (Infrastructure.HyperV) are
# available inside their function bodies. The shared orchestrator drives the
# whole run; the remove-direction reconcile helpers back its per-VM action.
. "$PSScriptRoot\reconcile\common\ConvertFrom-VmUsersConfigJson.ps1"
. "$PSScriptRoot\reconcile\common\Invoke-VmUserReconcileRun.ps1"
. "$PSScriptRoot\reconcile\down\Invoke-VmUserRemove.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmGroups.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmSudoers.ps1"
. "$PSScriptRoot\reconcile\down\Remove-VmUsers.ps1"

# Drive the shared orchestration in the remove direction: the final phase is
# the per-VM removal loop, and each reachable VM's action removes its sudoers
# files, user accounts, and declared groups over the open session.
Invoke-VmUserReconcileRun `
    -SecretSuffix   $SecretSuffix `
    -FinalPhaseName 'Per-VM SSH removal' `
    -PerVmAction    {
        param($Client, $VmName, $Entry)
        Invoke-VmUserRemove -SshClient $Client -VmName $VmName -Entry $Entry
    }
