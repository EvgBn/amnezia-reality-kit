#!/usr/bin/env bash
# smoke-voice-chat.sh — full metric report + logs during Telegram group voice.
#
# Same timing as voice-gate (diagnose-udp-path-watch):
#   [A] Already in group voice → run → stay in call for SMOKE_DURATION seconds
#   [B] Not in voice yet       → run → join within SMOKE_DURATION seconds
#
# Usage:
#   make voice-smoke-report SMOKE_DURATION=30
#   NONINTERACTIVE=1 SMOKE_CLIENT_IP=10.8.0.x make voice-smoke-report
#   make smoke-voice-chat   # legacy target name (same script)
#
# Preflight gate: make voice-gate WATCH=30
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/voice-smoke-help.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/voice-smoke-metrics.sh"

AWG_CONTAINER="${VPN_AWG_CONTAINER:-${VPN_AWG_POD:-vpn-amneziawg}}"
XRAY_CONTAINER="${VPN_XRAY_CONTAINER:-${VPN_XRAY_POD:-vpn-xray}}"
# Legacy: VPN_AWG_POD, VPN_XRAY_POD
CLIENT_IP="${SMOKE_CLIENT_IP:-}"
DURATION="${SMOKE_DURATION:-45}"
HANDSHAKE_MAX_AGE="${SMOKE_HANDSHAKE_MAX_AGE:-180}"
NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-100}"
WORKDIR="${SMOKE_WORKDIR:-/tmp/smoke-voice-chat.$$}"
PREP_SEC="${PREP:-5}"
voice_smoke_load_gate_defaults

mkdir -p "${WORKDIR}"

preflight_client() {
  local age
  if ! voice_smoke_peer_dump_line "${CLIENT_IP}" | grep -q .; then
    log_error "No AWG peer for ${CLIENT_IP}."
    exit 2
  fi
  age="$(voice_smoke_peer_handshake_age "${CLIENT_IP}")"
  if [[ "${age}" -lt 0 || "${age}" -gt "${HANDSHAKE_MAX_AGE}" ]]; then
    log_error "VPN for ${CLIENT_IP} not active (handshake age=${age}s, need <=${HANDSHAKE_MAX_AGE}s)."
    log_error "Connect VPN on the test device before running smoke."
    log_info "Hint: make voice-gate WATCH=30"
    exit 2
  fi
  if ! docker exec "${AWG_CONTAINER}" pgrep -f '/usr/local/bin/udp-relay' >/dev/null 2>&1; then
    log_error "udp-relay not running in ${AWG_CONTAINER}"
    exit 2
  fi
}

snapshot_baseline() {
  BASE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  BASE_NFQUEUE="$(voice_smoke_to_int "$(voice_smoke_counter_nfqueue)")"
  BASE_UDP_DROP="$(voice_smoke_to_int "$(voice_smoke_counter_forward_udp_drop)")"
  read -r BASE_WG_RX BASE_WG_TX <<< "$(voice_smoke_peer_bytes "${CLIENT_IP}")"
  BASE_WG_EP="$(voice_smoke_parse_wg_endpoint)"
  BASE_HS_AGE="$(voice_smoke_peer_handshake_age "${CLIENT_IP}")"
  docker logs "${AWG_CONTAINER}" --since 1s >/dev/null 2>&1 || true
  docker logs "${XRAY_CONTAINER}" --since 1s >/dev/null 2>&1 || true
}

collect_logs() {
  docker logs "${AWG_CONTAINER}" --since "${BASE_TS}" 2>&1 > "${WORKDIR}/awg.log" || true
  docker logs "${XRAY_CONTAINER}" --since "${BASE_TS}" 2>&1 > "${WORKDIR}/xray-socks.log" || true
  docker exec "${AWG_CONTAINER}" iptables-save 2>/dev/null > "${WORKDIR}/iptables-save.txt" || true
}

