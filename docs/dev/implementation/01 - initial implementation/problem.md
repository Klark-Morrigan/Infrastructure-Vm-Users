# Problem

## Index
- [Summary](#summary)
- [For laymen](#for-laymen)
- [Detail](#detail)

---

## Summary

VMs provisioned by Infrastructure-Vm-Provisioner arrive with only a single
admin user. Other infrastructure repos (e.g. Infrastructure-GitHubRunners)
need dedicated service and deploy users with specific permissions - but those
repos must not require admin credentials at runtime.

---

## Detail

### What needs to happen on each VM

1. Read VM connection details (IP, admin credentials) from the existing
   `VmProvisioner` vault.
2. Read the desired user list per VM from this repo's own `VmUsers` vault.
3. For each VM, reconcile groups against the desired state:
   - Groups that do not exist are created, optionally with a pinned GID.
     GID pinning is needed when multiple machines share storage (NFS, Docker
     bind mounts) - ownership is stored on disk as a number, not a name, so
     all machines must agree on the number. For local-only storage the OS can
     assign the GID freely.
   - A GID mismatch on an existing group is an error, not a silent fix.
     Changing a GID with groupmod does not update the numeric ownership
     already stored on files - those files become owned by a phantom ID until
     manually corrected with find + chown.
4. For each VM, reconcile users against the desired state:
   - Users that do not exist are created with the specified shell, home
     directory, and groups.
   - Sudoers rules are compared: missing rules are added, extra rules
     are removed.
   - Users that already match desired state are skipped.

### Inputs required

| Input | Source |
|---|---|
| VM IP address, admin username + password | `VmProvisioner` vault |
| Desired users + sudoers rules per VM | `VmUsers` vault (this repo) |

### Constraints

- Script runs on Windows, communicates with VMs via SSH (`ssh.exe` from
  Windows OpenSSH, built into Windows 11).
- Re-running must be safe: existing users and rules that already match
  desired state are left untouched.
- This repo has no knowledge of what the users will be used for - all
  configuration is caller-supplied via the vault JSON.
- Passwords for created users are set by the operator outside this script
  and stored in the consuming repo's vault.
