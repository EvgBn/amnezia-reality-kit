#!/usr/bin/env bash
# Layered UDP/NFQUEUE path diagnosis for Telegram group voice.
#
# Two modes:
#   diagnose-udp-path           — static L0–L4 only (NO phone call, NO voice chat)
#   diagnose-udp-path-watch     — static + live gate L5 (voice must be ACTIVE during WATCH seconds)
#
# Voice timing for --watch (either works):
#   [A] Already in group voice → run script → stay in call for WATCH seconds
#   [B] Not in voice yet       → run script → join group voice within WATCH seconds
#
# Usage:
#   make diagnose-udp-path
#   make diagnose-udp-path-watch WATCH=30
#   make voice-gate                              # alias for diagnose-udp-path-watch
#   NONINTERACTIVE=1 make voice-gate             # skip call-state prompt (CI only)
#
# Gate thresholds (override via env):
#   GATE_NFQUEUE_MIN=20  GATE_FWD_DROP_MAX=0  GATE_AWG_BYTES_MIN=10000  GATE_RX_MIN=15000
# Client IP: always prompted from awg-client-list (NONINTERACTIVE=1 + SMOKE_CLIENT_IP for CI only)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/paths.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/voice-smoke-help.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/voice-smoke-metrics.sh"

AWG_CONTAINER="${VPN_AWG_CONTAINER:-${VPN_AWG_POD:-vpn-amneziawg}}"
XRAY_CONTAINER="${VPN_XRAY_CONTAINER:-${VPN_XRAY_POD:-vpn-xray}}"
# Legacy: VPN_AWG_POD, VPN_XRAY_POD
CLIENT_IP="${SMOKE_CLIENT_IP:-}"
NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-100}"
WATCH_SEC=0
PREP_SEC="${PREP:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)
      WATCH_SEC="${2:-15}"
      shift 2
      ;;
    *)
      if [[ "${1}" =~ ^[0-9]+$ ]]; then
        WATCH_SEC="$1"
      fi
      shift
      ;;
  esac
done
HANDSHAKE_MAX_AGE="${SMOKE_HANDSHAKE_MAX_AGE:-180}"
voice_smoke_load_gate_defaults

WORKDIR="${DIAGNOSE_WORKDIR:-}"
WATCH_TS=""

pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; WARNS=$((WARNS + 1)); }
info() { printf '  [INFO] %s\n' "$*"; }

FAILS=0
WARNS=0
GATE_FAILS=0

gate_fail() {
  printf '  [GATE FAIL] %s\n' "$*" >&2
  GATE_FAILS=$((GATE_FAILS + 1))
}

gate_pass() {
  printf '  [GATE PASS] %s\n' "$*"
}

check_no_stale_udp_path() {
  local mangle
  mangle="$(docker exec "${AWG_CONTAINER}" iptables -t mangle -L PREROUTING -n 2>/dev/null || true)"
  if grep -q 'TPROXY' <<< "${mangle}"; then
    fail "stale TPROXY rule in mangle PREROUTING (Track B) — remove before NFQUEUE voice path"
  else
    pass "no TPROXY rules in mangle PREROUTING"
  fi
  if grep -q 'ctdir REPLY' <<< "${mangle}"; then
    fail "ctdir REPLY rule in mangle PREROUTING — REPLY UDP bypasses NFQUEUE (voice FWD-drop bug)"
  else
    pass "no ctdir REPLY bypass in mangle PREROUTING"
  fi
  if docker exec "${AWG_CONTAINER}" pgrep -af ipt2socks 2>/dev/null | grep -q '\-U'; then
    fail "ipt2socks -U (UDP) still running — should be udp-relay for NFQUEUE path"
  else
    pass "no ipt2socks -U UDP process (udp-relay owns UDP exit)"
  fi
}

