<#
.SYNOPSIS
    Installs and imports every PowerShell module the Infrastructure-Vm-Users
    entry-point scripts need.

.DESCRIPTION
    Centralised so each entry-point (create-users.ps1, remove-users.ps1)
    dot-sources this file once instead of repeating the same install/import
    block. Intentionally not a function: dot-sourcing this script imports
    every required module into the caller's scope, which is what the
    entry-points and their dot-sourced helpers expect.

    Step 1 - NuGet provider: PowerShellGet uses it to download from PSGallery.
             Included even though it's idempotent so a cold machine doesn't
             need a separate setup step.

    Step 2 - Common.PowerShell: the chicken-and-egg case. It supplies
             Invoke-ModuleInstall used by every install below, so it cannot
             install itself - the inline guard is unavoidable.

    Step 3 - Everything else flows through Invoke-ModuleInstall.

    Step 4 - Posh-SSH carries the Renci.SshNet.dll that Infrastructure.HyperV's
             SSH helpers consume; Posh-SSH cmdlets themselves are NOT used
             because the ConnectionInfoGenerator in Posh-SSH 3.x drops
             algorithm entries and breaks KEX against OpenSSH 9.x on
             Ubuntu 24.04.

    Step 5 - Infrastructure.Secrets and SecretManagement: installed here
             rather than assumed-installed so this helper is self-sufficient
             and setup-secrets.ps1 can dot-source it without a circular
             chicken-and-egg.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Install-PowerShellCommonWithRetry
#   The chicken-and-egg case: Invoke-ModuleInstall (which has retry built
#   in) lives inside Common.PowerShell, so it cannot be used to install
#   Common.PowerShell itself. A small inline retry wrapper here covers
#   that single bootstrap call. All later Invoke-ModuleInstall calls below
#   get retry for free.
#
#   Defaults mirror Invoke-ModuleInstall's: 6 attempts, exponential 10 s ->
#   20 -> 40 -> 80 -> 160, capped at 300 s (5 min). Total wait ~5 min
#   before giving up - long enough to ride out a transient PSGallery
#   resolution blip, short enough that a real outage fails the run.
# ---------------------------------------------------------------------------
function Install-PowerShellCommonWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Version] $MinimumVersion,
        [int] $MaxAttempts         = 6,
        [int] $InitialDelaySeconds = 10,
        [int] $MaxDelaySeconds     = 300
    )
    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            # -ErrorAction Stop promotes PSGallery "Unable to resolve
            # package source" (a non-terminating error by default) to a
            # terminating one so the catch block can retry it.
            Install-Module Common.PowerShell `
                -MinimumVersion $MinimumVersion `
                -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning (
                "Install-Module Common.PowerShell failed " +
                "(attempt $attempt/$MaxAttempts): " +
                "$($_.Exception.Message). Retrying in ${delay}s ..."
            )
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        }
    }
}

# Step 1 - NuGet provider
$_nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_nuget -or $_nuget.Version -lt [Version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
}

# Step 2 - Common.PowerShell (chicken-and-egg bootstrap)
# Floor is 9.3.0: that release adds Export-PhaseTimingTreeIfRequested, the
# self-guarding opt-in wrapper over Export-PhaseTimingTree that create-users.ps1
# / remove-users.ps1 call (a single unguarded call each) in their outer finally
# to hand their phase-timing tree to a parent orchestrator on the
# TIMING_TREE_OUTPUT_PATH opt-in. 9.2.0 shipped the underlying
# Export-PhaseTimingTree; 9.1.0 shipped the 2-level phase-timing compat shims
# (Initialize-PhaseTimings / Invoke-WithPhaseTimer) those scripts also consume.
$_common = Get-Module -ListAvailable -Name Common.PowerShell |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'9.3.0') {
    Install-PowerShellCommonWithRetry -MinimumVersion '9.3.0'
    # Re-query so the comparison below uses the freshly installed version.
    $_common = Get-Module -ListAvailable -Name Common.PowerShell |
        Sort-Object Version -Descending | Select-Object -First 1
}
# Reload only when the loaded state differs from the target (multiple
# versions live, or wrong version live). Mirrors the conditional in
# Invoke-ModuleInstall - inlined here because the bootstrap installs
# the very module that defines that function.
$_loaded = @(Get-Module -Name Common.PowerShell)
if ($_loaded.Count -ne 1 -or $_loaded[0].Version -ne $_common.Version) {
    if ($_loaded) { $_loaded | Remove-Module -Force }
    Import-Module Common.PowerShell -Force -ErrorAction Stop
}

# Step 3 - Infrastructure.HyperV (SSH execution, host file server,
# Test-VmSshPort, Wait-VmSshReady, plus the jump-aware New-VmSshClientWithJump
# / New-VmSshTunnel / Test-SshBanner and the Get-VmKvpIpAddress helper this
# script uses to find the router for workloads behind a feature-53 NAT
# topology - all added in 0.11.0).
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV' -MinimumVersion '0.11.0'

# Step 4 - Posh-SSH (SSH.NET DLL carrier - see header comment)
Invoke-ModuleInstall -ModuleName 'Posh-SSH'

# Step 5 - SecretStore stack
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets'             -MinimumVersion '3.0.1'
Invoke-ModuleInstall -ModuleName 'Microsoft.PowerShell.SecretManagement'
