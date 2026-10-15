#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/incident-channel-lib.sh
source "${ROOT}/scripts/lib/incident-channel-lib.sh"
# shellcheck source=../lib/incident_csv_v2_fixture.sh
source "${ROOT}/tests/lib/incident_csv_v2_fixture.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(incident_socks_ok_from_ms 0.34)" == "1" ]] || fail 'socks ok numeric'
[[ "$(incident_socks_ok_from_ms fail)" == "0" ]] || fail 'socks fail'

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
EV="${TMP}/ev.jsonl"
EVAL="${TMP}/eval.state"

incident_channel_eval_events "${EV}" "2026-10-14T07:00:00Z" "0" "100" "0" "0" "0" "0" "${EVAL}"
grep -q channel_degraded "${EV}" || fail 'degraded event'
grep -q '"primary":"CH5"' "${EV}" || fail 'CH5 primary'

incident_channel_eval_events "${EV}" "2026-10-14T07:02:00Z" "1" "100" "0" "0" "0" "0" "${EVAL}"
grep -q channel_recovered "${EV}" || fail 'recovered event'
grep -q '"primary":"CH5"' "${EV}" || fail 'recovered CH5 after socks degrade'

EV3="${TMP}/ev3.jsonl"
EVAL3="${TMP}/eval3.state"
incident_channel_eval_events "${EV3}" "2026-10-14T08:00:00Z" "1" "6000" "0" "0" "0" "0" "${EVAL3}"
grep -q '"primary":"CH4"' "${EV3}" || fail 'CH4 degraded'
incident_channel_eval_events "${EV3}" "2026-10-14T08:02:00Z" "0" "100" "0" "0" "0" "0" "${EVAL3}"
incident_channel_eval_events "${EV3}" "2026-10-14T08:04:00Z" "1" "100" "0" "0" "0" "0" "${EVAL3}"
grep -q '"primary":"CH5"' "${EV3}" || fail 'recovered last degraded CH5 not CH4'

# Same primary must not spam degraded events every tick.
EV2="${TMP}/ev2.jsonl"
EVAL2="${TMP}/eval2.state"
incident_channel_eval_events "${EV2}" "2026-10-14T07:00:00Z" "0" "100" "0" "0" "0" "0" "${EVAL2}"
incident_channel_eval_events "${EV2}" "2026-10-14T07:02:00Z" "0" "100" "0" "0" "0" "0" "${EVAL2}"
_n="$(grep -c channel_degraded "${EV2}" || true)"
[[ "${_n}" == "1" ]] || fail "degraded spam: ${_n}"

export INC_VERDICT_HOST=ok
export INC_VERDICT_OUT_ICMP=ok
export INC_VERDICT_OUT_TCP=ok
export INC_VERDICT_SOCKS=timeout
export INC_VERDICT_DNS_LOCAL=fail
export INC_VERDICT_DNS_CLIENT=fail
export INC_VERDICT_UDP_RELAY=ok
export INC_VERDICT_INJECT_FAIL_N=0
export INC_VERDICT_P2P_N=0
export INC_VERDICT_IPT2SOCKS_CLIENT_TO=0
export INC_VERDICT_RST_COREDNS=0
_v="$(incident_verdict_v2_compute)"
echo "${_v}" | grep -q 'PRIMARY=CH5_SHARED_SOCKS_EGRESS' || fail "verdict socks: ${_v}"

export INC_VERDICT_SOCKS=ok
export INC_VERDICT_DNS_LOCAL=ok
export INC_VERDICT_INJECT_FAIL_N=50
export INC_VERDICT_P2P_N=200
_v="$(incident_verdict_v2_compute)"
echo "${_v}" | grep -q 'PRIMARY=CH3_UDP_RELAY_DEGRADED' || fail "verdict udp: ${_v}"
echo "${_v}" | grep -q 'CORRELATION=p2p_udp_heavy_window' || fail "correlation: ${_v}"
echo "${_v}" | grep -q 'PRIMARY_CODE=CH3' || fail "primary code: ${_v}"

INC_SIG_MODE=tick
INC_SIG_SOCKS_OK=1
INC_SIG_COLD_MS=6000
INC_SIG_STREAK=0
INC_SIG_INJECT_DELTA=0
INC_SIG_P2P_DELTA=0
INC_SIG_ONE_WAY_DELTA=0
incident_primary_from_signals
[[ "${INC_PRIMARY_CODE}" == CH4 ]] || fail "tick CH4 cold"

INC_SIG_MODE=snapshot
INC_SIG_HOST=ok
INC_SIG_OUT_ICMP=ok
INC_SIG_OUT_TCP=ok
INC_SIG_SOCKS=timeout
INC_SIG_DNS_LOCAL=fail
incident_primary_from_signals
[[ "${INC_PRIMARY_CODE}" == CH5 ]] || fail "snapshot CH5 before dns"
[[ "$(incident_primary_snapshot_label CH5)" == CH5_SHARED_SOCKS_EGRESS ]] || fail 'snapshot label CH5'

echo "${INCIDENT_CSV_V2_HEADER}" | grep -q 'socks_ok' || fail 'header socks_ok'
echo "${INCIDENT_CSV_V2_HEADER}" | grep -q 'awg_socks_conn' || fail 'header awg_socks_conn'
echo "${INCIDENT_CSV_V2_HEADER}" | grep -q 'inject_fail_delta' || fail 'header inject_fail_delta'
_csv_stats="${TMP}/stats.csv"
printf '%s\n' "${INCIDENT_CSV_V2_HEADER}" > "${_csv_stats}"
_row="$(incident_metrics_csv_v2_build_row \
  "2026-01-01T00:00:00Z" 400 500 0.5 0 0.3 0 0 healthy 0 50 1 7 20 5 2 100 200 \
  0 0 0 0 0 1 2 0 SCEN-OK)" || fail 'build_row'
if incident_metrics_csv_v2_build_row 1 2 3 2>/dev/null; then
  fail 'build_row should reject wrong arity'
fi
[[ "$(echo "${_row}" | awk -F, '{print NF}')" == "$(incident_metrics_csv_v2_field_count)" ]] \
  || fail 'row field count vs header'
printf '%s\n' "${_row}" >> "${_csv_stats}"
read -r _qf _qo _qc _qi <<<"$(incident_metrics_csv_v2_quick_stats "${_csv_stats}")"
[[ "${_qf}" == 1 && "${_qc}" == 7 ]] || fail "quick stats: fail=${_qf} conn=${_qc}"
unset INC_CSV_V2_FIELD 2>/dev/null || true

incident_primary_sig_unset_inputs
incident_primary_clear_outputs
unset INC_VERDICT_HOST INC_VERDICT_OUT_ICMP INC_VERDICT_OUT_TCP INC_VERDICT_SOCKS
unset INC_VERDICT_DNS_LOCAL INC_VERDICT_DNS_CLIENT INC_VERDICT_UDP_RELAY
unset INC_VERDICT_INJECT_FAIL_N INC_VERDICT_P2P_N INC_VERDICT_IPT2SOCKS_CLIENT_TO
unset INC_VERDICT_RST_COREDNS

echo "OK test_incident_channel_lib"
