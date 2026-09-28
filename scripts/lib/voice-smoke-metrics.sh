#!/usr/bin/env bash
# voice-smoke-metrics.sh — shared counters, peer I/O, and gate verdict for voice smoke.
# Source after voice-smoke-help.sh (uses voice_smoke_normalize_ip).
#
# Expects env (set by caller before use):
#   AWG_CONTAINER, XRAY_CONTAINER, CLIENT_IP, NFQUEUE_NUM
# Optional gate thresholds (voice_smoke_load_gate_defaults sets defaults):
#   GATE_NFQUEUE_MIN, GATE_FWD_DROP_MAX, GATE_AWG_BYTES_MIN, GATE_RX_MIN

voice_smoke_load_gate_defaults() {
  GATE_NFQUEUE_MIN="${GATE_NFQUEUE_MIN:-20}"
  GATE_FWD_DROP_MAX="${GATE_FWD_DROP_MAX:-0}"
  GATE_AWG_BYTES_MIN="${GATE_AWG_BYTES_MIN:-10000}"
  GATE_RX_MIN="${GATE_RX_MIN:-15000}"
}

voice_smoke_gate_summary_line() {
  echo "NFQUEUE>=${GATE_NFQUEUE_MIN} FWD-drop<=${GATE_FWD_DROP_MAX} AWG>=${GATE_AWG_BYTES_MIN} rx>=${GATE_RX_MIN}"
}

voice_smoke_to_int() {
  local v="${1:-0}"
  [[ "${v}" =~ ^[0-9]+$ ]] || v=0
  echo "${v}"
}

voice_smoke_require_container() {
  docker inspect "$1" >/dev/null 2>&1
}

voice_smoke_counter_nfqueue() {
  docker exec "${AWG_CONTAINER}" iptables -t mangle -L PREROUTING -v -n 2>/dev/null \
    | awk -v q="${NFQUEUE_NUM}" '/NFQUEUE/ && $0 ~ q {print $1; exit}'
}

voice_smoke_counter_nat_tcp_redirect() {
  docker exec "${AWG_CONTAINER}" iptables -t nat -L PREROUTING -v -n 2>/dev/null \
    | awk '/REDIRECT/ && /tcp/ {print $1; exit}'
}

voice_smoke_counter_forward_udp_drop() {
  docker exec "${AWG_CONTAINER}" iptables -L FORWARD -v -n 2>/dev/null \
    | awk '/DROP/ && /udp/ && /dpt:!53/ {print $1; exit}'
}

voice_smoke_count_log_since() {
  local container="$1" pattern="$2" since="${3:-}"
  local n
  if [[ -z "${since}" ]]; then
    n="$(docker logs "${container}" 2>&1 | grep -cE "${pattern}" || true)"
  else
    n="$(docker logs "${container}" --since "${since}" 2>&1 | grep -cE "${pattern}" || true)"
  fi
  voice_smoke_to_int "${n}"
}

voice_smoke_count_log_file() {
  local pattern="$1" file="$2"
  local n
  n="$(grep -cE "${pattern}" "${file}" 2>/dev/null)" || n=0
  voice_smoke_to_int "${n}"
}

voice_smoke_count_log_file_icase() {
  local pattern="$1" file="$2"
  local n
  n="$(grep -ciE "${pattern}" "${file}" 2>/dev/null)" || n=0
  voice_smoke_to_int "${n}"
}

voice_smoke_peer_dump_line() {
  local ip="$1"
  ip="$(voice_smoke_normalize_ip "${ip}")"
  docker exec "${AWG_CONTAINER}" awg show awg0 dump 2>/dev/null \
    | awk -F'\t' -v ip="${ip}" '
      NR > 1 && $4 != "" {
        a = $4; sub(/,.*/, "", a); sub(/\/.*$/, "", a)
        if (a == ip) { print; exit }
      }'
}

