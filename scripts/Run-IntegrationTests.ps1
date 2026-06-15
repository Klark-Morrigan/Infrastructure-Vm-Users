<#
.SYNOPSIS
    Runs integration tests locally in Docker. Delegates to the shared runner
    in Common-PowerShell.

.EXAMPLE
    .\Run-IntegrationTests.ps1
#>

# Repo root is one level up now that this script lives under scripts\;
# Common-PowerShell is a sibling of the repo root, so two levels up from here.
$repoRoot = Split-Path -Parent $PSScriptRoot

& ([IO.Path]::Combine($repoRoot, '..', 'Common-PowerShell', '.github', `
    'actions', 'run-integration-tests', 'Run-IntegrationTests.ps1')) `
    -TestsRoot $repoRoot
