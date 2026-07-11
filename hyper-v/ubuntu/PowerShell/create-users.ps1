<#
.SYNOPSIS
    Reconciles OS users on Ubuntu VMs against the desired state in the
    VmUsers vault.

.DESCRIPTION
    Reads VM connection details (IP, admin credentials) from the existing
    VmProvisioner vault and the desired user list from the VmUsers vault.
    Joins the two by vmName, then for each reachable VM reconciles OS users
    and sudoers rules via SSH.

    The whole two-vault read, router resolution, SSH probe, and per-VM
    session lifecycle live in the shared Invoke-VmUserReconcileRun orchestrator
    (reconcile/common); this entry script only supplies the create direction:
    its final-phase label and a per-VM action that calls Invoke-VmUserCreate.

    Prerequisites:
    - setup-secrets.ps1 has been run at least once on this machine.
    - VMs are provisioned (Infrastructure-Vm-Provisioner) and reachable.
    - Posh-SSH is installed, or an internet connection is available so this
      script can install it from PSGallery automatically.

.EXAMPLE
    .\create-users.ps1 -SecretSuffix Production
#>

[CmdletBinding()]
param(
    # Required. The secret reads target `VmProvisionerConfig-<Suffix>`
    # and `VmUsersConfig-<Suffix>`. Operator invocations pass
    # `Production`; ephemeral fixtures (test harnesses, parallel
    # workflows, multi-tenant deployments) pass their own label.
    # Mandatory so a caller cannot silently fall through to a default
    # name and collide with another lifecycle's data.
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
# whole run; the create-direction reconcile helpers back its per-VM action.
. "$PSScriptRoot\reconcile\common\ConvertFrom-VmUsersConfigJson.ps1"
. "$PSScriptRoot\reconcile\common\Get-VmEntryDeclaredGroups.ps1"
. "$PSScriptRoot\reconcile\common\Invoke-VmUserReconcileRun.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-GroupReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-SudoersReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-UserReconciliation.ps1"
. "$PSScriptRoot\reconcile\up\Invoke-VmUserCreate.ps1"

# Drive the shared orchestration in the create direction: the final phase is
# the per-VM reconcile loop, and each reachable VM's action reconciles its
# groups, users, and sudoers rules over the open session.
Invoke-VmUserReconcileRun `
    -SecretSuffix   $SecretSuffix `
    -FinalPhaseName 'Per-VM SSH reconcile' `
    -PerVmAction    {
        param($Client, $VmName, $Entry)
        Invoke-VmUserCreate -SshClient $Client -VmName $VmName -Entry $Entry
    }
