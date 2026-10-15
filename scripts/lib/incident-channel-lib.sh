# shellcheck shell=bash
# Channel matrix (CH0–CH6), CSV v2 schema, events.jsonl, verdict v2 — incident RCA rules.
# Sourced by metrics-tick.sh, collect-snapshot.sh, incident-metrics-collect-lib (via prereq).

readonly INCIDENT_CSV_V2_HEADER='ts_utc,mem_avail_mb,swap_used_mb,load1,socks_ok,socks_ms,out_icmp_ok,out_tcp443_ok,coredns_health,coredns_streak,cold_dig_ms,dns_client_ms,awg_socks_conn,fd_awg_max,fd_coredns_max,nfqueue_pkts_delta,peer_rx_delta,peer_tx_delta,inject_fail_delta,one_way_delta,ipt2socks_timeout_awg_delta,ipt2socks_rst_coredns_delta,p2p_6881_delta,xray_accept_tp_delta,xray_accept_other_delta,mtproxy_inbound_delta,udp_scenario'

INCIDENT_EVENTS_DIR="${INCIDENT_EVENTS_DIR:-${HOME}/log/events}"
INCIDENT_METRICS_TAIL_LINES="${INCIDENT_METRICS_TAIL_LINES:-30}"
INCIDENT_LOG_DELTA_SINCE="${INCIDENT_LOG_DELTA_SINCE:-150s}"
INCIDENT_TICK_MAX_GAP_SEC="${INCIDENT_TICK_MAX_GAP_SEC:-600}"

# Shared thresholds: tick (2m deltas) vs snapshot (LOG_SINCE window counts).
INCIDENT_TICK_COLD_DNS_MS_MAX="${INCIDENT_TICK_COLD_DNS_MS_MAX:-5000}"
INCIDENT_TICK_COREDNS_STREAK_MIN="${INCIDENT_TICK_COREDNS_STREAK_MIN:-3}"
INCIDENT_TICK_INJECT_FAIL_DELTA_MIN="${INCIDENT_TICK_INJECT_FAIL_DELTA_MIN:-15}"
INCIDENT_TICK_ONE_WAY_DELTA_MIN="${INCIDENT_TICK_ONE_WAY_DELTA_MIN:-5}"
INCIDENT_TICK_P2P_CORRELATION_MIN="${INCIDENT_TICK_P2P_CORRELATION_MIN:-30}"
INCIDENT_SNAPSHOT_INJECT_FAIL_MIN="${INCIDENT_SNAPSHOT_INJECT_FAIL_MIN:-10}"
INCIDENT_SNAPSHOT_P2P_CORRELATION_MIN="${INCIDENT_SNAPSHOT_P2P_CORRELATION_MIN:-100}"
INCIDENT_SNAPSHOT_IPT2SOCKS_TO_MIN="${INCIDENT_SNAPSHOT_IPT2SOCKS_TO_MIN:-10}"

# Set by incident_primary_from_signals until the next call (inputs are unset inside).
INC_PRIMARY_CODE=""
INC_PRIMARY_CORRELATION="none"
INC_PRIMARY_SUBTYPE=""

incident_primary_sig_unset_inputs() {
  unset INC_SIG_MODE
  unset INC_SIG_SOCKS_OK INC_SIG_COLD_MS INC_SIG_STREAK
  unset INC_SIG_INJECT_DELTA INC_SIG_P2P_DELTA INC_SIG_ONE_WAY_DELTA
  unset INC_SIG_HOST INC_SIG_OUT_ICMP INC_SIG_OUT_TCP INC_SIG_SOCKS
  unset INC_SIG_DNS_LOCAL INC_SIG_UDP_RELAY INC_SIG_INJECT_N INC_SIG_P2P_N
  unset INC_SIG_IPT2SOCKS_TO INC_SIG_RST_COREDNS
}

incident_primary_clear_outputs() {
  unset INC_PRIMARY_CODE INC_PRIMARY_CORRELATION INC_PRIMARY_SUBTYPE
}

incident_int_or_zero() {
  local v="${1:-0}"
  [[ "${v}" =~ ^[0-9]+$ ]] && echo "${v}" || echo "0"
}

incident_metrics_ensure_v2_csv() {
  local csv="$1"
  if [[ ! -f "${csv}" ]]; then
    echo "${INCIDENT_CSV_V2_HEADER}" > "${csv}"
    chmod 600 "${csv}" 2>/dev/null || true
    return 0
  fi
  if ! head -1 "${csv}" | grep -q 'socks_ok'; then
    mv "${csv}" "${csv}.v1-bak-$(date +%s)"
    echo "${INCIDENT_CSV_V2_HEADER}" > "${csv}"
    chmod 600 "${csv}" 2>/dev/null || true
  fi
}

