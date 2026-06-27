# Problem: User Removal

## Index

- [For laymen](#for-laymen)
- [Context](#context)
- [What is missing](#what-is-missing)
- [Constraints](#constraints)
- [Out of scope](#out-of-scope)

---

## For laymen

When we provision a VM we create service accounts (users) on it. Currently
there is no automated way to remove those accounts when they are no longer
needed - for example when a VM is being rebuilt or a service is retired.
Without tooling, operators have to remember to manually delete each account,
its home directory, its sudoers file, and any groups that were created for it.
Missing any step leaves behind orphaned permissions or disk space. This
feature adds `remove-users.ps1` as the exact reverse of `create-users.ps1`.

---

## Context

`create-users.ps1` reconciles OS users on Ubuntu VMs against a desired
state stored in the `VmUsers` vault. It creates and updates users, groups,
and sudoers files. It is idempotent: re-running it is always safe.

`remove-users.ps1` reads the same vault config and removes every resource
that `create-users.ps1` would have created, in reverse dependency order:

1. Sudoers files (`/etc/sudoers.d/<username>`)
2. User accounts and home directories (`userdel -r`)
3. Declared groups (`groupdel`)

---

## What is missing

- No `remove-users.ps1` entry point exists.
- No per-resource removal helpers exist (`Remove-VmSudoers`,
  `Remove-VmUsers`, `Remove-VmGroups`).
- No per-VM orchestrator for removal exists.
- The `reconcile/` folder is flat, making it harder to navigate as both
  create and remove helpers accumulate. It needs the same layered structure
  (`common/`, `up/`, `down/`) used in Infrastructure-GitHubRunners.

---

## Constraints

- **Groups shared by other users must not be deleted.** Only declared
  groups (listed in the `groups` array of the config entry) are candidates
  for removal, and only after confirming they have no remaining members.
  Implicit groups (auto-created by `useradd` matching the username) are
  removed automatically when the user is deleted.
- **Removal is destructive.** `userdel -r` deletes the home directory and
  its contents. Callers must ensure data has been migrated before running.
- **No force mode initially.** Unlike the GitHubRunners deregistration,
  there is no GitHub-side state to clean up when a VM is unreachable.
  Unreachable VMs are warned and skipped.
- The same vault config drives both create and remove. There is no
  separate "removal config" - the presence of a VM entry in `VmUsersConfig`
  is the source of truth for what exists (and therefore what can be removed).

---

## Out of scope

- Removing users not listed in the vault config (manual cleanup).
- Force-removing users who have running processes.
- Migrating home directory data before removal.
- UID/GID reconciliation (already out of scope for creation).
