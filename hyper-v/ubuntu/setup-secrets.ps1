<#
.SYNOPSIS
    One-time setup: stores the VM users JSON config in the local vault.

.DESCRIPTION
    Run once per machine before running create-users.ps1.
    Re-running safely updates the stored config.

    Installs the Infrastructure.Secrets module from PSGallery automatically
    if not already present on this machine.

    VM connection details (IP, admin credentials) are read at runtime from
    the existing VmProvisioner vault - they are not duplicated here.

.PARAMETER ConfigJson
    The VM users config as a raw JSON string.
    Mutually exclusive with -ConfigFile.

.PARAMETER ConfigFile
    Path to a JSON file containing the VM users config.
    Mutually exclusive with -ConfigJson.
    The file is read at runtime; it is not modified.

.PARAMETER RequireVaultPassword
    When specified, the SecretStore vault requires a password each session.
    Recommended on shared or less-trusted machines.

.EXAMPLE
    .\setup-secrets.ps1 -ConfigFile C:\private\vm-users-config.json

.EXAMPLE
    .\setup-secrets.ps1 -ConfigFile C:\private\vm-users-config.json -RequireVaultPassword
#>

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Json')]
    [string] $ConfigJson,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ConfigFile,

    [Parameter()]
    [switch] $RequireVaultPassword,

    # Required. The secret is written as `VmUsersConfig-<Suffix>`.
    # Operator runs pass `Production`; ephemeral fixtures (test
    # harnesses, parallel workflows) pass their own label so each
    # lifecycle has an isolated secret.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install / import every required PowerShell module via the centralised
# helper. Owns NuGet provider, PowerShell.Common, Infrastructure.Secrets,
# and the rest of this repo's deps in one place.
. "$PSScriptRoot\Install-ModuleDependencies.ps1"

# ConvertFrom-VmUsersConfigJson.ps1 is dot-sourced after the modules are
# loaded. It only calls Assert-RequiredProperties inside function bodies,
# not at load time, so this ordering is safe.
. "$PSScriptRoot\reconcile\common\ConvertFrom-VmUsersConfigJson.ps1"

# Forward the secret-store cmdlet only the params it knows about; Suffix
# is consumed locally to build SecretName and must not be splatted.
$initParams = @{}
foreach ($k in 'ConfigJson','ConfigFile','RequireVaultPassword') {
    if ($PSBoundParameters.ContainsKey($k)) {
        $initParams[$k] = $PSBoundParameters[$k]
    }
}

Initialize-MicrosoftPowerShellSecretStoreVault `
    -VaultName  'VmUsers' `
    -SecretName "VmUsersConfig-$SecretSuffix" `
    @initParams `
    -Validate {
        param($json)
        $entries = ConvertTo-Array (ConvertFrom-VmUsersConfigJson -Json $json)
        Write-Host "✓ JSON validated - $($entries.Count) VM entry/entries found." `
            -ForegroundColor Green
    }

Write-Host ""
Write-Host "Setup complete. Run create-users.ps1 to reconcile users on VMs." `
    -ForegroundColor Cyan