voice_smoke_peer_handshake_age() {
  local ip="$1" hs now
  hs="$(voice_smoke_peer_dump_line "${ip}" | awk -F'\t' '{print $5}')"
  [[ "${hs}" =~ ^[0-9]+$ ]] || { echo -1; return; }
  now="$(date +%s)"
  echo $((now - hs))
}

voice_smoke_peer_bytes() {
  local ip="$1"
  voice_smoke_peer_dump_line "${ip}" | awk -F'\t' '{print $6, $7}'
}

voice_smoke_peer_list_status() {
  local now
  now="$(date +%s)"
  docker exec "${AWG_CONTAINER}" awg show awg0 dump 2>/dev/null | awk -F'\t' -v now="${now}" '
    NR > 1 && $4 != "" {
      ip = $4
      sub(/,.*/, "", ip)
      hs = ($5 + 0)
      if (hs > 0) age = now - hs "s"
      else age = "never"
      printf "    %s  hs_age=%s  rx=%s tx=%s\n", ip, age, $6, $7
    }'
}

voice_smoke_parse_wg_endpoint() {
  docker exec "${AWG_CONTAINER}" wg show awg0 2>/dev/null | awk -v ip="${CLIENT_IP}" '
    /^peer:/ { ep="" }
    $1=="endpoint:" { ep=$2 }
    $0 ~ "allowed ips: "ip { if (ep != "") print ep; else print "(none)"; exit }
  '
}

voice_smoke_print_metric_row() {
  printf '  %-26s %12s %12s %12s\n' "$1" "$2" "$3" "$4"
}

# Read live iptables + AWG byte counters into named vars (prefix optional).
# Usage: voice_smoke_read_live_snapshot base_nfq base_udp_drop base_rx base_tx
voice_smoke_read_live_snapshot() {
  local -n _nfq=$1
  local -n _udp_drop=$2
  local -n _rx=$3
  local -n _tx=$4
  _nfq="$(voice_smoke_to_int "$(voice_smoke_counter_nfqueue)")"
  _udp_drop="$(voice_smoke_to_int "$(voice_smoke_counter_forward_udp_drop)")"
  read -r _rx _tx <<< "$(voice_smoke_peer_bytes "${CLIENT_IP}")"
  _rx="$(voice_smoke_to_int "${_rx}")"
  _tx="$(voice_smoke_to_int "${_tx}")"
}

# Collect relay/xray window metrics from docker logs (--since timestamp).
voice_smoke_collect_window_metrics_live() {
  local since="$1"
  local -n _first_out=$2
  local -n _first_inject=$3
  local -n _session_open=$4
  local -n _one_way=$5
  local -n _inject_fail=$6
  local -n _relay_fail=$7
  local -n _xray_udp=$8
  _first_out="$(voice_smoke_count_log_since "${AWG_CONTAINER}" 'session first outbound' "${since}")"
  _first_inject="$(voice_smoke_count_log_since "${AWG_CONTAINER}" 'session first inject' "${since}")"
  _session_open="$(voice_smoke_count_log_since "${AWG_CONTAINER}" 'session opened' "${since}")"
  _one_way="$(voice_smoke_count_log_since "${AWG_CONTAINER}" 'session one-way' "${since}")"
  _inject_fail="$(voice_smoke_count_log_since "${AWG_CONTAINER}" 'inject reply failed' "${since}")"
  _relay_fail="$(voice_smoke_count_log_since "${AWG_CONTAINER}" 'packet relay failed|nfqueue receive error|set verdict failed' "${since}")"
  _xray_udp="$(voice_smoke_count_log_since "${XRAY_CONTAINER}" 'accepted udp|from udp:' "${since}")"
}

