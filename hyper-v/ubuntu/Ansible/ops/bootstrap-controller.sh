#!/usr/bin/env bash
# Consumer-side controller bootstrap for Infrastructure-Vm-Users. Runs inside
# WSL.
#
# This repo consumes Common-Ansible as a sibling checkout: the substrate's
# reusable roles AND its ops bridge are reached from one resolved root (see
# ops/imports/_common-ansible-root.sh). The roles are not standalone - they
# read the bridge's extra-vars/inventory contract - so roles and bridge are
# taken together through the one checkout, not split across transports.
#
# The bootstrap is thin: it (1) locates the substrate sibling and (2) makes
# sure the shared controller (the venv + ansible-core + substrate collections
# that Common-Ansible's own bootstrap builds) exists, reusing it rather than
# forking it. There is nothing to install for this repo - the user roles
# live in this repo's roles/ and resolve at play time: the flow wrappers
# declare CA_CONSUMER_ROOT and the substrate bridge puts this repo's roles/
# ahead of the substrate's on ANSIBLE_ROLES_PATH (see the README).
set -euo pipefail

# Anchor to this script's directory via parameter expansion (not dirname) so
# it works regardless of the caller's working directory and even on a
# locked-down PATH.
script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# Locate the substrate sibling (override with COMMON_ANSIBLE_ROOT).
# shellcheck source=ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"

venv_python="${common_ansible_root}/.venv/bin/python"

# Ensure the shared controller exists. When the substrate venv is absent,
# delegate to the substrate's own public bootstrap rather than rebuilding the
# venv here - that script owns the WSL2/bash gates, venv creation, and the
# substrate collection pins. It is a Windows entry point, so reach it through
# pwsh.exe (already a hard controller dependency) with a Windows path from
# wslpath.
if [[ ! -x "${venv_python}" ]]; then
    echo "Substrate controller venv not found at ${common_ansible_root}/.venv" >&2
    echo "Bootstrapping the shared Common-Ansible controller first ..." >&2
    substrate_bootstrap_win="$(wslpath -w "${common_ansible_root}/ops/bootstrap-controller.ps1")"
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "${substrate_bootstrap_win}"
fi

if [[ ! -x "${venv_python}" ]]; then
    echo "Controller bootstrap did not produce ${venv_python}." >&2
    echo "Bootstrap the Common-Ansible substrate manually, then re-run." >&2
    exit 1
fi

echo ""
echo "Consumer controller bootstrap complete:"
echo "  Substrate sibling : ${common_ansible_root}"
echo "  Controller venv   : ${common_ansible_root}/.venv"
echo "  Roles resolve via : ANSIBLE_ROLES_PATH -> ${repo_root}/roles then ${common_ansible_root}/roles"