check_shared_socks_associate() {
  local socks_ready since relay_out nfq_life
  socks_ready="$(docker logs "${AWG_CONTAINER}" --tail 5000 2>&1 | grep -c 'shared socks udp associate ready' || true)"
  socks_ready="$(voice_smoke_to_int "${socks_ready}")"
  if [[ "${socks_ready}" -gt 0 ]]; then
    pass "shared SOCKS UDP associate ready"
    return 0
  fi
  since="$(docker inspect "${AWG_CONTAINER}" --format '{{.State.StartedAt}}' 2>/dev/null || true)"
  if [[ -n "${since}" ]]; then
    socks_ready="$(voice_smoke_count_log_since "${AWG_CONTAINER}" 'shared socks udp associate ready' "${since}")"
    if [[ "${socks_ready}" -gt 0 ]]; then
      pass "shared SOCKS UDP associate ready (since container start)"
      return 0
    fi
  fi
  relay_out="$(docker logs "${AWG_CONTAINER}" 2>&1 | grep -c 'session first outbound' || true)"
  nfq_life="$(voice_smoke_to_int "$(voice_smoke_counter_nfqueue)")"
  if [[ "$(voice_smoke_to_int "${relay_out}")" -gt 0 && "${nfq_life}" -gt 100 ]]; then
    pass "relay handling UDP (startup log rotated; NFQUEUE lifetime=${nfq_life})"
    return 0
  fi
  warn "no SOCKS UDP associate evidence — check: docker logs ${AWG_CONTAINER} | grep shared"
}

save_fail_artifacts() {
  [[ "${FAILS}" -gt 0 || "${GATE_FAILS}" -gt 0 ]] || return 0
  if [[ -z "${WORKDIR}" ]]; then
    WORKDIR="/tmp/diagnose-udp-path.$$"
  fi
  mkdir -p "${WORKDIR}"
  info "saving artifacts to ${WORKDIR}/"
  docker logs "${AWG_CONTAINER}" --since "${WATCH_TS:-1h}" 2>&1 > "${WORKDIR}/awg.log" || true
  docker logs "${XRAY_CONTAINER}" --since "${WATCH_TS:-1h}" 2>&1 > "${WORKDIR}/xray-socks.log" || true
  docker exec "${AWG_CONTAINER}" iptables-save 2>/dev/null > "${WORKDIR}/iptables-save.txt" || true
  docker exec "${AWG_CONTAINER}" awg show awg0 dump 2>/dev/null > "${WORKDIR}/awg-dump.txt" || true
  {
    echo "client=${CLIENT_IP}"
    echo "watch_sec=${WATCH_SEC}"
    echo "watch_ts=${WATCH_TS:-n/a}"
    echo "gate_nfqueue_min=${GATE_NFQUEUE_MIN}"
    echo "gate_fwd_drop_max=${GATE_FWD_DROP_MAX}"
    echo "gate_awg_bytes_min=${GATE_AWG_BYTES_MIN}"
    echo "gate_rx_min=${GATE_RX_MIN}"
  } > "${WORKDIR}/meta.txt"
}

