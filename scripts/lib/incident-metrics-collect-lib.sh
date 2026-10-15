# shellcheck shell=bash
# One metrics-tick sample: probes + deltas. Sets INC_METRICS_* (see incident_metrics_collect_clear).
# Requires incident-udp-log-patterns.sh, incident-snapshot-lib.sh, incident-channel-lib.sh
# sourced before this lib (see incident_metrics_collect_prereq).

incident_metrics_collect_prereq() {
  if [[ -z "${INCIDENT_AWG_INJECT_FAIL_GREP:-}" || -z "${INCIDENT_AWG_IPT2SOCKS_CLIENT_TO_GREP:-}" ]]; then
    echo "incident-metrics-collect-lib: source incident-udp-log-patterns.sh before this lib" >&2
    return 1
  fi
  if ! declare -f incident_swap_used_mb >/dev/null 2>&1 \
    || ! declare -f incident_awg_nfqueue_pkts >/dev/null 2>&1 \
    || ! declare -f incident_peer_transfer_totals >/dev/null 2>&1; then
    echo "incident-metrics-collect-lib: source incident-snapshot-lib.sh before this lib" >&2
    return 1
  fi
  if ! declare -f incident_tick_state_load_blob >/dev/null 2>&1 \
    || ! declare -f incident_metrics_csv_v2_build_row >/dev/null 2>&1 \
    || ! declare -f incident_int_or_zero >/dev/null 2>&1; then
    echo "incident-metrics-collect-lib: source incident-channel-lib.sh before this lib" >&2
    return 1
  fi
  return 0
}

incident_mem_avail_mb() {
  awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "n/a"
}

# pattern: fixed substring (grep -F), not ERE — use INCIDENT_AWG_* from incident-udp-log-patterns.sh.
incident_docker_log_count() {
  local container="$1" pattern="$2" since="${3:-${INCIDENT_LOG_DELTA_SINCE}}"
  local n
  n="$(docker logs "${container}" --since "${since}" 2>&1 | grep -cF "${pattern}" || true)"
  incident_int_or_zero "${n}"
}

incident_mtproxy_inbound_accepted() {
  local stats_port="${1:-8888}"
  curl -sf --max-time 3 "http://127.0.0.1:${stats_port}/stats" 2>/dev/null \
    | awk -F'\t' '/^inbound_connections_accepted/ {print $2; exit}' || echo "0"
}

incident_udp_scenario_last() {
  local awg="$1" since="${2:-6m}"
  docker logs "${awg}" --since "${since}" 2>&1 \
    | grep 'associate health' \
    | tail -1 \
    | sed -n 's/.*path_scenario=\([^ ]*\).*/\1/p' || echo "n/a"
}

incident_metrics_collect_clear() {
  unset INC_METRICS_TS INC_METRICS_ROW
  unset INC_METRICS_SOCKS_OK INC_METRICS_COLD_INT INC_METRICS_STREAK
  unset INC_METRICS_INJECT_D INC_METRICS_P2P_D INC_METRICS_ONE_WAY_D
  unset INC_METRICS_NFQ_NOW INC_METRICS_PEER_RX_NOW INC_METRICS_PEER_TX_NOW INC_METRICS_MT_NOW
  unset INC_CSV_V2_FIELD
}