incident_metrics_csv_v2_field_count() {
  awk -F, '{print NF}' <<<"${INCIDENT_CSV_V2_HEADER}"
}

# Row order follows INCIDENT_CSV_V2_HEADER only. Set INC_CSV_V2_FIELD[name]=value before call.
incident_metrics_csv_v2_row_from_map() {
  local IFS=, line="" name first=1
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if [[ "${first}" == 1 ]]; then
      first=0
      line="${INC_CSV_V2_FIELD[$name]-}"
    else
      line+=",${INC_CSV_V2_FIELD[$name]-}"
    fi
  done <<<"$(tr ',' '\n' <<<"${INCIDENT_CSV_V2_HEADER}")"
  echo "${line}"
}

# Args: one value per column, in INCIDENT_CSV_V2_HEADER order (names not repeated at call sites).
incident_metrics_csv_v2_build_row() {
  local expected n i=1 name
  expected="$(incident_metrics_csv_v2_field_count)"
  n=$#
  if [[ "${n}" -ne "${expected}" ]]; then
    echo "incident_metrics_csv_v2_build_row: expected ${expected} values, got ${n}" >&2
    return 1
  fi
  declare -gA INC_CSV_V2_FIELD
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    INC_CSV_V2_FIELD["${name}"]="${!i}"
    i=$((i + 1))
  done <<<"$(tr ',' '\n' <<<"${INCIDENT_CSV_V2_HEADER}")"
  incident_metrics_csv_v2_row_from_map
}

# CSV v2 analytics: resolve columns by header name (first row), not fixed indices.
incident_metrics_csv_v2_count_eq() {
  local csv="$1" field="$2" value="$3"
  awk -v f="${field}" -v v="${value}" -F, '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == f) c = i; next }
    c > 0 && $c == v { n++ } END { print n + 0 }' "${csv}"
}

incident_metrics_csv_v2_max_numeric() {
  local csv="$1" field="$2"
  awk -v f="${field}" -F, '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == f) c = i; next }
    c > 0 && $c ~ /^[0-9]+$/ { print $c }' "${csv}" | sort -n | tail -1
}

# Returns: n_fail n_ok max_conn max_inject (whitespace-separated). Column names from CSV header row.
incident_metrics_csv_v2_quick_stats() {
  local csv="$1"
  local n_fail n_ok max_conn max_inject
  n_fail="$(incident_metrics_csv_v2_count_eq "${csv}" socks_ok 0)"
  n_ok="$(incident_metrics_csv_v2_count_eq "${csv}" socks_ok 1)"
  max_conn="$(incident_metrics_csv_v2_max_numeric "${csv}" awg_socks_conn)"
  max_inject="$(incident_metrics_csv_v2_max_numeric "${csv}" inject_fail_delta)"
  echo "${n_fail} ${n_ok} ${max_conn:-0} ${max_inject:-0}"
}

incident_tick_state_path() {
  local metrics_dir="$1"
  echo "${metrics_dir}/.tick-state"
}

# Cumulative counters for per-tick deltas (multiline key=value; never concatenate via $()+).
incident_tick_state_save() {
  local path="$1" ts="$2" nfqueue="$3" peer_rx="$4" peer_tx="$5" mtproxy_inbound="$6"
  {
    incident_state_kv tick_ts "${ts}"
    incident_state_kv nfqueue "${nfqueue}"
    incident_state_kv peer_rx "${peer_rx}"
    incident_state_kv peer_tx "${peer_tx}"
    incident_state_kv mtproxy_inbound "${mtproxy_inbound}"
  } > "${path}"
  chmod 600 "${path}" 2>/dev/null || true
}

# Previous tick state for deltas; empty after cron gap > INCIDENT_TICK_MAX_GAP_SEC.
incident_tick_state_load_blob() {
  local path="$1" now_ts="$2"
  local blob="" prev_ts now_epoch prev_epoch gap_max
  [[ -f "${path}" ]] || {
    echo ""
    return 0
  }
  blob="$(cat "${path}")"
  prev_ts="$(incident_state_get "${blob}" tick_ts)"
  if [[ -z "${prev_ts}" ]]; then
    # Pre-tick_ts or single-line corrupted KV (nfqueue=…peer_rx=…): do not use for deltas.
    if printf '%s\n' "${blob}" | grep -q '^tick_ts='; then
      echo "${blob}"
    else
      echo ""
    fi
    return 0
  fi
  now_epoch="$(date -u -d "${now_ts}" +%s 2>/dev/null || echo 0)"
  prev_epoch="$(date -u -d "${prev_ts}" +%s 2>/dev/null || echo 0)"
  gap_max="${INCIDENT_TICK_MAX_GAP_SEC:-600}"
  if [[ "${now_epoch}" -gt 0 && "${prev_epoch}" -gt 0 ]]; then
    if (( now_epoch - prev_epoch > gap_max )); then
      echo ""
      return 0
    fi
  fi
  echo "${blob}"
}

