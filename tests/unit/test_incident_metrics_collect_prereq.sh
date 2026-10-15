#!/usr/bin/env bash
# incident_metrics_collect_prereq: fails without full source chain; ok when patterns+snapshot+channel loaded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Collect-lib alone → missing patterns and snapshot/channel.
# shellcheck source=../../scripts/lib/incident-metrics-collect-lib.sh
source "${ROOT}/scripts/lib/incident-metrics-collect-lib.sh"
if incident_metrics_collect_prereq 2>/dev/null; then
  fail 'prereq should fail without patterns/snapshot/channel'
fi

# shellcheck source=../../scripts/lib/incident-udp-log-patterns.sh
source "${ROOT}/scripts/lib/incident-udp-log-patterns.sh"
if incident_metrics_collect_prereq 2>/dev/null; then
  fail 'prereq should fail without snapshot/channel'
fi

# shellcheck source=../../scripts/lib/incident-snapshot-lib.sh
source "${ROOT}/scripts/lib/incident-snapshot-lib.sh"
if incident_metrics_collect_prereq 2>/dev/null; then
  fail 'prereq should fail without channel'
fi

# shellcheck source=../../scripts/lib/incident-channel-lib.sh
source "${ROOT}/scripts/lib/incident-channel-lib.sh"
incident_metrics_collect_prereq || fail 'prereq should pass with patterns+snapshot+channel'

echo "OK test_incident_metrics_collect_prereq"
