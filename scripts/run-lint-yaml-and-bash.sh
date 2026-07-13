#!/usr/bin/env bash
# Runs the lint half of this repo's CI locally in two parts:
#   1. The cross-cutting linters - shellcheck, check-sh-executable,
#      actionlint, action-validator, yamllint - delegated to Common-
#      Automation's _run-lint-yaml-and-bash.sh, pointed at this repo via
#      COMMON_AUTOMATION_TARGET_REPO.
#   2. This repo's ansible-lint (run-lint-ansible.sh), run through the shared
#      Common-Ansible controller venv.
# The ansible-lint step is owned here, not by the delegated runner: feature
# 20 re-homed the Ansible gate from Common-Automation into Common-Ansible, so
# once Common-Automation dropped its own ansible-lint step this is what keeps
# the nested roles/playbooks linted on a local pre-push run. The bats test
# half is run-tests-bash.sh; run-ci-yaml-and-bash.sh runs both. Common-
# Automation is expected as a sibling checkout under the same parent directory.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
common_automation_root="$(cd "${repo_root}/../Common-Automation" && pwd)"

# Track failures across both halves so an early cross-cutting-linter miss does
# not hide a later ansible-lint failure - the user sees every problem in one
# run. The delegated call is no longer exec'd (it was) so this shim regains
# control to run ansible-lint after it.
failures=()

if ! COMMON_AUTOMATION_TARGET_REPO="${repo_root}" \
        "${common_automation_root}/scripts/_run-lint-yaml-and-bash.sh"; then
    failures+=("yaml-and-bash")
fi

if ! "${script_dir}/run-lint-ansible.sh"; then
    failures+=("ansible-lint")
fi

if (( ${#failures[@]} > 0 )); then
    echo "FAILED (lint): ${failures[*]}" >&2
    exit 1
fi
echo "Lint checks passed."
