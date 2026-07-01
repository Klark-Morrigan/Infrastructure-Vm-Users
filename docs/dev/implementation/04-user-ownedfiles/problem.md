# Problem: User-owned file copies in Vm-Users

## Index

- [Context](#context)
- [What this step must deliver](#what-this-step-must-deliver)
- [Why here, not in the provisioner](#why-here-not-in-the-provisioner)
- [What stays the same](#what-stays-the-same)
- [Out of scope](#out-of-scope)
- [For laymen](#for-laymen)

---

## Context

`Infrastructure-Vm-Provisioner` (feature 05 - "Java Dev Kit") added an
optional `files` array on its VM JSON definition. Each entry is a
`{ source, target }` pair: a host file path and a destination Linux path
on the VM. Those copies run as part of provisioning, so every file lands
`root:root, 0644`. The provisioner cannot place a file *as a specific
app user* because the app users do not exist yet at provisioning time -
they are created by this repo (Vm-Users) in a later step.

The transport itself (file-server + SSH + per-entry curl + chown +
chmod) and the shared schema validator live in `Infrastructure.HyperV`
(`Copy-VmFiles`, `Assert-VmFilesField`). The provisioner consumes those
primitives with the default policy "source + target only, no owner".
Vm-Users will consume the same primitives with an extended policy that
adds `owner`.

---

## What this step must deliver

- A new optional `files` array on the Vm-Users JSON definition. Same
  base shape as the provisioner's, with one additional sub-field:
  `owner` (required when the array is used).
- Schema validation that:
  - Uses `Assert-VmFilesField` from Infrastructure.HyperV for the shared
    shape checks (source/target/array/object/path-existence/strict
    sub-fields).
  - Extends the allow-list with `owner`.
  - Adds a `PostEntryValidator` that enforces `owner` is required AND
    references a user this repo is creating on the same VM (cross-field
    check inside the same VM entry).
- A post-reconciliation step that, for each VM whose entry has a
  non-empty `files`, opens the existing file-server + SSH pattern and
  calls `Copy-VmFiles` with `-Entries` constructed as
  `{ Source, Target, Owner = "<owner>:<owner>" }`. Defaults `Mode` to
  `0640` (group-readable for the owning user's primary group; not
  world-readable because user-owned files often carry secrets).
- README updates documenting the new field, its contract, and the
  ownership model split with the provisioner.

---

## Why here, not in the provisioner

The provisioner has no way to chown to an app user because no app users
exist when it runs. Putting user-owned copies here keeps each repo's
contract honest:

| Repo | Owns | When users exist |
|---|---|---|
| `Vm-Provisioner` | "the box's software": JDK install, root-owned files | No app users yet |
| `Vm-Users` | "people and their stuff": app users, sudoers, user-owned files | App users created in this run |

The split mirrors what already exists for users vs. OS-level software.

---

## What stays the same

- The transport stack (`Copy-VmFiles`, `Assert-VmFilesField`,
  `Invoke-WithVmFileServer`, `Add-VmFileServerFile`, SSH client) is not
  duplicated - this repo consumes Infrastructure.HyperV.
- The provisioner's existing `files` field and its `root:root, 0644`
  default policy are unchanged. The two arrays coexist on different
  vault entries (different `Vault`/`SecretName` pairs).
- No changes to user creation, sudoers handling, or the
  `Invoke-VmUsersTest` E2E shape beyond the new dispatch line.

---

## Out of scope

- Per-file `mode` override in the JSON. v1 fixes the mode at `0640`. If
  a future use case needs a different mode, extend `Assert-VmFilesField`'s
  allow-list here and pass `Mode` through to `Copy-VmFiles` - the
  primitive already accepts it.
- Group ownership separate from the user. v1 uses `<owner>:<owner>` so
  the file is owned by the user's primary group too. A future `group`
  sub-field can be added the same way `owner` is being added in v1.
- Templating / content substitution. `files` ships bytes verbatim; the
  user is expected to materialise the host file with whatever content
  they want before running this repo.
- File removal. v1 only adds files. The cleanup story (what happens to
  a file when its entry is removed from `files`?) is deferred until a
  concrete use case appears.
- Cross-VM file copies. Each entry is scoped to its parent VM entry's
  reachable host.

---

## For laymen

The companion repo (`Infrastructure-Vm-Provisioner`) already lets you
say "put this file from my Windows machine onto this Linux VM at this
path". But because that step runs before any user accounts are made,
every file it places ends up owned by `root` and readable by everyone.
That's fine for shared libraries (anyone can read `/opt/lib/foo.jar`)
but wrong for anything user-private (an SSH key, a deploy secret).

This repo creates the user accounts on those VMs. The natural next thing
it can do, once a user exists, is place files *as that user* with
restricted permissions. That is what this feature adds: a parallel
`files` array in this repo's config, with an extra `owner` field
saying "the file belongs to this user".
