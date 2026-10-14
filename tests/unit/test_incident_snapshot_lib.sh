#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/incident-snapshot-lib.sh
source "${ROOT}/scripts/lib/incident-snapshot-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(incident_iptables_pkts_field 700000)" == "700000" ]] || fail 'digits'
[[ "$(incident_iptables_pkts_field 0)" == "0" ]] || fail 'zero'
[[ "$(incident_iptables_pkts_field 700K)" == "0" ]] || fail 'human suffix should not parse (use iptables -x)'

echo "OK test_incident_snapshot_lib"
