# ---------------------------------------------------------------------------
# Integration tests for Invoke-GroupReconciliation, Invoke-UserReconciliation,
# and Invoke-SudoersReconciliation against a real Linux SSH session.
#
# ENVIRONMENT
#   Runs inside mcr.microsoft.com/powershell (Ubuntu-based). BeforeAll installs
#   openssh-server, creates a test admin user with passwordless sudo, starts
#   sshd, and opens a Posh-SSH session to localhost. All reconciliation
#   functions run through that session exactly as they would against a real VM.
#
# ISOLATION
#   All test artifacts use an 'infra-t-' prefix. They are removed in AfterAll.
#   BeforeEach/AfterEach clean per-test state so Describe blocks are
#   independent of one another.
# ---------------------------------------------------------------------------

BeforeAll {
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
    # 4. Start sshd and wait for it to bind
    # -----------------------------------------------------------------------

    Write-Step 4 'starting sshd'

    & /usr/sbin/sshd
    Start-Sleep -Seconds 1

    # -----------------------------------------------------------------------
    # 5. Install Posh-SSH and dot-source reconciliation functions
    # -----------------------------------------------------------------------

    Write-Step 5 'installing Posh-SSH from PSGallery'

    Install-Module Posh-SSH -MinimumVersion 3.0.0 `
        -Scope CurrentUser -Force -SkipPublisherCheck
    Import-Module Posh-SSH

    Write-Step 5 'dot-sourcing reconciliation functions'

    $src = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'hyper-v', 'ubuntu')
    . ([IO.Path]::Combine($src, 'reconcile-groups.ps1'))
    . ([IO.Path]::Combine($src, 'reconcile-users.ps1'))
    . ([IO.Path]::Combine($src, 'reconcile-sudoers.ps1'))

    # -----------------------------------------------------------------------
    # 6. Open SSH session to localhost
    # -----------------------------------------------------------------------

    Write-Step 6 'opening SSH session to localhost'

    $credential = [PSCredential]::new(
        $Script:AdminUser,
        ($Script:AdminPass | ConvertTo-SecureString -AsPlainText -Force)
    )

    $Script:Session = New-SSHSession `
        -ComputerName localhost `
        -Credential   $credential `
        -AcceptKey    `
        -ErrorAction  Stop

    $Script:SessionId = $Script:Session.SessionId
    $Script:VmName    = 'test-vm'

    # -----------------------------------------------------------------------
    # 7. Define shared helper
    #    Must be inside BeforeAll - functions defined at script level are not
    #    in scope when It blocks execute in Pester 5.
    # -----------------------------------------------------------------------

    Write-Step 7 'defining shared helpers'

    function Invoke-SshQuery {
        param([string] $Command)
        $r = Invoke-SSHCommand -SessionId $Script:SessionId -Command $Command `
            -ErrorAction Stop
        return ($r.Output -join '').Trim()
    }

    Write-Step 7 'BeforeAll complete'
}

AfterAll {
    if ($null -ne $Script:Session) {
        Remove-SSHSession -SessionId $Script:SessionId | Out-Null
    }

    # Remove all test artifacts. Suppress errors - some may not exist if a
    # test was skipped or failed before creating them.
    & bash -c "userdel -r infra-t-user 2>/dev/null; userdel -r ${Script:AdminUser} 2>/dev/null" |
        Out-Null
    & bash -c 'groupdel infra-t-group 2>/dev/null; groupdel infra-t-implicit 2>/dev/null' |
        Out-Null
}

# ===========================================================================
# Invoke-GroupReconciliation
# ===========================================================================

Describe 'Invoke-GroupReconciliation' {

    AfterEach {
        & bash -c 'groupdel infra-t-group 2>/dev/null; groupdel infra-t-implicit 2>/dev/null' |
            Out-Null
    }

    It 'creates a declared group' {
        $group = [PSCustomObject]@{ groupName = 'infra-t-group' }

        Invoke-GroupReconciliation `
            -SessionId      $Script:SessionId `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()

        Invoke-SshQuery "getent group infra-t-group" | Should -Match 'infra-t-group'
    }

    It 'is idempotent for a group that already exists' {
        # Create the group first, then reconcile again - should not throw.
        & bash -c 'groupadd infra-t-group' | Out-Null
        $group = [PSCustomObject]@{ groupName = 'infra-t-group' }

        { Invoke-GroupReconciliation `
            -SessionId      $Script:SessionId `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()
        } | Should -Not -Throw
    }

    It 'creates a declared group with a pinned GID' {
        $group = [PSCustomObject]@{ groupName = 'infra-t-group'; gid = 19500 }

        Invoke-GroupReconciliation `
            -SessionId      $Script:SessionId `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()

        # getent output: name:x:gid:members
        $gid = (Invoke-SshQuery "getent group infra-t-group") -split ':' | Select-Object -Index 2
        $gid | Should -Be '19500'
    }

    It 'throws when an existing group has a conflicting GID' {
        & bash -c 'groupadd -g 19501 infra-t-group' | Out-Null
        $group = [PSCustomObject]@{ groupName = 'infra-t-group'; gid = 19502 }

        { Invoke-GroupReconciliation `
            -SessionId      $Script:SessionId `
            -VmName         $Script:VmName `
            -DeclaredGroups @($group) `
            -Users          @()
        } | Should -Throw '*GID*'
    }

    It 'creates implicit groups referenced in users[].groups' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            groups   = @('infra-t-implicit')
        }

        Invoke-GroupReconciliation `
            -SessionId      $Script:SessionId `
            -VmName         $Script:VmName `
            -DeclaredGroups @() `
            -Users          @($user)

        Invoke-SshQuery "getent group infra-t-implicit" | Should -Match 'infra-t-implicit'
    }
}

