# Infrastructure-Vm-Users

Reconciles OS users on Ubuntu Hyper-V VMs against a desired state stored in
a local encrypted vault.

## Index

- [What this repo does](#what-this-repo-does)
- [What it does not do](#what-it-does-not-do)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Config reference](#config-reference)
- [Reconciliation behaviour](#reconciliation-behaviour)
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
- Delete users - removal must be done manually to prevent accidental data
  loss.
- Move home directories - if `homeDir` changes in config, the directory on
  disk is not relocated (a manual step to avoid data loss).
- Manage SSH keys or PAM configuration.

---

## Prerequisites

- **Windows 11** with PowerShell 5.1 or later.
- **[Infrastructure-Vm-Provisioner]** has already run - the `VmProvisioner`
  vault and its VMs must exist.
- The **admin user on each VM can run sudo without a password prompt** - SSH
  authentication uses the password from the `VmProvisioner` vault, but once
  connected, sudo must not require a second password entry. This is the
  default for Ubuntu cloud images provisioned with cloud-init (set up
  automatically via `/etc/sudoers.d/90-cloud-init-users`).
- An internet connection on first run (PSGallery is used to install
  `Infrastructure.Common`, `Infrastructure.Secrets`, and `Posh-SSH`
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
        // Broad sudo rules for mkdir/tar are avoided: wildcard paths make
        // them exploitable via path manipulation.
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
        // there is no further challenge before sudo. These four rules bound
        // the blast radius: even if u-runner-deploy credentials are
        // compromised, the attacker cannot escalate beyond them.
        "sudoersRules": [
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /home/u-actions-runner/runners/*/config.sh",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /home/u-actions-runner/runners/*/svc.sh",
          "u-runner-deploy ALL=(root) NOPASSWD: /bin/systemctl start actions.runner.*",
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

## CI

CI runs on pull requests targeting `master` via `.github/workflows/ci.yml`,
which delegates to the shared reusable workflow in
[Infrastructure-Common](https://github.com/VitaliiAndreev/Infrastructure-Common):

```
VitaliiAndreev/Infrastructure-Common/.github/workflows/ci-powershell.yml@master
```

The shared workflow runs `Run-Tests.ps1` on both PowerShell 5.1 and 7.
No additional CI configuration is needed in this repo.

---

## Repo structure

```
Infrastructure-Vm-Users/
|- .github/
|  `- workflows/
|     `- ci.yml                  # Delegates to shared ci-powershell.yml in Infrastructure-Common
|- hyper-v/
|  `- ubuntu/
|     |- create-users.ps1        # Entry point - reconciles groups, users, and sudoers
|     |- setup-secrets.ps1       # One-time vault setup
|     |- common.ps1              # Shared helpers (dot-sourced, not run directly)
|     |- reconcile-groups.ps1    # Group reconciliation logic
|     |- reconcile-users.ps1     # User reconciliation logic
|     `- reconcile-sudoers.ps1   # Sudoers reconciliation logic
|- Tests/               # Pester unit tests
|- docs/
|  `- dev/
|     `- implementation/
|        `- 01 - initial implementation/
|           |- problem.md
|           `- plan.md
|- Run-Tests.ps1     # Runs Pester tests (called by ci-powershell.yml)
`- README.md
```

[Infrastructure-Vm-Provisioner]: ../Infrastructure-Vm-Provisioner
