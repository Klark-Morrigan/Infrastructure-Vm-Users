# Plan: Drop PowerShell 5.1 Support

See [problem.md](problem.md) for the full problem statement.

## Index

- [Step 1 - Code compromises and tests](#step-1---code-compromises-and-tests)
- [Step 2 - Version pins and documentation](#step-2---version-pins-and-documentation)

---

## Step 1 - Code compromises and tests

**Why:** Removes all PS 5.1-specific workarounds from production code and
cleans up stale rationale from comments and test names. Must precede Step 2
so the tests validate the updated code before documentation is changed.

### Changes

#### `hyper-v/ubuntu/reconcile/common/ConvertFrom-VmUsersConfigJson.ps1`

| Location | Change |
|----------|--------|
| Line 44 | Remove "PS 5.1-compatible Get-Member loop" from comment — `Assert-RequiredProperties` still handles `IsNullOrWhiteSpace`; only the PS version rationale is stale |
| Line 59 | `(Get-Member -InputObject $entry -MemberType NoteProperty).Name` → `$entry.PSObject.Properties.Name` |

#### `hyper-v/ubuntu/reconcile/up/Invoke-GroupReconciliation.ps1`

| Location | Change |
|----------|--------|
| Line 54 | Shorten comment to "gid is optional - guard the property before accessing it." (remove StrictMode/PSCustomObject mention, already obvious) |
| Line 56 | `(Get-Member -InputObject $group -MemberType NoteProperty).Name` → `$group.PSObject.Properties.Name` |

#### `hyper-v/ubuntu/reconcile/up/Invoke-UserReconciliation.ps1`

| Location | Change |
|----------|--------|
| Lines 37-40 | Rewrite comment block: remove "Get-Member" mention; keep the important note about not using the if/else expression form (the empty `@()` / StrictMode reason still applies in PS 7) |
| Line 41 | `(Get-Member -InputObject $User -MemberType NoteProperty).Name` → `$User.PSObject.Properties.Name` |
| Line 42 | Remove "PS 5.1 single-element JSON unwrapping" — `@()` stays, only the PS version rationale is removed |
| Line 137 | "that handles empty arrays correctly in PS 5.1." → "for a simple equality check that handles empty arrays." |

#### `hyper-v/ubuntu/reconcile/up/Invoke-SudoersReconciliation.ps1`

| Location | Change |
|----------|--------|
| Lines 38-43 | Rewrite comment block: remove "Get-Member" mention; keep the note about the if/else expression form |
| Line 44 | `(Get-Member -InputObject $User -MemberType NoteProperty).Name` → `$User.PSObject.Properties.Name` |
| Line 45 | Remove "PS 5.1 single-element JSON unwrapping" |

#### `hyper-v/ubuntu/reconcile/up/Invoke-VmUserCreate.ps1`

| Location | Change |
|----------|--------|
| Lines 39-41 | Rewrite comment: "guards the optional 'groups' property without triggering StrictMode on a missing key." (remove "Get-Member" mention) |
| Line 42 | `(Get-Member -InputObject $Entry -MemberType NoteProperty).Name` → `$Entry.PSObject.Properties.Name` |

#### `hyper-v/ubuntu/reconcile/down/Invoke-VmUserRemove.ps1`

| Location | Change |
|----------|--------|
| Lines 37-39 | Same rewrite as `Invoke-VmUserCreate.ps1` lines 39-41 |
| Line 40 | `(Get-Member -InputObject $Entry -MemberType NoteProperty).Name` → `$Entry.PSObject.Properties.Name` |

#### `Tests/reconcile/common/ConvertFrom-VmUsersConfigJson.Tests.ps1`

| Location | Change |
|----------|--------|
| Line 55 | Rename: "normalises a bare JSON object to a 1-element array (PS 5.1 unwrap)" → "normalises a bare JSON object to a 1-element array" |
| Lines 56-58 | Remove the PS 5.1 inline comment; keep the description of what `ConvertTo-Array` does |

### Tests

Run `Run-Tests.ps1`. All tests must pass.

---

## Step 2 - Version pins and documentation

**Why:** Aligns the bootstrap guards and module install pins with the new
major versions released as part of this family-wide PS 5.1 drop, and
updates operator-facing documentation to reflect the new PS 7+ requirement.

### Changes

| File | Location | Change |
|------|----------|--------|
| `hyper-v/ubuntu/setup-secrets.ps1` | Line 60 | `[Version]'1.3.3'` → `[Version]'2.0.0'` |
| `hyper-v/ubuntu/setup-secrets.ps1` | Line 71 | `MinimumVersion '2.1.0'` → `'3.0.0'` |
| `hyper-v/ubuntu/create-users.ps1` | Line 34 | `[Version]'1.3.3'` → `[Version]'2.0.0'` |
| `hyper-v/ubuntu/remove-users.ps1` | Line 39 | `[Version]'1.3.3'` → `[Version]'2.0.0'` |
| `README.md` | Index | Add `- [Requirements](#requirements)` entry |
| `README.md` | After Overview | Add Requirements section: "PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 is not supported." |
| `README.md` | Prerequisites line | "Windows 11 with PowerShell 5.1 or later." → "Windows 11 with PowerShell 7+." |
| `README.md` | CI section | Remove mention of PS 5.1 test job |

### Tests

Run `Run-Tests.ps1`. All tests must pass.