# Collect one tick; writes cumulative counters into INC_METRICS_*_NOW for state save.
incident_metrics_tick_collect() {
  local state_path="$1"
  incident_metrics_collect_prereq || return 1
  incident_metrics_collect_clear

  local ts mem swap load coredns_health streak
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mem="$(incident_mem_avail_mb)"
  swap="$(incident_swap_used_mb)"
  load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo n/a)"

  coredns_health="$(docker inspect "${COREDNS_CONTAINER}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null || echo n/a)"
  streak="$(docker inspect "${COREDNS_CONTAINER}" --format '{{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}0{{end}}' 2>/dev/null || echo 0)"
  streak="$(incident_int_or_zero "${streak}")"

  local socks_conn fd_awg fd_cd
  socks_conn="$(incident_awg_socks_conn_count "${AWG_CONTAINER}" "${XRAY_IP}" "${SOCKS_PORT}")"
  fd_awg="$(incident_ipt2socks_max_fd "${AWG_CONTAINER}")"
  fd_cd="$(incident_ipt2socks_max_fd "${COREDNS_CONTAINER}")"

  local nfq_now peer_rx_now peer_tx_now
  nfq_now="$(incident_iptables_pkts_field "$(incident_awg_nfqueue_pkts "${AWG_CONTAINER}" "${NFQUEUE_NUM}")")"
  peer_rx_now=0
  peer_tx_now=0
  if docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
    read -r peer_rx_now peer_tx_now <<<"$(incident_peer_transfer_totals "${AWG_CONTAINER}" "${CLIENT_IP}")"
  fi
  peer_rx_now="$(incident_int_or_zero "${peer_rx_now}")"
  peer_tx_now="$(incident_int_or_zero "${peer_tx_now}")"

  local prev_blob nfq_prev rx_prev tx_prev mt_prev
  prev_blob="$(incident_tick_state_load_blob "${state_path}" "${ts}")"
  nfq_prev="$(incident_state_get "${prev_blob}" nfqueue)"
  rx_prev="$(incident_state_get "${prev_blob}" peer_rx)"
  tx_prev="$(incident_state_get "${prev_blob}" peer_tx)"
  mt_prev="$(incident_state_get "${prev_blob}" mtproxy_inbound)"

  local nfq_d=0 rx_d=0 tx_d=0 mt_d=0
  if [[ -n "${prev_blob}" ]]; then
    nfq_prev="$(incident_int_or_zero "${nfq_prev}")"
    rx_prev="$(incident_int_or_zero "${rx_prev}")"
    tx_prev="$(incident_int_or_zero "${tx_prev}")"
    nfq_d=$((nfq_now - nfq_prev))
    rx_d=$((peer_rx_now - rx_prev))
    tx_d=$((peer_tx_now - tx_prev))
  fi
  [[ "${nfq_d}" -lt 0 ]] && nfq_d=0
  [[ "${rx_d}" -lt 0 ]] && rx_d=0
  [[ "${tx_d}" -lt 0 ]] && tx_d=0

  local mt_now=0
  if docker inspect "${TELEPROXY_CONTAINER}" >/dev/null 2>&1; then
    mt_now="$(incident_mtproxy_inbound_accepted "${MTPROXY_STATS_PORT}")"
  fi
  mt_now="$(incident_int_or_zero "${mt_now}")"
  if [[ -n "${prev_blob}" && "${mt_prev}" =~ ^[0-9]+$ ]]; then
    mt_d=$((mt_now - mt_prev))
    [[ "${mt_d}" -lt 0 ]] && mt_d=0
  fi

  local since="${INCIDENT_LOG_DELTA_SINCE}"
  local inject_d one_way_d ipt_awg_d ipt_cd_d p2p_d
  inject_d="$(incident_docker_log_count "${AWG_CONTAINER}" "${INCIDENT_AWG_INJECT_FAIL_GREP}" "${since}")"
  one_way_d="$(incident_docker_log_count "${AWG_CONTAINER}" 'session one-way' "${since}")"
  ipt_awg_d="$(incident_docker_log_count "${AWG_CONTAINER}" "${INCIDENT_AWG_IPT2SOCKS_CLIENT_TO_GREP}" "${since}")"
  ipt_cd_d="$(incident_docker_log_count "${COREDNS_CONTAINER}" 'Connection reset by peer' "${since}")"
  p2p_d=0
  if docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
    p2p_d="$(docker logs "${AWG_CONTAINER}" --since "${since}" 2>&1 | grep -F "${CLIENT_IP}" | grep -c ':6881' || true)"
  fi
  p2p_d="$(incident_int_or_zero "${p2p_d}")"

  local xray_tp_d=0 xray_other_d=0
  if docker inspect "${XRAY_CONTAINER}" >/dev/null 2>&1; then
    local xray_log
    xray_log="$(docker logs "${XRAY_CONTAINER}" --since "${since}" 2>&1 || true)"
    xray_tp_d="$(printf '%s\n' "${xray_log}" | grep -c "from tcp:${TELEPROXY_IP}" 2>/dev/null || true)"
    local xray_acc
    xray_acc="$(printf '%s\n' "${xray_log}" | grep -c 'accepted' 2>/dev/null || true)"
    xray_tp_d="$(incident_int_or_zero "${xray_tp_d}")"
    xray_acc="$(incident_int_or_zero "${xray_acc}")"
    xray_other_d=$((xray_acc - xray_tp_d))
    [[ "${xray_other_d}" -lt 0 ]] && xray_other_d=0
  fi

  local udp_scen cold_ms dns_client_ms socks_ms socks_ok
  udp_scen="$(incident_udp_scenario_last "${AWG_CONTAINER}")"

  cold_ms="n/a"
  if docker inspect "${COREDNS_CONTAINER}" >/dev/null 2>&1; then
    local probe="probe-$(date +%s).invalid.example.com"
    cold_ms="$(docker exec "${COREDNS_CONTAINER}" dig @127.0.0.1 +norecurse +time=5 +tries=1 "${probe}" A +stats 2>/dev/null \
      | awk '/Query time:/ {print $4; exit}' || echo n/a)"
  fi

  dns_client_ms="n/a"
  if docker exec "${AWG_CONTAINER}" sh -c "command -v dig >/dev/null" 2>/dev/null; then
    dns_client_ms="$(docker exec "${AWG_CONTAINER}" dig @"${COREDNS_IP}" +time=5 +tries=1 cloudflare.com A +stats 2>/dev/null \
      | awk '/Query time:/ {print $4; exit}' || echo n/a)"
  fi

  socks_ms="n/a"
  if [[ -n "${SOCKS_USER:-}" && -n "${SOCKS_PASSWORD:-}" ]]; then
    socks_ms="$(curl -4 -sS -m 10 -x "socks5h://127.0.0.1:${SOCKS_PORT}" \
      --proxy-user "${SOCKS_USER}:${SOCKS_PASSWORD}" \
      -o /dev/null -w '%{time_total}' "${PREFLIGHT_OUT_EGRESS_URL:-https://api.ipify.org}" 2>/dev/null || echo fail)"
  fi
  socks_ok="$(incident_socks_ok_from_ms "${socks_ms}")"

  local out_icmp_ok=0 out_tcp_ok=0
  if [[ -n "${OUT_EXIT_ADDRESS:-}" ]] && docker inspect "${XRAY_CONTAINER}" >/dev/null 2>&1; then
    if docker exec "${XRAY_CONTAINER}" ping -c 1 -W 3 "${OUT_EXIT_ADDRESS}" >/dev/null 2>&1; then
      out_icmp_ok=1
    fi
  fi
  if [[ -n "${OUT_EXIT_ADDRESS:-}" ]]; then
    local tcp_r
    tcp_r="$(incident_xray_tcp_probe "${XRAY_CONTAINER}" "${OUT_EXIT_ADDRESS}" "${OUT_REALITY_PORT}")"
    [[ "${tcp_r}" == ok ]] && out_tcp_ok=1
  fi

  local cold_int=0
  if [[ "${cold_ms}" =~ ^[0-9]+$ ]]; then
    cold_int="${cold_ms}"
  fi

  INC_METRICS_TS="${ts}"
  INC_METRICS_SOCKS_OK="${socks_ok}"
  INC_METRICS_COLD_INT="${cold_int}"
  INC_METRICS_STREAK="${streak}"
  INC_METRICS_INJECT_D="${inject_d}"
  INC_METRICS_P2P_D="${p2p_d}"
  INC_METRICS_ONE_WAY_D="${one_way_d}"
  INC_METRICS_NFQ_NOW="${nfq_now}"
  INC_METRICS_PEER_RX_NOW="${peer_rx_now}"
  INC_METRICS_PEER_TX_NOW="${peer_tx_now}"
  INC_METRICS_MT_NOW="${mt_now}"

  # Column order = INCIDENT_CSV_V2_HEADER only (see incident-channel-lib.sh).
  INC_METRICS_ROW="$(incident_metrics_csv_v2_build_row \
    "${ts}" "${mem}" "${swap}" "${load}" "${socks_ok}" "${socks_ms}" \
    "${out_icmp_ok}" "${out_tcp_ok}" "${coredns_health}" "${streak}" "${cold_ms}" \
    "${dns_client_ms}" "${socks_conn}" "${fd_awg}" "${fd_cd}" "${nfq_d}" "${rx_d}" "${tx_d}" \
    "${inject_d}" "${one_way_d}" "${ipt_awg_d}" "${ipt_cd_d}" "${p2p_d}" "${xray_tp_d}" \
    "${xray_other_d}" "${mt_d}" "${udp_scen}")" || return 1
}