# Canonical primary from signals. Mode: tick | snapshot (INC_SIG_* inputs).
# Tick: INC_SIG_SOCKS_OK, INC_SIG_COLD_MS, INC_SIG_STREAK, INC_SIG_INJECT_DELTA,
#       INC_SIG_P2P_DELTA, INC_SIG_ONE_WAY_DELTA
# Snapshot: INC_SIG_HOST, INC_SIG_OUT_ICMP, INC_SIG_OUT_TCP, INC_SIG_SOCKS,
#           INC_SIG_DNS_LOCAL, INC_SIG_UDP_RELAY, INC_SIG_INJECT_N, INC_SIG_P2P_N,
#           INC_SIG_IPT2SOCKS_TO, INC_SIG_RST_COREDNS
incident_primary_from_signals() {
  INC_PRIMARY_CODE=""
  INC_PRIMARY_CORRELATION="none"
  INC_PRIMARY_SUBTYPE=""

  local mode="${INC_SIG_MODE:-tick}"
  if [[ "${mode}" == tick ]]; then
    local socks_ok cold_ms streak inject_d p2p_d one_way_d
    socks_ok="${INC_SIG_SOCKS_OK:-0}"
    cold_ms="${INC_SIG_COLD_MS:-0}"
    streak="${INC_SIG_STREAK:-0}"
    inject_d="${INC_SIG_INJECT_DELTA:-0}"
    p2p_d="${INC_SIG_P2P_DELTA:-0}"
    one_way_d="${INC_SIG_ONE_WAY_DELTA:-0}"
    incident_primary_sig_unset_inputs
    cold_ms="$(incident_int_or_zero "${cold_ms}")"
    streak="$(incident_int_or_zero "${streak}")"
    inject_d="$(incident_int_or_zero "${inject_d}")"
    p2p_d="$(incident_int_or_zero "${p2p_d}")"
    one_way_d="$(incident_int_or_zero "${one_way_d}")"

    if [[ "${socks_ok}" == "0" ]]; then
      INC_PRIMARY_CODE="CH5"
      return 0
    fi
    if [[ "${cold_ms}" -gt "${INCIDENT_TICK_COLD_DNS_MS_MAX}" ]] \
      || [[ "${streak}" -ge "${INCIDENT_TICK_COREDNS_STREAK_MIN}" ]]; then
      INC_PRIMARY_CODE="CH4"
      return 0
    fi
    if [[ "${inject_d}" -gt "${INCIDENT_TICK_INJECT_FAIL_DELTA_MIN}" && "${socks_ok}" == "1" ]]; then
      INC_PRIMARY_CODE="CH3"
      if [[ "${p2p_d}" -gt "${INCIDENT_TICK_P2P_CORRELATION_MIN}" ]]; then
        INC_PRIMARY_CORRELATION="p2p_udp_storm"
      fi
      return 0
    fi
    if [[ "${one_way_d}" -gt "${INCIDENT_TICK_ONE_WAY_DELTA_MIN}" && "${socks_ok}" == "1" ]]; then
      INC_PRIMARY_CODE="CH3"
      return 0
    fi
    return 0
  fi

  if [[ "${mode}" != snapshot ]]; then
    incident_primary_sig_unset_inputs
    return 0
  fi

  local host out_icmp out_tcp socks dns_local udp_relay inject_n p2p_n ipt_to rst_n
  host="${INC_SIG_HOST:-unknown}"
  out_icmp="${INC_SIG_OUT_ICMP:-unknown}"
  out_tcp="${INC_SIG_OUT_TCP:-unknown}"
  socks="${INC_SIG_SOCKS:-unknown}"
  dns_local="${INC_SIG_DNS_LOCAL:-unknown}"
  udp_relay="${INC_SIG_UDP_RELAY:-unknown}"
  inject_n="${INC_SIG_INJECT_N:-0}"
  p2p_n="${INC_SIG_P2P_N:-0}"
  ipt_to="${INC_SIG_IPT2SOCKS_TO:-0}"
  rst_n="${INC_SIG_RST_COREDNS:-0}"
  incident_primary_sig_unset_inputs
  inject_n="$(incident_int_or_zero "${inject_n}")"
  p2p_n="$(incident_int_or_zero "${p2p_n}")"
  ipt_to="$(incident_int_or_zero "${ipt_to}")"
  rst_n="$(incident_int_or_zero "${rst_n}")"

  if [[ "${host}" == fail ]]; then
    INC_PRIMARY_CODE="CH0"
    return 0
  fi
  if [[ "${out_tcp}" == fail && "${out_icmp}" == ok ]]; then
    INC_PRIMARY_CODE="CH6"
    return 0
  fi
  if [[ "${socks}" == timeout || "${socks}" == fail ]]; then
    INC_PRIMARY_CODE="CH5"
    return 0
  fi
  if [[ "${dns_local}" == fail && "${socks}" == ok ]]; then
    INC_PRIMARY_CODE="CH4"
    INC_PRIMARY_SUBTYPE="dns_path"
    return 0
  fi
  if [[ "${socks}" == ok && "${dns_local}" == ok ]]; then
    if [[ "${inject_n}" -gt "${INCIDENT_SNAPSHOT_INJECT_FAIL_MIN}" || "${udp_relay}" == degraded ]]; then
      INC_PRIMARY_CODE="CH3"
      if [[ "${p2p_n}" -gt "${INCIDENT_SNAPSHOT_P2P_CORRELATION_MIN}" ]]; then
        INC_PRIMARY_CORRELATION="p2p_udp_heavy_window"
      fi
      return 0
    fi
    if [[ "${ipt_to}" -gt "${INCIDENT_SNAPSHOT_IPT2SOCKS_TO_MIN}" ]]; then
      INC_PRIMARY_CODE="CLIENT_TCP_STALL"
      return 0
    fi
    if [[ "${rst_n}" -gt 0 ]]; then
      INC_PRIMARY_CODE="CH4"
      INC_PRIMARY_SUBTYPE="dns_rst_chronic"
      INC_PRIMARY_CORRELATION="coredns_rst_in_window_not_necessarily_incident"
      return 0
    fi
    INC_PRIMARY_CODE="NO_FAILURE"
    return 0
  fi
}

