#!/usr/bin/env bash
# Guard: channel-report entrypoint lib is present and callable (no docker).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/incident-channel-report-lib.sh
source "${ROOT}/scripts/lib/incident-channel-report-lib.sh"

declare -f incident_channel_report_markdown >/dev/null || {
  echo "missing incident_channel_report_markdown" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
_out="$(incident_channel_report_markdown "2099-01-01" "${TMP}/metrics" "${TMP}/events")"
echo "${_out}" | grep -q 'Incident channel report — 2099-01-01' || {
  echo "unexpected report header" >&2
  exit 1
}

echo "OK test_incident_channel_report_lib"
