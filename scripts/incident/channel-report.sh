#!/usr/bin/env bash
# Markdown RCA draft from metrics CSV v2 + events.jsonl for one UTC day.
#
#   make incident-channel-report
#   make incident-channel-report DATE=2026-10-14
#   OUT=~/log/reports/rca-2026-10-14.md make incident-channel-report
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_dir}/../lib/paths.sh"
# shellcheck source=../lib/incident-channel-report-lib.sh
source "${REPO_ROOT}/scripts/lib/incident-channel-report-lib.sh"
unset _script_dir

METRICS_DIR="${INCIDENT_METRICS_DIR:-${HOME}/log/metrics}"
EVENTS_DIR="${INCIDENT_EVENTS_DIR:-${HOME}/log/events}"
DAY="${DATE:-$(date -u '+%Y-%m-%d')}"

if [[ -n "${OUT:-}" ]]; then
  mkdir -p "$(dirname "${OUT}")"
  incident_channel_report_markdown "${DAY}" "${METRICS_DIR}" "${EVENTS_DIR}" | tee "${OUT}"
  chmod 600 "${OUT}" 2>/dev/null || true
  echo "Saved: ${OUT}"
else
  incident_channel_report_markdown "${DAY}" "${METRICS_DIR}" "${EVENTS_DIR}"
fi