# Snapshot artifact uses verbose PRIMARY= labels (maps from canonical code).
incident_primary_snapshot_label() {
  local code="${1:-}" subtype="${2:-}"
  case "${code}" in
    CH0) echo "CH0_IN_UPLINK" ;;
    CH6) echo "CH6_OUT_REALITY_TCP" ;;
    CH5) echo "CH5_SHARED_SOCKS_EGRESS" ;;
    CH4)
      if [[ "${subtype}" == dns_rst_chronic ]]; then
        echo "CH4_DNS_DOT_CHRONIC_RST"
      else
        echo "CH4_DNS_DOT_PATH"
      fi
      ;;
    CH3) echo "CH3_UDP_RELAY_DEGRADED" ;;
    CLIENT_TCP_STALL) echo "CLIENT_TCP_STALL" ;;
    NO_FAILURE) echo "NO_SERVER_PATH_FAILURE_IN_SNAPSHOT" ;;
    "") echo "UNKNOWN" ;;
    *) echo "UNKNOWN" ;;
  esac
}

# Values may contain '='; only split on the first '=' per line.
incident_state_get() {
  local blob="$1" key="$2"
  printf '%s\n' "${blob}" | awk -v k="${key}" '
    index($0, "=") > 0 {
      pos = index($0, "=")
      f = substr($0, 1, pos - 1)
      if (f == k) { print substr($0, pos + 1); exit }
    }'
}

incident_state_kv() {
  printf '%s=%s\n' "$1" "$2"
}

incident_socks_ok_from_ms() {
  local ms="$1"
  if [[ "${ms}" == "fail" || "${ms}" == "n/a" || -z "${ms}" ]]; then
    echo "0"
  elif [[ "${ms}" =~ ^[0-9.]+$ ]]; then
    echo "1"
  else
    echo "0"
  fi
}

incident_event_append() {
  local events_file="$1"
  local line="$2"
  mkdir -p "$(dirname "${events_file}")"
  printf '%s\n' "${line}" >> "${events_file}"
  chmod 600 "${events_file}" 2>/dev/null || true
}

