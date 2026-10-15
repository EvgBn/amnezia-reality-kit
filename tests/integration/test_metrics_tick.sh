#!/usr/bin/env bash
# Lib-only smoke: CSV v2 header + tick state path used by metrics-tick (no docker).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/lib/incident-channel-lib.sh
source "${ROOT}/scripts/lib/incident-channel-lib.sh"
# shellcheck source=../lib/incident_csv_v2_fixture.sh
source "${ROOT}/tests/lib/incident_csv_v2_fixture.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
METRICS="${TMP}/metrics"
mkdir -p "${METRICS}"

_csv="${METRICS}/2026-10-15.csv"
incident_metrics_ensure_v2_csv "${_csv}"
[[ -f "${_csv}" ]] || fail 'csv created'
head -1 "${_csv}" | grep -q 'socks_ok' || fail 'v2 header'
_nfields="$(head -1 "${_csv}" | awk -F, '{print NF}')"
[[ "${_nfields}" == 27 ]] || fail "expected 27 csv fields, got ${_nfields}"

# v1 → backup + v2 header
echo 'ts_utc,coredns_health,coredns_streak' > "${METRICS}/2026-10-16.csv"
incident_metrics_ensure_v2_csv "${METRICS}/2026-10-16.csv"
ls "${METRICS}/2026-10-16.csv.v1-bak-"* >/dev/null 2>&1 || fail 'v1 backup'
head -1 "${METRICS}/2026-10-16.csv" | grep -q 'socks_ok' || fail 'v2 after migrate'

_state="$(incident_tick_state_path "${METRICS}")"
incident_tick_state_save "${_state}" "2026-10-15T12:00:00Z" 42 100 200 3
_prev="$(incident_tick_state_load_blob "${_state}" "2026-10-15T12:02:00Z")"
[[ "$(incident_state_get "${_prev}" nfqueue)" == "42" ]] || fail 'tick-state for metrics dir'

# Synthetic row via row_from_map (order from INCIDENT_CSV_V2_HEADER only).
incident_test_csv_v2_map_defaults 0
INC_CSV_V2_FIELD[ts_utc]="2026-10-15T12:02:00Z"
INC_CSV_V2_FIELD[socks_ok]=1
INC_CSV_V2_FIELD[udp_scenario]=SCEN-OK
_row="$(incident_metrics_csv_v2_row_from_map)"
[[ "$(echo "${_row}" | awk -F, '{print NF}')" == "${_nfields}" ]] || fail 'row field count matches header'
unset INC_CSV_V2_FIELD
echo "${_row}" >> "${_csv}"
tail -1 "${_csv}" | grep -q 'SCEN-OK' || fail 'row appended'

echo "OK test_metrics_tick"
