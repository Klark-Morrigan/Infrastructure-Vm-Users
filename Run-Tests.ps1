<#
.SYNOPSIS
    Runs all Pester tests for the Infrastructure-Vm-Users scripts.

.DESCRIPTION
    Installs Pester 5 if not already present, then runs every *.Tests.ps1
    file under the Tests\ directory. Exits with a non-zero code on failure
    so the script is safe to call from CI.

.EXAMPLE
    .\Run-Tests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Ensure Pester 5 is available.
#   Pester 3 ships with Windows PowerShell 5.1 and is incompatible with our
#   tests (different API). We require >= 5.0 explicitly.
# ---------------------------------------------------------------------------

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host 'Pester 5 not found - installing ...' -ForegroundColor Cyan
    Install-Module -Name Pester -MinimumVersion 5.0 `
        -Scope CurrentUser -Force -SkipPublisherCheck
}

Import-Module Pester -MinimumVersion 5.0

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------

# Guard against running with no test files - Pester throws rather than
# returning a result object, which breaks the FailedCount check below.
$testFiles = Get-ChildItem -Path "$PSScriptRoot\Tests" `
    -Filter '*.Tests.ps1' -Recurse -ErrorAction SilentlyContinue

if (-not $testFiles) {
    Write-Host 'No test files found under Tests\ - nothing to run.' `
        -ForegroundColor Yellow
    exit 0
}

$config = New-PesterConfiguration
$config.Run.Path              = "$PSScriptRoot\Tests"
$config.Output.Verbosity      = 'Detailed'
$config.TestResult.Enabled    = $true
$config.TestResult.OutputPath = "$PSScriptRoot\TestResults.xml"
# PassThru is required for Invoke-Pester to return a result object;
# without it the return value is $null and FailedCount cannot be read.
$config.Run.PassThru = $true

$result = Invoke-Pester -Configuration $config

if ($result.FailedCount -gt 0) {
    Write-Host "$($result.FailedCount) test(s) failed." -ForegroundColor Red
    exit 1
}
