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
# The playbook path is given relative to the substrate root because the
# bridge resolves both the playbook and the user roles
# (groups/users/sudoers) from that root.
set -euo pipefail

export CA_INVENTORY_VAULT=VmProvisioner
export CA_EXTRA_VAULTS=VmUsers

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"

exec "${common_ansible_root}/ops/_run-playbook.sh" playbooks/remove-users.yml "$@"
