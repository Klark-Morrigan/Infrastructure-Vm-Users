#!/usr/bin/env bash
# Operator wrapper for the Ansible remove-users flow. Mirror of
# create-users.sh: every concern (tmpdir, venv activation, vault reads,
# inventory, extra-vars, dispatch) lives in the Common-Ansible substrate
# bridge, consumed as a sibling checkout (see README "Consuming
# Common-Ansible"). This wrapper locates the bridge via the 3.1 root
# resolver, declares its CA_* contract, and hands the bridge the
# remove-users playbook. Forwarded args follow it so operators can pass
# --tags, --limit, --check, -v, etc.
#
# Same CA_* contract as the create side - the down direction reads the
# same VmProvisioner inventory and VmUsers vault, just composing the
# roles in reverse - so the declaration is identical.
#
# No confirmation prompt: the destructive intent lives in the script
# name and in the operator's choice to invoke it.
#
# This repo owns the remove-users playbook and the user roles
# (groups/users/sudoers), so it declares CA_CONSUMER_ROOT as its own repo
# root. The bridge then resolves the playbook, those roles, and the VmUsers
# extra-vars fragment from here rather than from the substrate. The playbook
# path is given relative to that consumer root.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This repo's root (ops/ -> repo root): the consumer root the bridge
# resolves the playbook, roles, and fragment from.
CA_CONSUMER_ROOT="$(cd "${script_dir}/.." && pwd)"

export CA_INVENTORY_VAULT=VmProvisioner
export CA_EXTRA_VAULTS=VmUsers
export CA_CONSUMER_ROOT

# shellcheck source=ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"

exec "${common_ansible_root}/ops/_run-playbook.sh" playbooks/remove-users.yml "$@"
