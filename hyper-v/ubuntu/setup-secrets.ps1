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
    [switch] $RequireVaultPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install or update Infrastructure.Secrets from PSGallery.
# The minimum version is pinned here - bump it when a newer feature is required.
$requiredVersion = [Version]'1.1.0'
$installedModule = Get-Module -ListAvailable -Name Infrastructure.Secrets |
    Sort-Object Version -Descending | Select-Object -First 1
$installed = if ($installedModule) { $installedModule.Version } else { $null }

if (-not $installed -or $installed -lt $requiredVersion) {
    Write-Host "Installing Infrastructure.Secrets >= $requiredVersion from PSGallery ..." `
        -ForegroundColor Cyan
    Install-Module Infrastructure.Secrets -Scope CurrentUser -Force
}
Import-Module Infrastructure.Secrets -Force -ErrorAction Stop

. "$PSScriptRoot\common.ps1"

Initialize-InfrastructureVault `
    -VaultName  'VmUsers' `
    -SecretName 'VmUsersConfig' `
    @PSBoundParameters `
    -Validate {
        param($json)
        $entries = @(ConvertFrom-VmUsersConfigJson -Json $json)
        Write-Host "✓ JSON validated - $($entries.Count) VM entry/entries found." `
            -ForegroundColor Green
    }

Write-Host ""
Write-Host "Setup complete. Run create-users.ps1 to reconcile users on VMs." `
    -ForegroundColor Cyan