# Collect relay/xray window metrics from saved log files (full report mode).
voice_smoke_collect_window_metrics_files() {
  local awg_log="$1" xray_log="$2"
  local -n _first_out=$3
  local -n _first_inject=$4
  local -n _one_way=$5
  local -n _inject_fail=$6
  local -n _relay_fail=$7
  local -n _xray_udp=$8
  local -n _awg_log_errors=$9
  _first_out="$(voice_smoke_count_log_file 'session first outbound' "${awg_log}")"
  _first_inject="$(voice_smoke_count_log_file 'session first inject' "${awg_log}")"
  _one_way="$(voice_smoke_count_log_file 'session one-way' "${awg_log}")"
  _inject_fail="$(voice_smoke_count_log_file 'inject reply failed' "${awg_log}")"
  _relay_fail="$(voice_smoke_count_log_file 'packet relay failed|nfqueue receive error|set verdict failed' "${awg_log}")"
  _xray_udp="$(voice_smoke_count_log_file_icase 'accepted udp|from udp:' "${xray_log}")"
  _awg_log_errors="$(voice_smoke_count_log_file 'level=ERROR|panic' "${awg_log}")"
}

# Unified gate verdict (diagnose L5 + smoke report).
# Sets: VOICE_SMOKE_GATE_FAIL_MSG, VOICE_SMOKE_GATE_PASS_MSG, VOICE_SMOKE_GATE_INFO
# Returns: 0 pass, 1 fail
voice_smoke_eval_gate() {
  local d_nfq="$1" d_udp_drop="$2" d_rx="$3" d_tx="$4"
  local w_first_out="$5" w_first_inject="$6" w_one_way="$7"
  local w_inject_fail="$8" w_relay_fail="$9"
  local w_xray_udp="${10:-0}"
  local client_ip="${CLIENT_IP:-?}"

  VOICE_SMOKE_GATE_FAIL_MSG=""
  VOICE_SMOKE_GATE_PASS_MSG=""
  VOICE_SMOKE_GATE_INFO=""

  if [[ "${d_tx}" -lt 100 && "${d_rx}" -lt 100 ]]; then
    VOICE_SMOKE_GATE_FAIL_MSG="no meaningful AWG traffic from ${client_ip} (VPN off, wrong IP, or idle during watch)"
    return 1
  fi
  if [[ "${d_nfq}" -lt "${GATE_NFQUEUE_MIN}" ]]; then
    VOICE_SMOKE_GATE_FAIL_MSG="delta NFQUEUE=${d_nfq} < ${GATE_NFQUEUE_MIN} — voice UDP not captured (not in active call?)"
    return 1
  fi
  if [[ "${d_udp_drop}" -gt "${GATE_FWD_DROP_MAX}" ]]; then
    VOICE_SMOKE_GATE_FAIL_MSG="udp-FWD-drop +${d_udp_drop} > ${GATE_FWD_DROP_MAX} — UDP bypasses NFQUEUE (check mangle/REPLY rules)"
    return 1
  fi
  if [[ "${d_tx}" -lt "${GATE_AWG_BYTES_MIN}" && "${d_rx}" -lt "${GATE_AWG_BYTES_MIN}" ]]; then
    VOICE_SMOKE_GATE_FAIL_MSG="AWG rx/tx deltas (${d_rx}/${d_tx}) below ${GATE_AWG_BYTES_MIN} — relay likely not moving voice bytes"
    return 1
  fi
  if [[ "${w_first_out}" -gt 0 && "${w_first_inject}" -eq 0 ]]; then
    if [[ "${w_one_way}" -gt 0 ]]; then
      VOICE_SMOKE_GATE_FAIL_MSG="relay logged session one-way (${w_one_way}) — outbound without inject (return path broken)"
    else
      VOICE_SMOKE_GATE_FAIL_MSG="no session first inject in watch window — return path broken (Telegram Connecting…)"
    fi
    return 1
  fi
  if [[ "${w_relay_fail}" -gt 0 ]]; then
    VOICE_SMOKE_GATE_FAIL_MSG="nfqueue/relay errors in watch window (${w_relay_fail}) — see awg.log"
    return 1
  fi
  if [[ "${w_inject_fail}" -gt 0 ]]; then
    VOICE_SMOKE_GATE_FAIL_MSG="inject reply failed (${w_inject_fail}) in watch window"
    return 1
  fi
  if [[ "${d_rx}" -lt "${GATE_RX_MIN}" && "${w_first_inject}" -eq 0 && "${w_first_out}" -eq 0 ]]; then
    VOICE_SMOKE_GATE_FAIL_MSG="client rx +${d_rx} < ${GATE_RX_MIN} and no session first inject — possible one-way audio"
    return 1
  fi

  VOICE_SMOKE_GATE_PASS_MSG="voice path active (NFQUEUE +${d_nfq}, FWD-drop +${d_udp_drop}, rx +${d_rx}, tx +${d_tx})"
  if [[ "${w_first_out}" -eq 0 && "${w_first_inject}" -eq 0 ]]; then
    VOICE_SMOKE_GATE_INFO+="reused existing VoIP session (no new first outbound/inject — normal if call started before watch)"$'\n'
  fi
  if [[ "${w_xray_udp}" -eq 0 ]]; then
    VOICE_SMOKE_GATE_INFO+="xray socks udp unchanged in window (shared associate reuse — not a failure by itself)"$'\n'
  else
    VOICE_SMOKE_GATE_INFO+="xray accepted ${w_xray_udp} udp log line(s) in watch window"$'\n'
  fi
  VOICE_SMOKE_GATE_INFO+="GATE PASS = path metrics only; Telegram may still show Connecting… with inject=1 (use call state [1] when already hearing audio)"$'\n'
  return 0
}

