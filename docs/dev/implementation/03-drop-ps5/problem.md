# Problem: Drop PowerShell 5.1 Support

## Index

- [Context](#context)
- [What changes](#what-changes)
  - [Code compromises to remove](#code-compromises-to-remove)
  - [Comments to update](#comments-to-update)
  - [Version pins to bump](#version-pins-to-bump)
  - [Documentation](#documentation)
- [What stays](#what-stays)
- [Out of scope](#out-of-scope)

---

## Context

Common-PowerShell (2.0.0), Infrastructure-Secrets (3.0.0), and
Infrastructure-Vm-Provisioner have all dropped PS 5.1 support.
Infrastructure-Vm-Users is the remaining repo in the family that still
declares and codes for PS 5.1 compatibility.

The shared CI workflow (`ci-powershell.yml@master`) now runs only on PS 7,
so the PS 5.1 test job is already gone at the CI layer. The remaining work
is to remove the in-code compromises and update documentation.

---

## What changes

### Code compromises to remove

Six production files use `Get-Member -MemberType NoteProperty` to read
property names. This was required in PS 5.1 because accessing a missing
property under `Set-StrictMode -Version Latest` throws; `Get-Member`
silently returns nothing instead. In PS 7, `PSObject.Properties` is the
idiomatic equivalent and reads in insertion order (unlike `Get-Member`,
which returns properties alphabetically).

| File | Pattern to replace |
|------|--------------------|
| `hyper-v/ubuntu/reconcile/common/ConvertFrom-VmUsersConfigJson.ps1` | `(Get-Member -InputObject $entry -MemberType NoteProperty).Name` |
| `hyper-v/ubuntu/reconcile/up/Invoke-GroupReconciliation.ps1` | `(Get-Member -InputObject $Group -MemberType NoteProperty).Name` |
| `hyper-v/ubuntu/reconcile/up/Invoke-UserReconciliation.ps1` | `(Get-Member -InputObject $User -MemberType NoteProperty).Name` |
| `hyper-v/ubuntu/reconcile/up/Invoke-SudoersReconciliation.ps1` | `(Get-Member -InputObject $User -MemberType NoteProperty).Name` |
| `hyper-v/ubuntu/reconcile/up/Invoke-VmUserCreate.ps1` | `(Get-Member -InputObject $Entry -MemberType NoteProperty).Name` |
| `hyper-v/ubuntu/reconcile/down/Invoke-VmUserRemove.ps1` | `(Get-Member -InputObject $Entry -MemberType NoteProperty).Name` |

Replacement: `$obj.PSObject.Properties.Name` (same containment checks, no
functional change).

### Comments to update

Stale PS 5.1 rationale in production code and tests:

| File | Change |
|------|--------|
| `create-users.ps1` | Remove "PS 5.1 single-element JSON unwrapping" from `@()` comment |
| `remove-users.ps1` | Same |
| `Invoke-UserReconciliation.ps1` | Two comments: `@()` normalization and empty-array handling |
| `Invoke-SudoersReconciliation.ps1` | `@()` normalization comment |
| `ConvertFrom-VmUsersConfigJson.ps1` | Reference to "PS 5.1-compatible Get-Member loop" |
| `Tests/.../ConvertFrom-VmUsersConfigJson.Tests.ps1` | Test name "normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)" and its inline comment |

### Version pins to bump

`setup-secrets.ps1` pins minimum versions for the two upstream modules.
Both have had major-version bumps as part of this family-wide PS 5.1 drop:

| Module | Old pin | New pin |
|--------|---------|---------|
| `Common.PowerShell` | `1.3.3` | `2.0.0` |
| `Infrastructure.Secrets` | `2.1.0` | `3.0.0` |

### Documentation

| File | Change |
|------|--------|
| `README.md` | Prerequisites: "PowerShell 5.1 or later" -> "PowerShell 7+"; add Requirements section with index entry; CI section: remove mention of PS 5.1 job |

---

## What stays

- **`@()` wrapping** around `ConvertFrom-Json` output and function return
  values. This is still good practice in PS 7: it guarantees an array
  type for downstream pipeline operations regardless of element count.
  Only the PS 5.1 rationale in comments is removed; the code stays.
- **Direct SSH.NET usage** instead of Posh-SSH cmdlets. This is the
  correct approach for unrelated reasons (see memory: Posh-SSH 3.x KEX
  issue on Ubuntu 24.04) and is unrelated to PS 5.1.

---

## Out of scope

- Behaviour changes to reconciliation logic.
- Changes to integration tests or the Docker-based test environment.
