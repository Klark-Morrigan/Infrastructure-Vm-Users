# ---------------------------------------------------------------------------
# Initialize-DockerHostEnvironment.ps1
#   Shared BeforeAll body for DockerHost integration tests. Dot-source this
#   file inside a BeforeAll block:
#       BeforeAll { . "$PSScriptRoot\Initialize-DockerHostEnvironment.ps1" }
#
#   When dot-sourced inside BeforeAll, all code runs in that block's scope,
#   so $Script:* assignments land on the test file's script scope and are
#   visible to It/AfterAll/AfterEach blocks in that file.
# ---------------------------------------------------------------------------

# Prints a timestamped step banner so slow steps are identifiable in CI
# output. Format: [HH:mm:ss] Step N - description
function Write-Step {
    param([int] $Number, [string] $Description)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host "[$ts] Step $Number - $Description" -ForegroundColor Cyan
}

# -----------------------------------------------------------------------
# 1. Install openssh-server and sudo
#    The powershell image is Ubuntu-based; apt-get is available.
# -----------------------------------------------------------------------

Write-Step 1 'configuring apt sources'

# DEBIAN_FRONTEND=noninteractive prevents apt post-install scripts (notably
# tzdata, pulled in by openssh-server) from prompting for timezone input.
# Without it the container hangs indefinitely because stdin is not a TTY.
$env:DEBIAN_FRONTEND = 'noninteractive'

# Docker Desktop on Windows silently drops TCP connections on port 80.
# apt sources default to http://, so every mirror times out (~30 s each)
# causing a 9-minute update that also wipes the package cache (APT marks
# lists that could not be verified as unavailable). Port 443 (HTTPS) is
# routed correctly by Docker Desktop - PSGallery installs confirm this.
# Switching all sources from http:// to https:// before the update makes
# it complete in seconds rather than minutes.
& bash -c 'sed -i "s|http://|https://|g" /etc/apt/sources.list; find /etc/apt/sources.list.d -name "*.list" -exec sed -i "s|http://|https://|g" {} + 2>/dev/null; true'

Write-Step 1 'apt-get update'
& bash -c 'apt-get update -qq 2>&1' | Out-Null

Write-Step 1 'apt-get install openssh-server sudo'

# --no-install-recommends reduces the dependency footprint and avoids
# pulling in additional packages that trigger interactive prompts.
# Capture output so it can be printed on failure for diagnosis.
$aptOutput = & bash -c 'apt-get install -y --no-install-recommends openssh-server sudo 2>&1'
if ($LASTEXITCODE -ne 0) {
    Write-Host 'apt-get install failed. Output:' -ForegroundColor Red
    $aptOutput | ForEach-Object { Write-Host $_ }
    throw "apt-get install exited $LASTEXITCODE - cannot continue without openssh-server and sudo."
}

Write-Step 1 'generating SSH host keys'

# Generate host keys (absent in a fresh container).
& ssh-keygen -A 2>&1 | Out-Null

# sshd needs /run/sshd to exist before it will start.
New-Item -ItemType Directory -Path '/run/sshd' -Force | Out-Null

# -----------------------------------------------------------------------
# 2. Create test admin user
#    Reconciliation functions SSH in as this user and prefix OS commands
#    with sudo. NOPASSWD:ALL grants the needed privileges; !requiretty
#    allows sudo in a non-interactive SSH session.
# -----------------------------------------------------------------------

Write-Step 2 'creating test admin user'

$Script:AdminUser = 'infra-t-admin'
$Script:AdminPass = 'InfraTestAdmin1!'

& useradd -m -s /bin/bash $Script:AdminUser 2>&1 | Out-Null
& bash -c "echo '${Script:AdminUser}:${Script:AdminPass}' | chpasswd"

$sudoLine = "${Script:AdminUser} ALL=(ALL) NOPASSWD:ALL"
$noTtyLine = "Defaults:${Script:AdminUser} !requiretty"
Set-Content -Path "/etc/sudoers.d/${Script:AdminUser}" `
    -Value "$sudoLine`n$noTtyLine"
& chmod 0440 "/etc/sudoers.d/${Script:AdminUser}"

# -----------------------------------------------------------------------
# 3. Enable password authentication in sshd
#    The default Ubuntu sshd_config may have PasswordAuthentication set
#    to 'no' or left commented. Replace or append to make it explicit.
# -----------------------------------------------------------------------

Write-Step 3 'configuring sshd for password authentication'

$sshdConfigPath = '/etc/ssh/sshd_config'
$sshdConfig = Get-Content $sshdConfigPath -Raw

if ($sshdConfig -match '(?m)^#?PasswordAuthentication') {
    $sshdConfig = $sshdConfig -replace `
        '(?m)^#?PasswordAuthentication\s+\w+', `
        'PasswordAuthentication yes'
} else {
    $sshdConfig += "`nPasswordAuthentication yes"
}

Set-Content -Path $sshdConfigPath -Value $sshdConfig

# -----------------------------------------------------------------------
# 4. Install PowerShell.Common and Infrastructure.HyperV
#    Done before starting sshd because Wait-VmSshReady (HyperV) is used in
#    step 5 to gate sshd's port-22 bind. Posh-SSH is installed later -
#    its SSH.NET DLL is only needed in step 7 when the test opens its own
#    SshClient. Common and HyperV are installed via direct Install-Module
#    rather than Invoke-ModuleInstall because the container is fresh and
#    Invoke-ModuleInstall ships in Common itself.
# -----------------------------------------------------------------------

