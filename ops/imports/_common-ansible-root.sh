#!/usr/bin/env bash
# Resolves the Common-Ansible substrate root - the single place this repo's
# Ansible consumption learns where the shared substrate lives, so the
# "where is Common-Ansible" knowledge is not re-derived per script.
#
# Common-Ansible is consumed as a sibling checkout (same adapter pattern as
# ops/imports/_common-automation-root.sh): its reusable roles AND its ops
# bridge are reached from this one resolved root, because the roles depend
# on the bridge's extra-vars/inventory contract and are not usable on their
# own - they are one substrate, consumed through one checkout.
#
# Guarded so sourcing it from several scripts in one run resolves the root
# only once. COMMON_ANSIBLE_ROOT overrides the sibling-checkout default (for
# tests / non-standard layouts). The relative fallback walks three levels up:
# ops/imports -> ops -> repo root -> c:\a_Code, then into the Common-Ansible
# sibling. The plain assignment (not `: "${x:=...}"`) observes the cd's exit
# status rather than masking it (shellcheck SC2312).
if [[ -z "${common_ansible_root:-}" ]]; then
    # shellcheck disable=SC2034  # consumed by the scripts that source this
    common_ansible_root="${COMMON_ANSIBLE_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../../../Common-Ansible" && pwd)}"
fi
