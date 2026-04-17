<#
.SYNOPSIS
    Runs integration tests locally in Docker. Delegates to the shared runner
    in Infrastructure-Common.

.EXAMPLE
    .\Run-IntegrationTests.ps1
#>

& ([IO.Path]::Combine($PSScriptRoot, '..', 'Infrastructure-Common', '.github', `
    'actions', 'run-integration-tests', 'Run-IntegrationTests.ps1')) `
    -TestsRoot $PSScriptRoot
