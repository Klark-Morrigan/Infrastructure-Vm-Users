# Implementation Plan

## Index
- [Step 1 - Repo skeleton](#step-1---repo-skeleton)
- [Step 2 - setup-secrets.ps1](#step-2---setup-secretsps1)
- [Step 3 - create-users.ps1: vault read + validation](#step-3---create-usersps1-vault-read--validation)
- [Step 4 - create-users.ps1: user reconciliation via SSH](#step-4---create-usersps1-user-reconciliation-via-ssh)
- [Step 5 - create-users.ps1: sudoers reconciliation](#step-5---create-usersps1-sudoers-reconciliation)
- [Step 6 - README.md](#step-6---readmemd)

---

## Step 1 - Repo skeleton

**What:** Create directory structure and placeholder files.

```
hyper-v/
└── ubuntu/
    ├── setup-secrets.ps1
    └── create-users.ps1
```

**Why:** Follows the `hypervisor/guest-os/` convention from
Infrastructure-Vm-Provisioner. Additional hypervisors or guest OSes slot
in as new subdirectories without changing the root structure.

```mermaid
graph TD
    subgraph Repo["Infrastructure-Vm-Users"]
        HV[hyper-v/]
        HV --> UB[ubuntu/]
        UB --> SS[setup-secrets.ps1]
        UB --> CU[create-users.ps1]
        HV -.-> OHV[other-hypervisor/ ...]
        UB -.-> OOS[other-os/ ...]
    end
```

---

## Step 2 - setup-secrets.ps1

**What:** Script that installs `Infrastructure.Secrets` from PSGallery and
calls `Initialize-InfrastructureVault` with:
- Vault: `VmUsers`
- Secret: `VmUsersConfig`
- Validation: checks required fields per VM entry

**Config schema** - desired users per VM, matched to provisioner VMs by
`vmName`:
```jsonc
[
  {
    "vmName": "ubuntu-01-ci",
    "users": [
      {
        "username":     "u-actions-runner",
        "shell":        "/usr/sbin/nologin",
        "homeDir":      "/home/u-actions-runner",
        "groups":       [],
        "sudoersRules": []
      },
      {
        "username":     "u-runner-deploy",
        "shell":        "/bin/bash",
        "homeDir":      "/home/u-runner-deploy",
        "groups":       [],
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

```mermaid
sequenceDiagram
    participant SS as setup-secrets.ps1
    participant PSG as PSGallery
    participant V as VmUsers vault

    SS->>PSG: Install-Module Infrastructure.Secrets (if missing)
    PSG-->>SS: module installed
    SS->>V: Initialize-InfrastructureVault (create + store config)
    V-->>SS: ok
```

---

## Step 3 - create-users.ps1: vault read + validation

**What:** Opening section of `create-users.ps1` that:
1. Reads `VmProvisionerConfig` from the `VmProvisioner` vault - VM names,
   IPs, and admin credentials.
2. Reads `VmUsersConfig` from the `VmUsers` vault - desired users per VM.
3. Joins the two by `vmName` - warns and skips any VM in `VmUsersConfig`
   that has no matching entry in `VmProvisionerConfig`.
4. Checks each matched VM with a ping - warns if unreachable, skips.
5. Emits structured output for each decision.

**Why:** Reading admin credentials from the existing `VmProvisioner` vault
avoids duplication and prompting. Joining by `vmName` keeps the two vaults
independent - either can change without the other needing to be updated.

```mermaid
sequenceDiagram
    participant P as create-users.ps1
    participant VP as VmProvisioner vault
    participant VU as VmUsers vault
    participant N as Network

    P->>VP: Get-Secret VmProvisionerConfig
    VP-->>P: VM list + admin creds
    P->>VU: Get-Secret VmUsersConfig
    VU-->>P: desired users per VM
    P->>P: join by vmName
    P->>N: Test-Connection per VM
    N-->>P: reachable / unreachable
```

---

## Step 4 - create-users.ps1: user reconciliation via SSH

**What:** For each matched, reachable VM, for each desired user:
1. Check if the user exists (`id {username}`).
2. If not: `useradd` with the specified shell, home directory, and groups.
3. If yes: check shell and groups match desired state; update if not
   (`usermod`).
4. Emit a per-user result line: `created`, `updated`, or `ok`.

**Why:** Reconciling rather than just creating means re-running is always
safe and drifted config (e.g. shell changed manually) is corrected.

```mermaid
sequenceDiagram
    participant P as create-users.ps1
    participant VM as Ubuntu VM (per user)

    P->>VM: id {username}
    alt user missing
        VM-->>P: not found
        P->>VM: useradd -s -d -G
        VM-->>P: created
    else user exists
        VM-->>P: found
        P->>VM: getent passwd / id -Gn
        VM-->>P: current shell + groups
        alt shell or groups drifted
            P->>VM: usermod -s -G
            VM-->>P: updated
        else already correct
            VM-->>P: ok - skip
        end
    end
```

---

## Step 5 - create-users.ps1: sudoers reconciliation

**What:** For each user, after user creation/update:
1. Read current rules from `/etc/sudoers.d/{username}` (empty if file
   absent).
2. Compare with desired rules.
3. If different: rewrite the file with desired rules, `chmod 0440`,
   validate with `visudo -c -f` - abort and restore previous content
   if invalid.
4. If identical: skip.
5. Emit a per-user result: `sudoers updated`, `sudoers removed` (if desired
   is empty and file existed), or `sudoers ok`.

**Why:** Full reconciliation (not just append) ensures rules removed from
the config are also removed from the VM. `visudo -c` validation prevents a
broken sudoers from locking out all sudo access.

```mermaid
sequenceDiagram
    participant P as create-users.ps1
    participant VM as Ubuntu VM (per user)

    P->>VM: cat /etc/sudoers.d/{username}
    VM-->>P: current rules (or empty)
    alt rules match desired
        P->>P: sudoers ok - skip
    else desired is empty
        P->>VM: rm /etc/sudoers.d/{username}
        VM-->>P: removed
    else rules differ
        P->>VM: write new rules + chmod 0440
        P->>VM: visudo -c -f
        alt valid
            VM-->>P: ok
        else invalid
            P->>VM: restore previous content
            VM-->>P: rolled back
        end
    end
```

---

## Step 6 - README.md

**What:** Root `README.md` covering:
- What this repo does and what it does not do.
- Prerequisites (Windows 11, OpenSSH, VMs provisioned,
  `VmProvisioner` vault already set up).
- Quick start (setup-secrets -> create-users).
- JSON config reference with a runner users example.
- Idempotency and reconciliation behaviour.
- Repo structure.

**Why:** Required after each step per global instructions; primary
onboarding document for the repo.

```mermaid
graph TD
    subgraph Docs["Documentation"]
        README[README.md] -->|references| SS[setup-secrets.ps1]
        README -->|references| CU[create-users.ps1]
        README -->|references| VP[Infrastructure-Vm-Provisioner]
        README -->|references| GR[Infrastructure-GitHubRunners]
    end
```
