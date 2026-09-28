#!/usr/bin/env bash
# Unit tests for scripts/lib/voice-smoke-metrics.sh — gate logic and helpers (no Docker).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
METRICS="${REPO_ROOT}/scripts/lib/voice-smoke-metrics.sh"
HELP="${REPO_ROOT}/scripts/lib/voice-smoke-help.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck disable=SC1091
source "${HELP}"
# shellcheck disable=SC1091
source "${METRICS}"

voice_smoke_load_gate_defaults

[[ "$(voice_smoke_to_int '129')" == "129" ]] || fail "to_int numeric"
[[ "$(voice_smoke_to_int 'abc')" == "0" ]] || fail "to_int non-numeric"

eval_gate() {
  local rc=0
  VOICE_SMOKE_GATE_FAIL_MSG=""
  VOICE_SMOKE_GATE_PASS_MSG=""
  VOICE_SMOKE_GATE_INFO=""
  voice_smoke_eval_gate "$@" || rc=$?
  return "${rc}"
}

CLIENT_IP=10.8.0.9

eval_gate 129 0 27000 22000 1 1 0 0 0 5 \
  || fail "expected PASS for typical voice run"
[[ -n "${VOICE_SMOKE_GATE_PASS_MSG}" ]] || fail "PASS message missing"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == "" ]] || fail "unexpected FAIL on good run"

eval_gate 5 0 27000 22000 1 1 0 0 0 0 \
  && fail "expected FAIL for low NFQUEUE"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"NFQUEUE=5"* ]] \
  || fail "NFQUEUE fail message: ${VOICE_SMOKE_GATE_FAIL_MSG}"

eval_gate 129 3 27000 22000 1 1 0 0 0 0 \
  && fail "expected FAIL for FWD-drop"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"udp-FWD-drop"* ]] \
  || fail "FWD-drop fail message: ${VOICE_SMOKE_GATE_FAIL_MSG}"

eval_gate 129 0 50 50 1 1 0 0 0 0 \
  && fail "expected FAIL for idle traffic"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"meaningful AWG traffic"* ]] \
  || fail "idle traffic message: ${VOICE_SMOKE_GATE_FAIL_MSG}"

eval_gate 129 0 500 500 0 0 0 0 0 0 \
  && fail "expected FAIL for low AWG bytes"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"below ${GATE_AWG_BYTES_MIN}"* ]] \
  || fail "AWG bytes message: ${VOICE_SMOKE_GATE_FAIL_MSG}"

eval_gate 129 0 5000 22000 1 0 1 0 0 0 \
  && fail "expected FAIL for one-way session (active call state)"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"one-way"* ]] \
  || fail "one-way message: ${VOICE_SMOKE_GATE_FAIL_MSG}"

VOICE_SMOKE_CALL_STATE=joining
eval_gate 129 0 27000 22000 1 0 1 0 0 0 \
  && fail "joining mode must FAIL on one-way without inject"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"one-way"* ]] \
  || fail "joining one-way message: ${VOICE_SMOKE_GATE_FAIL_MSG}"

eval_gate 129 0 27000 22000 1 0 0 0 0 0 \
  && fail "joining mode must FAIL when outbound started without inject"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"first inject"* ]] \
  || fail "joining inject message: ${VOICE_SMOKE_GATE_FAIL_MSG}"
VOICE_SMOKE_CALL_STATE=active

eval_gate 129 0 5000 22000 0 0 0 0 0 0 \
  && fail "expected FAIL for low rx without inject on reused session"
[[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"one-way audio"* ]] \
  || fail "rx/inject message: ${VOICE_SMOKE_GATE_FAIL_MSG}"

eval_gate 129 0 27000 22000 0 0 0 0 0 0 \
  || fail "reused session should PASS"
[[ "${VOICE_SMOKE_GATE_INFO}" == *"reused existing VoIP session"* ]] \
  || fail "reused session info missing"

summary="$(voice_smoke_gate_summary_line)"
[[ "${summary}" == *"NFQUEUE>=20"* ]] || fail "gate summary line: ${summary}"

echo "OK: test_voice_smoke_metrics"
