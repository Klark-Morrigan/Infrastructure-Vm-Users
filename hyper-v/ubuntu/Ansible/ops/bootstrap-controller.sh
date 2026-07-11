#!/usr/bin/env bash
# Thin consumer bootstrap shim for Infrastructure-Vm-Users. Runs inside WSL.
#
# The bootstrap logic is a SSOT in the Common-Ansible substrate
# (ops/bootstrap-controller-consumer.sh), reached through the sibling checkout;
# this shim only resolves the substrate and hands it this repo's Ansible-slice
# root (for the roles-path summary). Kept per-repo so `bootstrap-controller
# (Ansible)` is a uniform menu entry across the substrate consumers.
set -euo pipefail

script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ansible_root="$(cd "${script_dir}/.." && pwd)"

# Locate the substrate sibling (override with COMMON_ANSIBLE_ROOT).
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"

exec "${common_ansible_root}/ops/bootstrap-controller-consumer.sh" "${ansible_root}"
