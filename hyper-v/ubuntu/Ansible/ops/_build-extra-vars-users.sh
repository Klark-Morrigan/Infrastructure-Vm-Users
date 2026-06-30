#!/usr/bin/env bash
# Per-domain extra-vars helper: users. Owned by Infrastructure-Vm-Users
# (the user domain's home) and consumed by the Common-Ansible substrate
# composer (ops/_build-extra-vars.sh), which dispatches the VmUsers vault
# to this fragment.
#
# Emits the single top-level key `vm_users_config` consumed by the
# groups / users / sudoers roles.
#
# Output (stdout): {"vm_users_config": <document>}

set -euo pipefail

# The shared input gate and the unknown-flag handler are generic substrate
# helpers, not user-domain code, so they live in Common-Ansible and are
# reached through the 3.1 sibling-checkout resolver rather than duplicated
# here. The resolver sets `common_ansible_root` once per run.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_validate-extra-vars-input.sh"
# shellcheck source=/dev/null
source "${common_ansible_root}/ops/_die-on-unknown-flag.sh"

users_path=""

usage() {
    echo "usage: _build-extra-vars-users.sh --users-config <path>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --users-config)
            users_path="${2:-}"
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ -z "${users_path}" ]]; then
    usage
    exit 2
fi

_validate_extra_vars_input --users-config "${users_path}"

jq -n --slurpfile u "${users_path}" '{vm_users_config: $u[0]}'
