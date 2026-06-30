#!/usr/bin/env bash
# Operator wrapper for the Ansible create-users flow. The flow's heavy
# lifting (tmpdir, venv activation, vault reads, inventory, extra-vars,
# dispatch) lives in the Common-Ansible substrate bridge, consumed as a
# sibling checkout (see README "Consuming Common-Ansible"). This wrapper
# (1) locates that bridge via the 3.1 root resolver, (2) DECLARES its
# needs to the consumer-agnostic bridge through the CA_* contract, and
# (3) hands the bridge the create-users playbook path; forwarded args
# follow it so operators can pass --tags, --limit, --check, -v, etc.
#
# CA contract: the fleet inventory lives in the VmProvisioner vault and
# the user roles' extra-vars come from the VmUsers vault on top of it.
# The bridge names no vault itself, so naming them here is what couples
# this flow - not the substrate - to its own vault layout. No token and
# no host file server: the user flow needs neither.
#
# This repo owns the create-users playbook and the user roles
# (groups/users/sudoers), so it declares CA_CONSUMER_ROOT as its own repo
# root. The bridge then resolves the playbook, those roles, and the VmUsers
# extra-vars fragment from here rather than from the substrate - the
# substrate carries no user domain. The playbook path is given relative to
# that consumer root.
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

exec "${common_ansible_root}/ops/_run-playbook.sh" playbooks/create-users.yml "$@"