run_l5_gate() {
  local b_nfq b_tcp b_udp_drop b_rx b_tx
  local a_nfq a_tcp a_udp_drop a_rx a_tx
  local d_nfq d_tcp d_udp_drop d_rx d_tx
  local w_first_out w_first_inject w_session_open w_one_way w_inject_fail w_relay_fail w_xray_udp

  if [[ "${VOICE_GATE_VERBOSE:-0}" == "1" ]]; then
    voice_smoke_print_purpose gate "${CLIENT_IP}"
    voice_smoke_print_timing "${WATCH_SEC}" "${CLIENT_IP}"
  else
    voice_smoke_print_l5_prep "${CLIENT_IP}" "${WATCH_SEC}"
  fi
  voice_smoke_prompt_call_state "${WATCH_SEC}"
  voice_smoke_prep_countdown "${PREP_SEC}" "${WATCH_SEC}"
  WATCH_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker logs "${AWG_CONTAINER}" --since 1s >/dev/null 2>&1 || true
  docker logs "${XRAY_CONTAINER}" --since 1s >/dev/null 2>&1 || true

  b_nfq="$(voice_smoke_counter_nfqueue)"
  b_tcp="$(voice_smoke_counter_nat_tcp_redirect)"
  b_udp_drop="$(voice_smoke_counter_forward_udp_drop)"
  read -r b_rx b_tx <<< "$(voice_smoke_peer_bytes "${CLIENT_IP}")"

  sleep "${WATCH_SEC}"

  a_nfq="$(voice_smoke_counter_nfqueue)"
  a_tcp="$(voice_smoke_counter_nat_tcp_redirect)"
  a_udp_drop="$(voice_smoke_counter_forward_udp_drop)"
  read -r a_rx a_tx <<< "$(voice_smoke_peer_bytes "${CLIENT_IP}")"

  d_nfq=$(( $(voice_smoke_to_int "${a_nfq}") - $(voice_smoke_to_int "${b_nfq}") ))
  d_tcp=$(( $(voice_smoke_to_int "${a_tcp}") - $(voice_smoke_to_int "${b_tcp}") ))
  d_udp_drop=$(( $(voice_smoke_to_int "${a_udp_drop}") - $(voice_smoke_to_int "${b_udp_drop}") ))
  d_rx=$(( $(voice_smoke_to_int "${a_rx}") - $(voice_smoke_to_int "${b_rx}") ))
  d_tx=$(( $(voice_smoke_to_int "${a_tx}") - $(voice_smoke_to_int "${b_tx}") ))

  voice_smoke_collect_window_metrics_live "${WATCH_TS}" \
    w_first_out w_first_inject w_session_open w_one_way w_inject_fail w_relay_fail w_xray_udp

  echo ""
  echo "── Results (${WATCH_SEC}s window) ──"
  echo ""
  voice_smoke_print_human_results "${d_nfq}" "${d_udp_drop}" "${d_rx}" "${d_tx}" \
    "${w_first_out}" "${w_first_inject}" "${w_one_way}" "${w_inject_fail}" "${w_relay_fail}" "${w_xray_udp}"

  if [[ "${VOICE_GATE_VERBOSE:-0}" == "1" ]]; then
    echo ""
    echo "── Engineer details (raw counters) ──"
    echo ""
    voice_smoke_print_engineer_table \
      "${b_nfq}" "${a_nfq}" "${d_nfq}" \
      "${b_tcp}" "${a_tcp}" "${d_tcp}" \
      "${b_udp_drop}" "${a_udp_drop}" "${d_udp_drop}" \
      "${b_rx}" "${a_rx}" "${d_rx}" \
      "${b_tx}" "${a_tx}" "${d_tx}" \
      "${w_session_open}" "${w_first_out}" "${w_first_inject}" \
      "${w_one_way}" "${w_inject_fail}" "${w_relay_fail}" "${w_xray_udp}"
  fi

  echo ""
  echo "── L5 verdict ──"

  if voice_smoke_eval_gate "${d_nfq}" "${d_udp_drop}" "${d_rx}" "${d_tx}" \
      "${w_first_out}" "${w_first_inject}" "${w_one_way}" "${w_inject_fail}" "${w_relay_fail}" "${w_xray_udp}"; then
    gate_pass "VoIP captured and return path OK in ${WATCH_SEC}s window"
    voice_smoke_result_info "PASS = relay metrics only; Telegram UI may still show Connecting… (use call state [1] when hearing audio)"
    if [[ "${VOICE_GATE_VERBOSE:-0}" != "1" ]]; then
      voice_smoke_result_info "Raw counters: VOICE_GATE_VERBOSE=1"
    else
      while IFS= read -r info_line; do
        [[ -z "${info_line}" ]] && continue
        voice_smoke_result_info "${info_line}"
      done <<< "${VOICE_SMOKE_GATE_INFO}"
    fi
  else
    gate_fail "${VOICE_SMOKE_GATE_FAIL_MSG}"
    if [[ "${VOICE_SMOKE_GATE_FAIL_MSG}" == *"voice UDP not captured"* ]]; then
      voice_smoke_result_info "Connecting… without UDP = Telegram never started media (server cannot fix yet)"
    fi
    voice_smoke_result_info "Diagnostics: make voice-path-probe; make voice-fail-snapshot (before refresh-full)"
  fi
}