# Emit channel_degraded / recovered; persists prev socks_ok in eval_state_file (key=value lines).
incident_channel_eval_events() {
  local events_file="$1" ts="$2" socks_ok="$3" cold_ms="$4" streak="$5"
  local inject_fail_d="$6" p2p_d="$7" one_way_d="$8" eval_state_file="$9"

  local prev_blob="" prev_socks="" prev_primary="" last_degraded=""
  if [[ -f "${eval_state_file}" ]]; then
    prev_blob="$(cat "${eval_state_file}")"
    prev_socks="$(incident_state_get "${prev_blob}" prev_socks_ok)"
    prev_primary="$(incident_state_get "${prev_blob}" prev_primary)"
    last_degraded="$(incident_state_get "${prev_blob}" last_degraded_primary)"
  fi

  INC_SIG_MODE=tick
  INC_SIG_SOCKS_OK="${socks_ok}"
  INC_SIG_COLD_MS="${cold_ms}"
  INC_SIG_STREAK="${streak}"
  INC_SIG_INJECT_DELTA="${inject_fail_d}"
  INC_SIG_P2P_DELTA="${p2p_d}"
  INC_SIG_ONE_WAY_DELTA="${one_way_d}"
  incident_primary_from_signals
  local primary correlation rec_primary
  primary="${INC_PRIMARY_CODE}"
  correlation="${INC_PRIMARY_CORRELATION}"

  if [[ -n "${primary}" ]]; then
    last_degraded="${primary}"
  fi

  if [[ -n "${primary}" && "${primary}" != "${prev_primary}" ]]; then
    incident_event_append "${events_file}" \
      "{\"ts\":\"${ts}\",\"event\":\"channel_degraded\",\"primary\":\"${primary}\",\"correlation\":\"${correlation}\",\"socks_ok\":${socks_ok},\"coredns_streak\":${streak},\"inject_fail_delta\":${inject_fail_d},\"p2p_6881_delta\":${p2p_d}}"
  elif [[ "${prev_socks}" == "0" && "${socks_ok}" == "1" ]]; then
    rec_primary="${last_degraded:-CH5}"
    incident_event_append "${events_file}" \
      "{\"ts\":\"${ts}\",\"event\":\"channel_recovered\",\"primary\":\"${rec_primary}\",\"socks_ok\":1}"
    last_degraded=""
  fi

  {
    incident_state_kv prev_socks_ok "${socks_ok}"
    incident_state_kv prev_streak "${streak}"
    incident_state_kv prev_primary "${primary}"
    incident_state_kv last_degraded_primary "${last_degraded}"
  } > "${eval_state_file}"
  chmod 600 "${eval_state_file}" 2>/dev/null || true
  incident_primary_clear_outputs
}

# Snapshot-time verdict v2 (INC_VERDICT_* → shared incident_primary_from_signals).
incident_verdict_v2_compute() {
  INC_SIG_MODE=snapshot
  INC_SIG_HOST="${INC_VERDICT_HOST:-unknown}"
  INC_SIG_OUT_ICMP="${INC_VERDICT_OUT_ICMP:-unknown}"
  INC_SIG_OUT_TCP="${INC_VERDICT_OUT_TCP:-unknown}"
  INC_SIG_SOCKS="${INC_VERDICT_SOCKS:-unknown}"
  INC_SIG_DNS_LOCAL="${INC_VERDICT_DNS_LOCAL:-unknown}"
  INC_SIG_UDP_RELAY="${INC_VERDICT_UDP_RELAY:-unknown}"
  INC_SIG_INJECT_N="${INC_VERDICT_INJECT_FAIL_N:-0}"
  INC_SIG_P2P_N="${INC_VERDICT_P2P_N:-0}"
  INC_SIG_IPT2SOCKS_TO="${INC_VERDICT_IPT2SOCKS_CLIENT_TO:-0}"
  INC_SIG_RST_COREDNS="${INC_VERDICT_RST_COREDNS:-0}"
  incident_primary_from_signals

  local primary correlation
  primary="$(incident_primary_snapshot_label "${INC_PRIMARY_CODE}" "${INC_PRIMARY_SUBTYPE}")"
  correlation="${INC_PRIMARY_CORRELATION}"

  echo "PRIMARY=${primary}"
  echo "CORRELATION=${correlation}"
  echo "PRIMARY_CODE=${INC_PRIMARY_CODE:-}"
  incident_primary_clear_outputs
}

incident_csv_tail_section() {
  local csv="$1" lines="${2:-${INCIDENT_METRICS_TAIL_LINES}}"
  if [[ ! -f "${csv}" ]]; then
    echo "(no metrics CSV for today: ${csv})"
    return 0
  fi
  echo "metrics_csv: ${csv}"
  echo "metrics_tail_lines: ${lines}"
  echo "--- header ---"
  head -1 "${csv}"
  echo "--- tail ---"
  tail -n "${lines}" "${csv}"
}
