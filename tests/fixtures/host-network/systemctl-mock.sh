#!/usr/bin/env bash
# Mock systemctl for unit tests.
#
# contract: any invocation → exit 0, append args to SYSTEMCTL_MOCK_LOG
#
# env:
#   SYSTEMCTL_MOCK_LOG — log file path
#
# consumers: test_host_network_remove, test_host_remove_integration
set -euo pipefail

log="${SYSTEMCTL_MOCK_LOG:?SYSTEMCTL_MOCK_LOG not set}"
printf '%s\n' "$*" >> "${log}"
exit 0
