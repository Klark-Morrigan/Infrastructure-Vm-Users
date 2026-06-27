# Infrastructure-Vm-Users

> **Notice:** This repo is no longer the operator default;
> [Common-Ansible] is. The PowerShell scripts here remain
> callable and back the Infrastructure-E2E `custom-powershell` users
> flow as a non-primary first-class implementation. The canonical home
> of the migrated logic is under [Common-Ansible]'s
> `docs/dev/implementation/02-...` (create direction) and `03-...`
> (remove direction) folders.

Reconciles and removes OS users on Ubuntu Hyper-V VMs against a desired
state stored in a local encrypted vault.

## Index

- [What this repo does](#what-this-repo-does)
- [What it does not do](#what-it-does-not-do)
- [Requirements](#requirements)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Config reference](#config-reference)
- [Reconciliation behaviour](#reconciliation-behaviour)
- [Removal](#removal)
- [CI](#ci)
- [Repo structure](#repo-structure)

---

## What this repo does

Reads two vaults:

| Vault | Secret | Source |
|---|---|---|
| `VmProvisioner` | `VmProvisionerConfig` | [Infrastructure-Vm-Provisioner] |
| `VmUsers` | `VmUsersConfig` | `setup-secrets.ps1` in this repo |

Joins them by `vmName`, then for each reachable VM reconciles:

1. **OS groups** - ensures declared groups exist before users are processed;
   supports optional GID pinning (`groupadd`).
2. **OS users** - creates or updates shell, home directory, and supplementary
   groups (`useradd` / `usermod`).
3. **Sudoers rules** - writes or removes `/etc/sudoers.d/{username}`, always
   validated with `visudo -c -f` before going live.

---

## What it does not do

- Provision VMs - use [Infrastructure-Vm-Provisioner] for that.
- Delete users automatically on config removal - use `remove-users.ps1`
  explicitly when you intend to remove accounts (see [Removal](#removal)).
- Move home directories - if `homeDir` changes in config, the directory on
  disk is not relocated (a manual step to avoid data loss).
- Manage SSH keys or PAM configuration.

---

## Requirements

PowerShell 7+ (`pwsh`).

---

## Prerequisites

- **Windows 11** with PowerShell 7+.
- **[Infrastructure-Vm-Provisioner]** has already run - the `VmProvisioner`
  vault and its VMs must exist.
- The **admin user on each VM can run sudo without a password prompt** - SSH
  authentication uses the password from the `VmProvisioner` vault, but once
  connected, sudo must not require a second password entry. This is the
  default for Ubuntu cloud images provisioned with cloud-init (set up
  automatically via `/etc/sudoers.d/90-cloud-init-users`).
- An internet connection on first run (PSGallery is used to install
  `Common.PowerShell`, `Infrastructure.Secrets`, and `Posh-SSH`
  automatically). Posh-SSH is used as the carrier for its bundled
  SSH.NET library; its own cmdlets are not used directly.

---

## Quick start

### 1. Store the config (once per machine)

```powershell
.\hyper-v\ubuntu\setup-secrets.ps1 -ConfigFile C:\private\vm-users-config.json
```

Re-running safely updates the stored config.

### 2. Reconcile users

```powershell
.\hyper-v\ubuntu\create-users.ps1
```

The script is idempotent - re-running it produces the same result and emits
`ok` for everything already in the desired state.

### 3. Remove users

```powershell
.\hyper-v\ubuntu\remove-users.ps1
```

Reads the same `VmUsersConfig` used by `create-users.ps1` and removes every
declared user, their sudoers file, and declared groups from each reachable VM.
See [Removal](#removal) for the sequence and safety guarantees.

---

## Config reference

`VmUsersConfig` is a JSON array - one object per VM, matched to the
provisioner config by `vmName`.

```jsonc
[
  {
    // Must match a vmName in VmProvisionerConfig exactly.
    "vmName": "ubuntu-01-ci",
    // Optional. Declares groups that must exist before users are reconciled.
    // Useful for documenting intent and ensuring groups are created even if
    // no users in this config are members (e.g. a shared directory group
    // managed by Infrastructure-GitHubRunners). Supports optional gid pinning
    // - see fields table below.
    "groups": [
      {
        "groupName": "u-actions-runner"
      }
    ],
    "users": [
      {
        "username": "u-actions-runner",
        // nologin prevents direct SSH login - this account is service-only.
        // Even if credentials were known, the shell rejects interactive
        // sessions. Consuming repos (e.g. Infrastructure-GitHubRunners)
        // act as this user only via sudoers delegation from u-runner-deploy.
        "shell":    "/usr/sbin/nologin",
        "homeDir":  "/home/u-actions-runner",
        // No supplementary groups needed. The primary group u-actions-runner
        // is declared in the groups section above; useradd adopts it via -g
        // rather than creating a new one. u-runner-deploy joins that primary
        // group as a supplementary member for write access.
        "groups":       [],
        // Lines written verbatim to /etc/sudoers.d/{username}.
        // Empty list = file absent (removed if previously present).
        "sudoersRules": []
      },
      {
        "username": "u-runner-deploy",
        // Interactive shell - this account is the SSH entry point used by
        // consuming repos at deploy time. Admin credentials are never
        // required or stored outside the VmProvisioner vault.
        "shell":    "/bin/bash",
        "homeDir":  "/home/u-runner-deploy",
        // Joins u-actions-runner as a supplementary group so it can write
        // into /home/u-actions-runner/runners/ when that directory is set
        // g+rwx by Infrastructure-GitHubRunners. u-actions-runner owns the
        // directory via its primary group - no extra group entry needed there.
        "groups":   ["u-actions-runner"],
        // Optional. When present, written via chpasswd on every run.
        // Comparison against an existing hash is impossible, so overwriting
        // is the only safe approach. This vault entry is the canonical source
        // of the password - consuming repos read from here rather than
        // storing their own copy. Must never appear in console output or
        // SSH command arguments.
        "password": "...",
        // Scoped to exactly the operations Infrastructure-GitHubRunners
        // requires. SSH password auth is the only gate - once authenticated,
        // there is no further challenge before sudo. These rules bound the
        // blast radius: even if u-runner-deploy credentials are compromised,
        // the attacker cannot escalate beyond u-actions-runner or the
        // runner service lifecycle.
        //
        // Rules 1-5: act as u-actions-runner to manage files in its cache dir.
        //   mkdir/rm/curl/tar/test are scoped by binary only - sudoers cannot
        //   restrict by path argument without enabling bypass via symlinks.
        //   The constraint is that the attacker is bounded to whatever
        //   u-actions-runner itself can write.
        //   test is required because the runner user's home dir is mode 700;
        //   checking for a cached tarball must run as that user.
        // Rules 6-7: act as root to create /opt/runners/<name> and transfer
        //   ownership to u-actions-runner. /opt/runners is root-owned so the
        //   runner user cannot create directories there itself.
        // Rule 8: act as root to remove a runner directory under
        //   /opt/runners during deregistration. The wildcard matches one
        //   path component only (sudoers '*' does not match '/'), and
        //   rm refuses '.' and '..', so the blast radius is bounded to
        //   /opt/runners/<single-name>.
        // Rule 9: config.sh registers the runner; runs as u-actions-runner.
        // Rule 10: svc.sh installs/uninstalls the systemd unit; requires root.
        // Rules 11-13: systemctl lifecycle for the runner service.
        "sudoersRules": [
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/mkdir",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/rm",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/curl",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/tar",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/test",
          "u-runner-deploy ALL=(root) NOPASSWD: /usr/bin/mkdir",
          "u-runner-deploy ALL=(root) NOPASSWD: /usr/bin/chown",
          "u-runner-deploy ALL=(root) NOPASSWD: /usr/bin/rm -rf /opt/runners/*",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /opt/runners/*/config.sh",
          "u-runner-deploy ALL=(root) NOPASSWD: /opt/runners/*/svc.sh",
          "u-runner-deploy ALL=(root) NOPASSWD: /bin/systemctl start actions.runner.*",
          "u-runner-deploy ALL=(root) NOPASSWD: /bin/systemctl stop actions.runner.*",
          "u-runner-deploy ALL=(root) NOPASSWD: /bin/systemctl is-active actions.runner.*"
        ]
      }
    ]
  }
]
```

### Required fields

| Field | Description |
|---|---|
| `vmName` | Hyper-V VM name - must match `VmProvisionerConfig` exactly |
| `users[].username` | OS username |
| `users[].shell` | Login shell (e.g. `/bin/bash`, `/usr/sbin/nologin`) |
| `users[].homeDir` | Absolute home directory path |
| `users[].groups` | Array of supplementary group names (may be empty) |
| `users[].sudoersRules` | Array of sudoers rule strings (may be empty) |

### Optional fields

| Field | Description |
|---|---|
| `groups` | Array of group declarations to ensure exist before users are processed |
| `groups[].groupName` | Group name (required within each group entry) |
| `groups[].gid` | Pin the GID - useful for NFS / Docker bind mounts; mismatch is an error |
| `users[].password` | OS password - always written via `chpasswd`; canonical source for consuming repos |

---

## Reconciliation behaviour

`create-users.ps1` is safe to re-run at any time. On each run:

1. VMs missing from `VmProvisionerConfig` are warned and skipped.
2. VMs that do not respond to ping are warned and skipped.
3. For each reachable VM, one SSH session is opened and all reconciliation
   runs within it.
4. **Group reconciliation** runs first. Declared groups are created if absent.
   If a group exists with a different GID than declared, the script throws an
   actionable error - GIDs are not silently changed because the numeric
   ownership stored on files would become stale.
5. **User reconciliation** compares shell and supplementary groups. `homeDir`
   is set only on creation - it is not moved if it changes later.
6. **Sudoers reconciliation** writes to a temp file, validates with
   `visudo -c -f`, then moves the file into place. If validation fails the
   live file is untouched and the script throws.

### Output legend

| Colour | Meaning |
|---|---|
| Cyan | In-progress step |
| Green | Already correct (`ok`) or newly created |
| Yellow | Updated or removed |
| Warning | Skipped (unmatched VM or unreachable) |
| Error | Fatal - script stops |

---

## Removal

`remove-users.ps1` is safe to re-run at any time. It reads the same
`VmUsersConfig` as `create-users.ps1` and removes every declared user and
group from each reachable VM. On each run:

1. VMs missing from `VmProvisionerConfig` are warned and skipped.
2. VMs that do not respond to ping are warned and skipped.
3. For each reachable VM, one SSH session is opened. For each declared user:
   1. **Sudoers removal** - `/etc/sudoers.d/{username}` is deleted if it
      exists. Absence is not an error.
   2. **User removal** - `userdel -r` deletes the account and home directory.
      The implicit primary group (named after the user) is removed
      automatically by `userdel`. Absence is not an error.
4. **Group removal** - declared groups are deleted after all users are gone
   so `groupdel` finds no members. If a group still has members (e.g. a
   user not in this config joined it), the group is warned and skipped rather
   than forcing deletion.

---

## CI

CI runs on pull requests targeting `master` via `.github/workflows/ci.yml`,
which delegates to the shared reusable workflow in
[Common-PowerShell](https://github.com/Klark-Morrigan/Common-PowerShell):

```
Klark-Morrigan/Common-PowerShell/.github/workflows/ci-powershell.yml@master
```

The shared workflow runs `scripts\Run-Tests.ps1` on PowerShell 7.
No additional CI configuration is needed in this repo.

Two more thin workflows lint the YAML and Bash surfaces by delegating to
**Common-Automation**, so the lint config is single-sourced and cannot drift
per repo:

| Workflow | Runs |
|---|---|
| `.github/workflows/ci-yaml.yml` | actionlint, action-validator, yamllint, ansible-lint |
| `.github/workflows/ci-bash.yml` | shellcheck, check-sh-executable, bats |

Each linter auto-skips when its surface is absent. To reproduce the same checks
locally (Git Bash + Docker), three sibling shim commands map to the CI surface:

```bash
# MAIN entry: the full local equivalent of ci-yaml.yml + ci-bash.yml -
# runs the whole lint suite AND the bats tests in one go.
scripts/run-ci-yaml-and-bash.sh              # or double-click scripts\run-ci-yaml-and-bash.bat

# Run a single half - lint only (shellcheck, actionlint, action-validator,
# yamllint, ansible-lint). No PowerShell tests; distinct from Run-Tests.ps1.
scripts/run-lint-yaml-and-bash.sh            # or double-click scripts\run-lint-yaml-and-bash.bat

# Run a single half - the bats tests only.
scripts/run-tests-bash.sh                    # or double-click scripts\run-tests-bash.bat

# Re-stage the +x bit on tracked *.sh files (Windows checkouts drop it,
# tripping the check-sh-executable gate).
scripts/fix-permissions.sh     # or scripts\fix-permissions.bat
```

All three are thin shims over Common-Automation's engine, pointed at this repo
via `COMMON_AUTOMATION_TARGET_REPO`, so a sibling checkout at
`..\Common-Automation` is required. `.gitattributes` pins `*.sh` to LF and
`*.bat` to CRLF - Linux CI runners reject CRLF shebangs.

---

## Repo structure

```
Infrastructure-Vm-Users/
|- .gitattributes           # Pins *.sh to LF and *.bat to CRLF
|- .github/
|  `- workflows/
|     |- ci.yml             # Delegates to shared ci-powershell.yml in Common-PowerShell
|     |- ci-yaml.yml        # Delegates to Common-Automation reusable ci-yaml.yml
|     `- ci-bash.yml        # Delegates to Common-Automation reusable ci-bash.yml
|- hyper-v/
|  `- ubuntu/
|     |- create-users.ps1    # Entry point - reconciles groups, users, and sudoers
|     |- remove-users.ps1    # Entry point - removes users, sudoers, and groups
|     |- setup-secrets.ps1   # One-time vault setup
|     `- reconcile/
|        |- common/          # Shared between create and remove
|        |- up/              # User creation and reconciliation
|        `- down/            # User removal
|- Tests/
|  |- reconcile/
|  |  |- common/             # Unit tests for reconcile/common
|  |  |- up/                 # Unit tests for reconcile/up
|  |  `- down/               # Unit tests for reconcile/down
|  `- Integration/           # Integration tests - one shared SSH session for all reconciliation
|     `- Reconcile.Tests.ps1 # All integration tests (groups, users, sudoers, removal)
|- docs/
|  `- dev/
|     `- implementation/
|        |- 01 - initial implementation/
|        `- 02 - user removal/
|- scripts/
|  |- Run-Tests.ps1          # Runs Pester unit tests (called by ci-powershell.yml)
|  |- Run-IntegrationTests.ps1            # Integration-test runner
|  |- run-ci-yaml-and-bash.sh / run-ci-yaml-and-bash.bat              # MAIN: full local lint + bats (Common-Automation engine)
|  |- run-lint-yaml-and-bash.sh / run-lint-yaml-and-bash.bat          # Lint half only (shellcheck, actionlint, yamllint, ...)
|  |- run-tests-bash.sh / run-tests-bash.bat                          # Bats test half only
|  `- fix-permissions.sh / fix-permissions.bat  # Re-stage +x on tracked *.sh via the shared engine
`- README.md
```

[Common-Ansible]: ../Common-Ansible
[Infrastructure-Vm-Provisioner]: ../Infrastructure-Vm-Provisioner
