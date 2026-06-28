# Playbook conventions

Shared rationale for the operator-facing user playbooks under
`playbooks/` ([create-users.yml](../../playbooks/create-users.yml) and
[remove-users.yml](../../playbooks/remove-users.yml)). Each playbook's
header keeps only its per-playbook rationale (role order, what it
reconciles) and points here for the shared posture, so the same posture
is not re-explained in two headers.

## Index

- [`hosts: vm_provisioner_hosts`](#hosts-vm_provisioner_hosts)
- [Fact gathering](#fact-gathering)
- [`any_errors_fatal: false`](#any_errors_fatal-false)
- [Tags mirror role names](#tags-mirror-role-names)
- [Role order lives in the playbook, not meta deps](#role-order-lives-in-the-playbook-not-meta-deps)

## `hosts: vm_provisioner_hosts`

The Common-Ansible substrate bridge
(`ops/virtual-machines/_build-inventory.sh`) drops every host the
operator's `provisioner.json` declares into this group. Both user
playbooks reconcile every provisioned VM by default; operators scope
down with `-l <vm>` when they want a subset.

## Fact gathering

`ansible.builtin.user` and the group/sudoers shell tasks consult facts
(shell / home derivation, distribution detection), so facts must be
present before the roles run.

The two playbooks gather them differently because their first contact
with a VM differs:

- `remove-users.yml` uses `gather_facts: true`. The accounts already
  exist, so a one-shot gather at play start is safe.
- `create-users.yml` sets `gather_facts: false` and instead runs a
  `wait_for_connection` probe followed by an explicit
  `ansible.builtin.setup` in `pre_tasks`. Freshly provisioned VMs are
  reached over a two-hop proxy whose inner hop can stall at banner
  exchange during early boot; a one-shot pre-play gather turns that
  transient into a fatal `UNREACHABLE`. The retrying probe absorbs it,
  then the explicit `setup` restores the facts the roles need.

## `any_errors_fatal: false`

The inventory can contain several VMs, and one host being temporarily
offline should not strand the rest. Per-host failures still surface in
the recap; the play just does not abort the others. Making this
explicit (rather than relying on the Ansible default) guards against a
later edit silently flipping it via a play-level `error_strategy`
override.

## Tags mirror role names

Every `roles:` entry (or `import_role` task) carries a `tags:` value
equal to the role name. Operators scope a partial run with
`--tags <role-name>` without having to learn the playbook layout.

Roles do not coordinate across tag scopes. On the remove direction,
skipping `users` while running `groups` hits the `groups` role's
non-empty-group skip path, which is the intended safety net rather than
a silent mis-reconcile.

## Role order lives in the playbook, not meta deps

The play-level role list (create direction) and the sequence of
`import_role` tasks (remove direction) are the single source of truth
for which roles run in which order:

- `create-users.yml`: `groups -> users -> sudoers` (groups exist before
  users adopt them; users exist before sudoers references them).
- `remove-users.yml`: `sudoers -> users -> groups` (the mirror, so each
  artifact is removed before the thing it depended on).

Roles' `meta/main.yml` files intentionally do **not** carry inter-role
ordering dependencies. Ansible's meta dependencies always run the dep's
`tasks/main.yml` and ignore the entry role's `tasks_from` selector, so a
meta dep like `sudoers -> users` would silently re-create users mid
teardown when `remove-users.yml` imports `sudoers` with
`tasks_from: remove`.

The only meta dep the roles carry is the direction-neutral
[`vm_users_entry`](../../roles/vm_users_entry) helper, which sets the
shared `vm_users_entry` fact but does not own playbook-level ordering.