if ! voice_smoke_require_container "${AWG_CONTAINER}"; then
  fail "container ${AWG_CONTAINER} not found"
  exit 1
fi
if ! voice_smoke_require_container "${XRAY_CONTAINER}"; then
  fail "container ${XRAY_CONTAINER} not found"
  exit 1
fi

if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
  info "Resolving client ${SMOKE_CLIENT_IP:-?} (NONINTERACTIVE)…"
fi

if ! CLIENT_IP="$(voice_smoke_resolve_client_ip "${AWG_CONTAINER}" "${HANDSHAKE_MAX_AGE}" "${ROOT}")"; then
  exit 1
fi
CLIENT_IP="$(voice_smoke_normalize_ip "${CLIENT_IP}")"

echo "=== UDP path diagnosis (NFQUEUE / udp-relay) ==="
echo "repo:     ${REPO_ROOT:-$ROOT}"
echo "client:   ${CLIENT_IP}"
echo "nfqueue:  queue ${NFQUEUE_NUM} -> udp-relay -> SOCKS"
if [[ "${WATCH_SEC}" -gt 0 ]]; then
  echo "mode:     LIVE GATE (static L0–L4 + ${WATCH_SEC}s voice probe L5)"
  echo "gate:     $(voice_smoke_gate_summary_line)"
else
  echo "mode:     STATIC ONLY (L0–L4) — no phone call required"
fi
echo ""

echo "── L0: VPN client on tunnel ──"
line="$(voice_smoke_peer_dump_line "${CLIENT_IP}")"
if [[ -z "${line}" ]]; then
  fail "no AWG peer for ${CLIENT_IP}"
else
  age="$(voice_smoke_peer_handshake_age "${CLIENT_IP}")"
  if [[ "${age}" -lt 0 ]]; then
    fail "peer ${CLIENT_IP} has no handshake timestamp"
  elif [[ "${age}" -gt "${HANDSHAKE_MAX_AGE}" ]]; then
    fail "peer ${CLIENT_IP} VPN idle/stale — last handshake ${age}s ago (need <${HANDSHAKE_MAX_AGE}s)"
    info "Active peers on tunnel:"
    voice_smoke_peer_list_status
    info "If you tested from another device, rerun with SMOKE_CLIENT_IP=<that-ip>"
  else
    pass "peer ${CLIENT_IP} handshake ${age}s ago"
  fi
  bytes="$(voice_smoke_peer_bytes "${CLIENT_IP}")"
  read -r rx tx <<< "${bytes}"
  info "lifetime bytes rx=${rx} tx=${tx} (awg dump)"
fi

echo ""
echo "── L1: udp-relay (in container) ──"
if docker exec "${AWG_CONTAINER}" pgrep -f '/usr/local/bin/udp-relay' >/dev/null 2>&1; then
  pass "udp-relay running"
else
  fail "udp-relay process not running in ${AWG_CONTAINER}"
fi
if docker exec "${AWG_CONTAINER}" pgrep -x ipt2socks >/dev/null 2>&1; then
  tcp_procs="$(docker exec "${AWG_CONTAINER}" pgrep -x ipt2socks 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${tcp_procs}" -ge 2 ]; then
    pass "ipt2socks tcp (${tcp_procs} processes: v4/v6)"
  else
    fail "expected 2 ipt2socks tcp processes, got ${tcp_procs}"
  fi
else
  fail "no ipt2socks tcp processes in ${AWG_CONTAINER}"
fi
check_shared_socks_associate

echo ""
echo "── L2: iptables NFQUEUE capture ──"
if docker exec "${AWG_CONTAINER}" iptables -t mangle -C PREROUTING -i awg0 -p udp -m multiport ! --dports 53,784,8853 \
    -m addrtype ! --dst-type LOCAL \
    -j NFQUEUE --queue-num "${NFQUEUE_NUM}" --queue-bypass 2>/dev/null; then
  pass "NFQUEUE rule -> queue ${NFQUEUE_NUM}"