voice_smoke_result_pass() { printf '    [PASS] %s\n' "$*"; }
voice_smoke_result_warn() { printf '    [WARN] %s\n' "$*"; }
voice_smoke_result_fail() { printf '    [FAIL] %s\n' "$*"; }
voice_smoke_result_info() { printf '    [INFO] %s\n' "$*"; }

# Human-readable L5 results (default voice-gate / smoke report).
voice_smoke_print_human_results() {
  local d_nfq="$1" d_udp_drop="$2" d_rx="$3" d_tx="$4"
  local w_first_out="$5" w_first_inject="$6" w_one_way="$7"
  local w_inject_fail="$8" w_relay_fail="$9"
  local w_xray_udp="${10:-0}"

  echo "  A) Traffic capture — phone sent VoIP through VPN"
  if [[ "${d_nfq}" -ge "${GATE_NFQUEUE_MIN}" ]]; then
    voice_smoke_result_pass "NFQUEUE captured +${d_nfq} packets (need ≥${GATE_NFQUEUE_MIN})"
  else
    voice_smoke_result_fail "NFQUEUE +${d_nfq} < ${GATE_NFQUEUE_MIN} — voice UDP not captured (not in active call?)"
  fi
  if [[ "${d_udp_drop}" -le "${GATE_FWD_DROP_MAX}" ]]; then
    voice_smoke_result_pass "No RF leak (FORWARD udp-drop +${d_udp_drop})"
  else
    voice_smoke_result_fail "UDP leak: FORWARD udp-drop +${d_udp_drop} > ${GATE_FWD_DROP_MAX}"
  fi
  if [[ "${d_tx}" -lt 100 && "${d_rx}" -lt 100 ]]; then
    voice_smoke_result_fail "No meaningful AWG traffic (VPN off, wrong client, or idle during window)"
  elif [[ "${d_tx}" -ge "${GATE_AWG_BYTES_MIN}" || "${d_rx}" -ge "${GATE_AWG_BYTES_MIN}" ]]; then
    voice_smoke_result_pass "AWG bytes moved (rx +${d_rx}, tx +${d_tx})"
  else
    voice_smoke_result_fail "AWG rx/tx (+${d_rx}/+${d_tx}) below ${GATE_AWG_BYTES_MIN}"
  fi

  echo ""
  echo "  B) Return path — server reply reached the phone"
  if [[ "${w_first_inject}" -gt 0 ]]; then
    voice_smoke_result_pass "First reply delivered (server → phone)"
  elif [[ "${w_first_out}" -eq 0 && "${w_first_inject}" -eq 0 ]]; then
    voice_smoke_result_info "No new reply in window (existing call — OK if audio already up)"
  else
    voice_smoke_result_fail "No reply delivered to client (return path broken)"
  fi
  if [[ "${w_one_way}" -gt 0 ]]; then
    if [[ "${w_first_inject}" -gt 0 ]]; then
      voice_smoke_result_warn "Brief one-way episode then recovered (${w_one_way}×) — common when joining during window"
    else
      voice_smoke_result_fail "One-way episode (${w_one_way}×): outbound without return"
    fi
  else
    voice_smoke_result_pass "No one-way episodes"
  fi
  if [[ "${w_inject_fail}" -eq 0 ]]; then
    voice_smoke_result_pass "No reply delivery errors"
  else
    voice_smoke_result_fail "Reply delivery errors: ${w_inject_fail}"
  fi
  if [[ "${w_relay_fail}" -eq 0 ]]; then
    voice_smoke_result_pass "No nfqueue/relay errors"
  else
    voice_smoke_result_fail "nfqueue/relay errors in window: ${w_relay_fail}"
  fi

  echo ""
  echo "  C) Exit path — xray saw outbound VoIP"
  if [[ "${w_xray_udp}" -gt 0 ]]; then
    voice_smoke_result_pass "xray accepted ${w_xray_udp} outbound UDP in window"
    if [[ "${w_xray_udp}" -le 3 && "${w_first_inject}" -gt 0 ]]; then
      voice_smoke_result_info "Low xray count is OK — gate uses return path, not xray counter"
    fi
  else
    voice_smoke_result_info "xray UDP log quiet in window (OK if return path passed — shared associate reuse)"
  fi
}