Write-Step 4 'installing PowerShell.Common from PSGallery'

# Inline retry for the chicken-and-egg case: Invoke-ModuleInstall (which
# has retry built in) ships inside PowerShell.Common, so it cannot be
# used to install Common itself. Six attempts with exponential backoff
# (10 s -> 20 -> 40 -> 80 -> 160, capped at 300 s) covers transient
# PSGallery "Unable to resolve package source" blips without stalling an
# integration run on a real outage.
$_installAttempts        = 6
$_installDelaySeconds    = 10
$_installMaxDelaySeconds = 300
for ($_attempt = 1; $_attempt -le $_installAttempts; $_attempt++) {
    try {
        # -ErrorAction Stop promotes the PSGallery resolution warning to a
        # terminating error so the catch block can see and retry it.
        Install-Module PowerShell.Common -MinimumVersion '5.1.0' `
            -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
        break
    }
    catch {
        if ($_attempt -ge $_installAttempts) { throw }
        Write-Warning (
            "Install-Module PowerShell.Common failed " +
            "(attempt $_attempt/$_installAttempts): " +
            "$($_.Exception.Message). Retrying in ${_installDelaySeconds}s ..."
        )
        Start-Sleep -Seconds $_installDelaySeconds
        $_installDelaySeconds = [Math]::Min(
            $_installDelaySeconds * 2, $_installMaxDelaySeconds)
    }
}

# Reload only when the loaded state differs from the target (multiple
# versions live, or wrong version live). Mirrors the conditional in
# Invoke-ModuleInstall - inlined here because this script runs before
# PowerShell.Common is available.
$_common = Get-Module -ListAvailable -Name PowerShell.Common |
    Sort-Object Version -Descending | Select-Object -First 1
$_loaded = @(Get-Module -Name PowerShell.Common)
if ($_loaded.Count -ne 1 -or $_loaded[0].Version -ne $_common.Version) {
    if ($_loaded) { $_loaded | Remove-Module -Force }
    Import-Module PowerShell.Common -Force -ErrorAction Stop
}

Write-Step 4 'installing Infrastructure.HyperV from PSGallery'

# Provides Invoke-SshClientCommand used by Invoke-SshQuery below, plus
# Wait-VmSshReady used to gate sshd startup in step 5.
Install-Module Infrastructure.HyperV -MinimumVersion '0.3.1' `
    -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Infrastructure.HyperV -Force -ErrorAction Stop

# -----------------------------------------------------------------------
# 5. Start sshd and wait for it to bind
# -----------------------------------------------------------------------

Write-Step 5 'starting sshd'

& /usr/sbin/sshd
# Wait for sshd to bind port 22 deterministically. The previous fixed
# Start-Sleep -Seconds 1 was a guess; on a slow container it could race
# the subsequent SSH connect attempt.
if (-not (Wait-VmSshReady -IpAddress 'localhost' -TimeoutSeconds 10 `
                          -PollIntervalSeconds 1)) {
    throw "sshd did not become reachable on localhost:22 within 10s."
}

# -----------------------------------------------------------------------
# 6. Install Posh-SSH (for its bundled SSH.NET DLL) and dot-source
#    reconciliation functions. Posh-SSH cmdlets are NOT used - SSH.NET is
#    used directly to avoid the Posh-SSH 3.x ConnectionInfoGenerator bug
#    that drops algorithm entries and causes KEX failure against OpenSSH 9.x.
# -----------------------------------------------------------------------

Write-Step 6 'installing Posh-SSH (SSH.NET carrier) from PSGallery'

Install-Module Posh-SSH -MinimumVersion 3.0.0 `
    -Scope CurrentUser -Force -SkipPublisherCheck
# Import-Module loads the bundled Renci.SshNet.dll into the session.
Import-Module Posh-SSH

Write-Step 6 'dot-sourcing reconciliation functions'

$src = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'hyper-v', 'ubuntu', 'reconcile')
. ([IO.Path]::Combine($src, 'common', 'ConvertFrom-VmUsersConfigJson.ps1'))
. ([IO.Path]::Combine($src, 'up',     'Invoke-GroupReconciliation.ps1'))
. ([IO.Path]::Combine($src, 'up',     'Invoke-SudoersReconciliation.ps1'))
. ([IO.Path]::Combine($src, 'up',     'Invoke-UserReconciliation.ps1'))

# -----------------------------------------------------------------------
# 7. Open SSH session to localhost via SSH.NET directly.
# -----------------------------------------------------------------------

Write-Step 7 'opening SSH session to localhost'

$auth             = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                        $Script:AdminUser, $Script:AdminPass)
$connInfo         = [Renci.SshNet.ConnectionInfo]::new(
                        'localhost', $Script:AdminUser, @($auth))
$Script:SshClient = [Renci.SshNet.SshClient]::new($connInfo)
$Script:SshClient.Connect()
$Script:VmName    = 'test-vm'

# -----------------------------------------------------------------------
# 8. Define shared helper
#    Must be inside BeforeAll - functions defined at script level are not
#    in scope when It blocks execute in Pester 5.
# -----------------------------------------------------------------------

Write-Step 8 'defining shared helpers'

function Invoke-SshQuery {
    param([string] $Command)
    $r = Invoke-SshClientCommand -SshClient $Script:SshClient -Command $Command `
        -ErrorAction Stop
    return ($r.Output -join '').Trim()
}

Write-Step 8 'BeforeAll complete'