print_report() {
  local end_nfqueue end_udp_drop end_wg_rx end_wg_tx end_hs_age
  local delta_nfqueue delta_udp_drop delta_rx delta_tx
  local w_first_out w_first_inject w_one_way w_inject_fail w_relay_fail w_xray_udp awg_log_errors
  local fail=0 info_line

  end_nfqueue="$(voice_smoke_to_int "$(voice_smoke_counter_nfqueue)")"
  end_udp_drop="$(voice_smoke_to_int "$(voice_smoke_counter_forward_udp_drop)")"
  read -r end_wg_rx end_wg_tx <<< "$(voice_smoke_peer_bytes "${CLIENT_IP}")"
  end_hs_age="$(voice_smoke_peer_handshake_age "${CLIENT_IP}")"
  delta_nfqueue=$((end_nfqueue - BASE_NFQUEUE))
  delta_udp_drop=$((end_udp_drop - BASE_UDP_DROP))
  delta_rx=$(( $(voice_smoke_to_int "${end_wg_rx}") - $(voice_smoke_to_int "${BASE_WG_RX}") ))
  delta_tx=$(( $(voice_smoke_to_int "${end_wg_tx}") - $(voice_smoke_to_int "${BASE_WG_TX}") ))

  voice_smoke_collect_window_metrics_files "${WORKDIR}/awg.log" "${WORKDIR}/xray-socks.log" \
    w_first_out w_first_inject w_one_way w_inject_fail w_relay_fail w_xray_udp awg_log_errors

  local w_session_open=0

  echo ""
  echo "=== smoke-voice-chat report (NFQUEUE -> udp-relay -> SOCKS) ==="
  echo "mode:       FULL REPORT (human results + raw counters; same timing as voice-gate)"
  echo "window:     ${BASE_TS} .. $(date -u +%Y-%m-%dT%H:%M:%SZ) (${DURATION}s)"
  echo "client:     ${CLIENT_IP}"
  echo "handshake:  ${BASE_HS_AGE}s ago -> ${end_hs_age}s ago (must stay <=${HANDSHAKE_MAX_AGE}s)"
  echo "nfqueue:    queue ${NFQUEUE_NUM}"
  echo "gate:       $(voice_smoke_gate_summary_line)"
  echo "wg endpoint: ${BASE_WG_EP:-(unknown)}"
  if [[ "${BASE_WG_EP:-}" == 172.20.0.1:* ]]; then
    echo "wg note:     endpoint is docker gateway (NAT hairpin — normal for clients behind same host)"
  fi
  echo ""
  echo "── Results (${DURATION}s window) ──"
  echo ""
  voice_smoke_print_human_results "${delta_nfqueue}" "${delta_udp_drop}" "${delta_rx}" "${delta_tx}" \
    "${w_first_out}" "${w_first_inject}" "${w_one_way}" "${w_inject_fail}" "${w_relay_fail}" "${w_xray_udp}"
  echo ""
  echo "── Engineer details (raw counters) ──"
  echo ""
  voice_smoke_print_engineer_table \
    "${BASE_NFQUEUE}" "${end_nfqueue}" "${delta_nfqueue}" \
    "0" "0" "0" \
    "${BASE_UDP_DROP}" "${end_udp_drop}" "${delta_udp_drop}" \
    "${BASE_WG_RX}" "${end_wg_rx}" "${delta_rx}" \
    "${BASE_WG_TX}" "${end_wg_tx}" "${delta_tx}" \
    "${w_session_open}" "${w_first_out}" "${w_first_inject}" \
    "${w_one_way}" "${w_inject_fail}" "${w_relay_fail}" "${w_xray_udp}"
  printf '  %-28s %12s\n' "awg container errors" "${awg_log_errors}"
  echo ""
  echo "OUT tcpdump (return path on OUT — optional):"
  echo "  ssh vpn-out \"sudo tcpdump -ni any 'host 91.108.9.58 and udp portrange 32000-32003'\""
  echo ""

  echo "=== verdict ==="
  if [[ "${end_hs_age}" -gt "${HANDSHAKE_MAX_AGE}" ]]; then
    log_warn "FAIL: VPN disconnected during test (handshake now ${end_hs_age}s old)"
    fail=1
  fi

  if voice_smoke_eval_gate "${delta_nfqueue}" "${delta_udp_drop}" "${delta_rx}" "${delta_tx}" \
      "${w_first_out}" "${w_first_inject}" "${w_one_way}" "${w_inject_fail}" "${w_relay_fail}" "${w_xray_udp}"; then
    log_info "PASS: VoIP captured and return path OK in ${DURATION}s window"
    voice_smoke_result_info "PASS = relay metrics only; Telegram UI may still show Connecting…"
  else
    log_warn "FAIL: ${VOICE_SMOKE_GATE_FAIL_MSG}"
    fail=1
  fi

  if [[ "${awg_log_errors}" -gt 0 ]]; then
    log_warn "WARN: ${awg_log_errors} error line(s) in awg container log"
  fi

  echo ""
  echo "logs saved: ${WORKDIR}/awg.log ${WORKDIR}/xray-socks.log ${WORKDIR}/iptables-save.txt"
  if [[ "${fail}" -eq 0 ]]; then
    log_info "OVERALL: PASS (NFQUEUE path metrics OK; Telegram UI quality not validated here)"
  else
    log_warn "OVERALL: FAIL — run: make voice-gate WATCH=30"
  fi
  return "${fail}"
}

main() {
  local smoke_rc=0

  if ! voice_smoke_require_container "${AWG_CONTAINER}"; then
    log_error "container ${AWG_CONTAINER} not found"
    exit 1
  fi
  if ! voice_smoke_require_container "${XRAY_CONTAINER}"; then
    log_error "container ${XRAY_CONTAINER} not found"
    exit 1
  fi

  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    log_info "Resolving client ${SMOKE_CLIENT_IP:-?} (NONINTERACTIVE)…"
  fi

  if ! CLIENT_IP="$(voice_smoke_resolve_client_ip "${AWG_CONTAINER}" "${HANDSHAKE_MAX_AGE}" "${ROOT}")"; then
    exit 1
  fi
  CLIENT_IP="$(voice_smoke_normalize_ip "${CLIENT_IP}")"
  preflight_client

  echo "=== voice smoke report (NFQUEUE path) ==="
  voice_smoke_print_purpose report "${CLIENT_IP}"
  voice_smoke_print_timing "${DURATION}" "${CLIENT_IP}"
  voice_smoke_prompt_call_state "${DURATION}"

  log_info "Baseline snapshot for ${CLIENT_IP}…"
  snapshot_baseline
  voice_smoke_prep_countdown "${PREP_SEC}" "${DURATION}"
  log_info "Collecting metrics for ${DURATION}s (stay in ACTIVE group voice)…"
  sleep "${DURATION}"

  log_info "Collecting logs and metrics…"
  collect_logs
  print_report || smoke_rc=$?

  exit "${smoke_rc}"
}

main "$@"