else
  fail "NFQUEUE rule missing for queue ${NFQUEUE_NUM}"
fi
nfq="$(voice_smoke_to_int "$(voice_smoke_counter_nfqueue)")"
tcp_redir="$(voice_smoke_to_int "$(voice_smoke_counter_nat_tcp_redirect)")"
udp_drop="$(voice_smoke_to_int "$(voice_smoke_counter_forward_udp_drop)")"
info "lifetime: mangle NFQUEUE=${nfq}"
info "lifetime: nat TCP redirect=${tcp_redir}, FORWARD udp-drop(!53)=${udp_drop}"
if [[ "${nfq}" -lt 1 ]]; then
  warn "no non-DNS UDP on awg0 yet — Telegram voice needs UDP (TCP-only = messages/Connecting…)"
fi

echo ""
echo "── L2b: anti-regression (no stale Track B / REPLY bypass) ──"
check_no_stale_udp_path

echo ""
echo "── L3: Anti-leak FORWARD ──"
if docker exec "${AWG_CONTAINER}" iptables -C FORWARD -i awg0 -p udp ! --dport 53 -j DROP 2>/dev/null; then
  pass "FORWARD udp !:53 DROP (no RF leak)"
else
  fail "FORWARD udp anti-leak rule missing"
fi

echo ""
echo "── L4: SOCKS / xray exit ──"
if docker inspect "${XRAY_CONTAINER}" --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
  pass "${XRAY_CONTAINER} healthy"
else
  fail "${XRAY_CONTAINER} not healthy"
fi

echo ""
echo "── L5: Live voice gate (${WATCH_SEC}s) ──"
if [[ "${WATCH_SEC}" -gt 0 ]]; then
  run_l5_gate
else
  info "skipped — static mode (no phone call). Deploy gate:"
  info "  make diagnose-udp-path-watch WATCH=30   # alias: make voice-gate"
  info "Voice may start before OR after the script; must be ACTIVE during the WATCH window."
fi

save_fail_artifacts

echo ""
echo "=== Summary ==="
if [[ "${FAILS}" -eq 0 ]]; then
  log_info "Static checks (L0–L4): PASS"
else
  log_warn "Static checks (L0–L4): ${FAILS} FAIL — fix top-to-bottom (L0 first)"
fi
if [[ "${WARNS}" -gt 0 ]]; then
  log_warn "Warnings: ${WARNS}"
fi
if [[ "${WATCH_SEC}" -gt 0 ]]; then
  if [[ "${GATE_FAILS}" -eq 0 ]]; then
    log_info "Live gate (L5, ${WATCH_SEC}s): PASS"
  else
    log_warn "Live gate (L5, ${WATCH_SEC}s): FAIL (${GATE_FAILS} criterion(s))"
  fi
  if [[ -n "${WORKDIR}" && ( "${FAILS}" -gt 0 || "${GATE_FAILS}" -gt 0 ) ]]; then
    log_info "Artifacts: ${WORKDIR}/"
  fi
fi
  if [[ "${FAILS}" -eq 0 && "${GATE_FAILS}" -eq 0 ]]; then
    if [[ "${WARNS}" -eq 0 ]]; then
      log_info "OVERALL: PASS"
    else
      log_info "OVERALL: PASS (${WARNS} warning(s) — see WARN lines above)"
    fi
  elif [[ "${GATE_FAILS}" -gt 0 || "${FAILS}" -gt 0 ]]; then
    log_warn "OVERALL: FAIL"
  fi

echo ""
echo "Suggested retest:"
echo "  make voice-gate WATCH=30          # interactive client + call state"
echo "  make voice-smoke-report SMOKE_DURATION=30"
echo "  VOICE_GATE_VERBOSE=1 make voice-gate   # show full L5 help text"
echo "  NONINTERACTIVE=1 SMOKE_CLIENT_IP=<ip> make voice-gate WATCH=30"

exit $(( FAILS > 0 || GATE_FAILS > 0 ? 1 : 0 ))
