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
3. For each VM, reconcile users against the desired state:
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
