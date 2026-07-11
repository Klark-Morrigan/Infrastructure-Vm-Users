#!/usr/bin/env bash
# Cross-repo adapter: imports the shared timing-span emitter (timing_init,
# timing_span_begin / timing_span_end, timing_enabled) from Common-Automation
# (scripts/timing.sh, the bash counterpart of Common.PowerShell's
# Export-TimingSpanTree - it writes the e2e-timing/v1 tree Infrastructure-E2E
# imports and grafts). Sourcing this is how an ops/ flow pulls in the emitter
# on a stable in-repo path while the cross-repo location stays resolved in one
# place. See _common-automation-root.sh for how the repo root is found and
# overridden under test.
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-automation-root.sh
source "${BASH_SOURCE[0]%/*}/_common-automation-root.sh"
# shellcheck source=/dev/null
source "${common_automation_root}/scripts/timing.sh"