voice_smoke_print_engineer_table() {
  local b_nfq="$1" a_nfq="$2" d_nfq="$3"
  local b_tcp="$4" a_tcp="$5" d_tcp="$6"
  local b_udp_drop="$7" a_udp_drop="$8" d_udp_drop="$9"
  local b_rx="${10}" a_rx="${11}" d_rx="${12}"
  local b_tx="${13}" a_tx="${14}" d_tx="${15}"
  local w_session_open="${16}" w_first_out="${17}" w_first_inject="${18}"
  local w_one_way="${19}" w_inject_fail="${20}" w_relay_fail="${21}" w_xray_udp="${22}"

  voice_smoke_print_metric_row "METRIC" "BASE" "NOW" "DELTA"
  voice_smoke_print_metric_row "NFQUEUE pkts" "${b_nfq}" "${a_nfq}" "${d_nfq}"
  voice_smoke_print_metric_row "TCP redirect pkts" "${b_tcp}" "${a_tcp}" "${d_tcp}"
  voice_smoke_print_metric_row "udp-FWD-drop pkts" "${b_udp_drop}" "${a_udp_drop}" "${d_udp_drop}"
  voice_smoke_print_metric_row "AWG client rx bytes" "${b_rx}" "${a_rx}" "${d_rx}"
  voice_smoke_print_metric_row "AWG client tx bytes" "${b_tx}" "${a_tx}" "${d_tx}"
  echo ""
  printf '  %-26s %12s\n' "relay session opened" "${w_session_open}"
  printf '  %-26s %12s\n' "relay first outbound" "${w_first_out}"
  printf '  %-26s %12s\n' "relay first inject" "${w_first_inject}"
  printf '  %-26s %12s\n' "relay one-way warns" "${w_one_way}"
  printf '  %-26s %12s\n' "relay inject failed" "${w_inject_fail}"
  printf '  %-26s %12s\n' "nfqueue/relay errors" "${w_relay_fail}"
  printf '  %-26s %12s\n' "xray socks udp (window)" "${w_xray_udp}"
}