# ===========================================================================
# Invoke-UserReconciliation
# ===========================================================================

Describe 'Invoke-UserReconciliation' {

    BeforeEach {
        # Ensure test group exists so useradd -G does not fail.
        & bash -c 'groupadd infra-t-group 2>/dev/null' | Out-Null
    }

    AfterEach {
        & bash -c 'userdel -r infra-t-user 2>/dev/null; groupdel infra-t-group 2>/dev/null' |
            Out-Null
    }

    It 'creates a new user with the correct shell' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-UserReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        $shell = Invoke-SshQuery "getent passwd infra-t-user | cut -d: -f7"
        $shell | Should -Be '/bin/bash'
    }

    It 'creates a new user and assigns supplementary groups' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            groups   = @('infra-t-group')
        }

        Invoke-UserReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery "id -Gn infra-t-user" | Should -Match 'infra-t-group'
    }

    It 'is idempotent when user already matches desired state' {
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-UserReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        # Second call - must not throw.
        { Invoke-UserReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user
        } | Should -Not -Throw
    }

    It 'updates the shell when it drifts' {
        & bash -c 'useradd -m -s /bin/sh infra-t-user' | Out-Null

        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-UserReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        $shell = Invoke-SshQuery "getent passwd infra-t-user | cut -d: -f7"
        $shell | Should -Be '/bin/bash'
    }

    It 'updates supplementary groups when they drift' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            groups   = @('infra-t-group')
        }

        Invoke-UserReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery "id -Gn infra-t-user" | Should -Match 'infra-t-group'
    }

    It 'sets the password so the user can authenticate via SSH' {
        # Uses a second SSH session as the test user to prove chpasswd ran
        # correctly - the only reliable way to verify a password was set on a
        # real system is to authenticate with it.
        $testPass = 'InfraTestUser1!'
        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
            password = $testPass
        }

        Invoke-UserReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        $cred = [PSCredential]::new(
            'infra-t-user',
            ($testPass | ConvertTo-SecureString -AsPlainText -Force)
        )
        $userSession = New-SSHSession `
            -ComputerName localhost `
            -Credential   $cred `
            -AcceptKey    `
            -ErrorAction  Stop
        Remove-SSHSession -SessionId $userSession.SessionId | Out-Null
    }

    It 'emits a warning but does not move the directory when homeDir drifts' {
        & bash -c 'useradd -m -s /bin/bash infra-t-user' | Out-Null

        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            # Desired homeDir differs from the one useradd created above.
            homeDir  = '/home/infra-t-other'
        }

        Invoke-UserReconciliation `
            -SessionId       $Script:SessionId `
            -VmName          $Script:VmName `
            -User            $user `
            -WarningVariable warnings

        # Original directory must still exist - it must not have been moved.
        Invoke-SshQuery 'test -d /home/infra-t-user && echo exists || echo absent' |
            Should -Be 'exists'
        # New path must not have been created.
        Invoke-SshQuery 'test -d /home/infra-t-other && echo exists || echo absent' |
            Should -Be 'absent'
        # Warning must have been emitted identifying the drift.
        $warnings | Should -Match 'homeDir has drifted'
    }
}

# ===========================================================================
# Invoke-SudoersReconciliation
# ===========================================================================

Describe 'Invoke-SudoersReconciliation' {

    BeforeEach {
        # Ensure the test user exists so sudoers operations have a real subject.
        & bash -c 'useradd -m -s /bin/bash infra-t-user 2>/dev/null' | Out-Null
    }

    AfterEach {
        & bash -c 'rm -f /etc/sudoers.d/infra-t-user; userdel -r infra-t-user 2>/dev/null' |
            Out-Null
    }

    It 'writes sudoers rules when none exist' {
        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @('infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls')
        }

        Invoke-SudoersReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        $content = Invoke-SshQuery 'sudo cat /etc/sudoers.d/infra-t-user'
        $content | Should -Match 'NOPASSWD'
    }

    It 'is idempotent when rules already match' {
        $rule = 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls'
        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @($rule)
        }

        Invoke-SudoersReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        # Second call - must not throw and file content must be unchanged.
        { Invoke-SudoersReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user
        } | Should -Not -Throw
    }

    It 'updates rules when they drift' {
        # Write initial rules directly.
        & bash -c "echo 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls' | sudo tee /etc/sudoers.d/infra-t-user > /dev/null && sudo chmod 0440 /etc/sudoers.d/infra-t-user" |
            Out-Null

        $user = [PSCustomObject]@{
            username     = 'infra-t-user'
            shell        = '/bin/bash'
            homeDir      = '/home/infra-t-user'
            sudoersRules = @('infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/id')
        }

        Invoke-SudoersReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        $content = Invoke-SshQuery 'sudo cat /etc/sudoers.d/infra-t-user'
        $content | Should -Match '/usr/bin/id'
        $content | Should -Not -Match '/usr/bin/ls'
    }

    It 'removes the sudoers file when rules are emptied' {
        & bash -c "echo 'infra-t-user ALL=(ALL) NOPASSWD: /usr/bin/ls' | sudo tee /etc/sudoers.d/infra-t-user > /dev/null && sudo chmod 0440 /etc/sudoers.d/infra-t-user" |
            Out-Null

        $user = [PSCustomObject]@{
            username = 'infra-t-user'
            shell    = '/bin/bash'
            homeDir  = '/home/infra-t-user'
        }

        Invoke-SudoersReconciliation `
            -SessionId $Script:SessionId `
            -VmName    $Script:VmName `
            -User      $user

        Invoke-SshQuery 'sudo test -f /etc/sudoers.d/infra-t-user && echo exists || echo absent' |
            Should -Be 'absent'
    }
}
