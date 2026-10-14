#!/usr/bin/env bash
# Forensic bundle for VPN incidents on the IN host (<IN_SERVER>).
# Run while symptoms are visible (before recreate if you still need in-container state).
#
# Usage (from kit root):
#   make incident-snapshot
#   CLIENT_IP=10.8.0.7 ./scripts/incident/collect-snapshot.sh
#
# Artifacts default to ~/log/snapshots (outside git).
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_dir}/../lib/paths.sh"
# shellcheck source=../lib/incident-udp-log-patterns.sh
source "${REPO_ROOT}/scripts/lib/incident-udp-log-patterns.sh"
# shellcheck source=../lib/incident-snapshot-lib.sh
source "${REPO_ROOT}/scripts/lib/incident-snapshot-lib.sh"
unset _script_dir

INCIDENT_OUT_DIR="${INCIDENT_OUT_DIR:-${OUT_DIR:-${HOME}/log/snapshots}}"
CLIENT_IP="${CLIENT_IP:-10.8.0.7}"
LOG_SINCE="${LOG_SINCE:-45m}"
readonly LOG_TAIL_DOCKER_EVENTS=40
readonly LOG_TAIL_COREDNS=50

# OPERATIONS.md tuning hints (printed in load signals).
readonly INCIDENT_WARN_SOCKS_CONN=400
readonly INCIDENT_WARN_IPT2SOCKS_FD=6000

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-${INCIDENT_OUT_DIR}/incident-${TS}.log}"

AWG_CONTAINER="${VPN_AWG_CONTAINER:-vpn-amneziawg}"
XRAY_CONTAINER="${VPN_XRAY_CONTAINER:-vpn-xray}"
COREDNS_CONTAINER="${VPN_COREDNS_CONTAINER:-vpn-coredns}"
TELEPROXY_CONTAINER="${VPN_TELEPROXY_CONTAINER:-vpn-teleproxy}"
NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-100}"

mkdir -p "${INCIDENT_OUT_DIR}"

section() {
  printf '\n══ %s ══\n' "$*"
}

run_dc() {
  if [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" ]]; then
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
  else
    return 1
  fi
}

_service_container() {
  case "$1" in
    amneziawg) printf '%s\n' "${AWG_CONTAINER}" ;;
    xray) printf '%s\n' "${XRAY_CONTAINER}" ;;
    coredns) printf '%s\n' "${COREDNS_CONTAINER}" ;;
    teleproxy) printf '%s\n' "${TELEPROXY_CONTAINER}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

dc_logs() {
  local svc="$1"
  local ctn
  ctn="$(_service_container "$svc")"
  run_dc logs "${svc}" --since "${LOG_SINCE}" 2>&1 || docker logs "${ctn}" --since "${LOG_SINCE}" 2>&1 || true
}

dc_logs_ts() {
  local svc="$1"
  local ctn
  ctn="$(_service_container "$svc")"
  run_dc logs "${svc}" --timestamps --since "${LOG_SINCE}" 2>&1 \
    || docker logs --timestamps --since "${LOG_SINCE}" "${ctn}" 2>&1 || true
}

awg_exec() {
  docker exec "${AWG_CONTAINER}" "$@" 2>&1 || echo "(command failed in ${AWG_CONTAINER}: $*)"
}

coredns_exec() {
  docker exec "${COREDNS_CONTAINER}" "$@" 2>&1 || echo "(command failed in ${COREDNS_CONTAINER}: $*)"
}

awg_logs() {
  dc_logs amneziawg
}

coredns_logs() {
  dc_logs coredns
}

# ── Load compose / OUT address (no secrets printed) ──
COMPOSE_FILE="${COMPOSE_FILE:-${BUILD_DIR}/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-${DATA_DIR}/.env}"
OUT_EXIT_FAMILY=""
OUT_EXIT_ADDRESS=""
OUT_REALITY_PORT="${OUT_REALITY_PORT:-443}"
SOCKS_PORT="1080"
COREDNS_IP="${COREDNS_IP:-10.200.97.2}"
XRAY_IP="${XRAY_IP:-10.200.97.4}"
TELEPROXY_IP="${TELEPROXY_IP:-10.200.97.5}"
PREFLIGHT_EGRESS_URL="${PREFLIGHT_OUT_EGRESS_URL:-https://api.ipify.org}"

# Verdict flags (artifact summary; set during collection).
INC_HOST_UPLINK="unknown"
INC_OUT_ICMP="unknown"
INC_OUT_TCP443="unknown"
INC_SOCKS_EGRESS="unknown"
INC_SOCKS_EGRESS_IP=""
INC_DNS_LOCAL="unknown"
INC_DNS_CLIENT_PATH="skip"
INC_AWG_TUNNEL="unknown"
INC_UDP_RELAY="unknown"
INC_CANON_NFQ_PKTS="0"
INC_DIAG_NFQ_PKTS=""
INC_RST_COREDNS_LOG="0"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=../lib/env-file.sh
  source "${REPO_ROOT}/scripts/lib/env-file.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "${ENV_FILE}" 2>/dev/null || true
  set +a
  if [[ -f "${REPO_ROOT}/scripts/lib/endpoint.sh" ]]; then
    # shellcheck source=../lib/endpoint.sh
    source "${REPO_ROOT}/scripts/lib/endpoint.sh"
    ENDPOINT_RESOLVE_QUIET=1 endpoint_resolve_env 2>/dev/null || true
    OUT_EXIT_FAMILY="${OUT_EXIT_FAMILY:-}"
    OUT_EXIT_ADDRESS="${OUT_EXIT_ADDRESS:-}"
  fi
  SOCKS_PORT="${SOCKS_PORT:-1080}"
  NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-${NFQUEUE_NUM}}"
  COREDNS_IP="${COREDNS_IP:-10.200.97.2}"
  XRAY_IP="${XRAY_IP:-10.200.97.4}"
  TELEPROXY_IP="${TELEPROXY_IP:-10.200.97.5}"
  OUT_REALITY_PORT="${OUT_REALITY_PORT:-443}"
  PREFLIGHT_EGRESS_URL="${PREFLIGHT_OUT_EGRESS_URL:-https://api.ipify.org}"
fi

COLLECTION_START_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

{
  section "meta"
  echo "collection_start_utc: ${COLLECTION_START_UTC}"
  echo "time_local: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "time_utc: $(date -u '+%Y-%m-%d %H:%M:%SZ')"
  echo "hostname: $(hostname 2>/dev/null || echo '?')"
  echo "repo_root: ${REPO_ROOT}"
  echo "client_ip: ${CLIENT_IP}"
  echo "log_since: ${LOG_SINCE}"
  echo "nfqueue_num: ${NFQUEUE_NUM}"
  echo "docker_ips: coredns=${COREDNS_IP} amneziawg=${AMNEZIAWG_IP:-?} xray=${XRAY_IP} teleproxy=${TELEPROXY_IP}"
  echo "output: ${OUT}"
  if [[ -d "${REPO_ROOT}/.git" ]]; then
    echo "kit_git: $(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo '?')"
  fi
  echo "counter_trust: canonical NFQUEUE pkts = section「amneziawg — iptables NFQUEUE」(iptables -x); ignore diagnose L2 if it disagrees"
  echo "log_note: events after time_local may appear in --since tails (collection takes ~1–2 min)"
  echo "tip: run while users report issues; artifacts under ~/log/snapshots — independent of recreate in pub"

  section "meta — container clocks (correlate xray access logs)"
  for c in "${XRAY_CONTAINER}" "${COREDNS_CONTAINER}" "${AWG_CONTAINER}"; do
    if docker inspect "${c}" >/dev/null 2>&1; then
      echo "${c}: $(incident_container_date_utc "${c}")"
    fi
  done
  echo "host_local: $(date '+%Y-%m-%d %H:%M:%S %z')  host_utc: $(date -u '+%Y-%m-%d %H:%M:%SZ')"

  section "host (IN uplink — provider vs local stack)"
  uptime 2>/dev/null || true
  free -h 2>/dev/null | head -3 || true
  echo "swap_used_mb: $(incident_swap_used_mb)"
  echo "--- ping 1.1.1.1 from host (3) ---"
  if ping -c 3 -W 2 1.1.1.1 >/dev/null 2>&1; then
    INC_HOST_UPLINK=ok
    ping -c 3 -W 2 1.1.1.1 2>&1
  else
    INC_HOST_UPLINK=fail
    echo "(host ping failed)"
  fi
  echo "--- curl https://1.1.1.1/cdn-cgi/trace (host, 8s) ---"
  if curl -4 -sS -m 8 https://1.1.1.1/cdn-cgi/trace 2>&1 | head -5; then
    [[ "${INC_HOST_UPLINK}" == "unknown" ]] && INC_HOST_UPLINK=ok
  else
    echo "(host curl failed)"
    INC_HOST_UPLINK=fail
  fi

  section "docker vpn-* status"
  docker ps -a --filter 'name=vpn-' --format 'table {{.Names}}\t{{.Status}}\t{{.State}}' 2>&1 || true
  echo "--- OOMKilled flags ---"
  for c in "${COREDNS_CONTAINER}" "${XRAY_CONTAINER}" "${AWG_CONTAINER}" "${TELEPROXY_CONTAINER}"; do
    if docker inspect "${c}" >/dev/null 2>&1; then
      docker inspect "${c}" --format '{{.Name}} OOMKilled={{.State.OOMKilled}} Restarts={{.RestartCount}}' 2>&1 || true
    fi
  done

  section "docker events (container die/oom/kill/restart/destroy since ${LOG_SINCE}; 8s collect cap)"
  timeout 8 docker events \
    --since "${LOG_SINCE}" \
    --filter 'type=container' \
    --format '{{.Time}} {{.Action}} name={{.Actor.Attributes.name}}' 2>&1 \
    | grep -E 'name=vpn-' \
    | grep -E ' (die|oom|kill|restart|destroy) ' \
    | tail -"${LOG_TAIL_DOCKER_EVENTS}" || echo "(no matching events or timeout)"

  section "health (State.Health — lost after container recreate, not this log file)"
  for c in "${COREDNS_CONTAINER}" "${XRAY_CONTAINER}" "${AWG_CONTAINER}" "${TELEPROXY_CONTAINER}"; do
    if docker inspect "${c}" >/dev/null 2>&1; then
      echo "--- ${c} ---"
      docker inspect "${c}" --format 'Started={{.State.StartedAt}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} FailingStreak={{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}0{{end}}' 2>&1 || true
      docker inspect "${c}" --format '{{range .State.Health.Log}}{{.Start}} exit={{.ExitCode}} {{json .Output}}{{"\n"}}{{end}}' 2>/dev/null | tail -8 || true
    else
      echo "--- ${c}: not found ---"
    fi
  done

  section "egress matrix (IN / OUT ICMP / OUT TCP / SOCKS — discriminate data-plane)"
  echo "egress_url: ${PREFLIGHT_EGRESS_URL}"
  echo "out_expected_egress: ${OUT_EXPECTED_EGRESS_ADDRESS:-not_set}"
  if [[ -n "${OUT_EXIT_ADDRESS}" ]]; then
    echo "OUT_EXIT: family=${OUT_EXIT_FAMILY} addr=${OUT_EXIT_ADDRESS}"
    if docker inspect "${XRAY_CONTAINER}" >/dev/null 2>&1; then
      echo "--- OUT ICMP from ${XRAY_CONTAINER} ---"
      if [[ "${OUT_EXIT_FAMILY}" == "6" ]]; then
        if docker exec "${XRAY_CONTAINER}" sh -c "ping6 -c 3 -W 3 $(printf '%q' "${OUT_EXIT_ADDRESS}")" >/dev/null 2>&1; then
          INC_OUT_ICMP=ok
          docker exec "${XRAY_CONTAINER}" sh -c "ping6 -c 3 -W 3 $(printf '%q' "${OUT_EXIT_ADDRESS}")" 2>&1
        else
          INC_OUT_ICMP=fail
          echo "(ping6 failed)"
        fi
      else
        if docker exec "${XRAY_CONTAINER}" sh -c "ping -c 3 -W 3 $(printf '%q' "${OUT_EXIT_ADDRESS}")" >/dev/null 2>&1; then
          INC_OUT_ICMP=ok
          docker exec "${XRAY_CONTAINER}" sh -c "ping -c 3 -W 3 $(printf '%q' "${OUT_EXIT_ADDRESS}")" 2>&1
        else
          INC_OUT_ICMP=fail
          echo "(ping failed)"
        fi
      fi
      echo "--- OUT TCP :${OUT_REALITY_PORT} from ${XRAY_CONTAINER} (best-effort) ---"
      _tcp="$(incident_xray_tcp_probe "${XRAY_CONTAINER}" "${OUT_EXIT_ADDRESS}" "${OUT_REALITY_PORT}")"
      echo "out_tcp_probe=${_tcp}"
      case "${_tcp}" in
        ok) INC_OUT_TCP443=ok ;;
        skip_no_nc_wget) INC_OUT_TCP443=skip ;;
        *) INC_OUT_TCP443=fail ;;
      esac
    fi
  else
    echo "(OUT_EXIT not resolved — check ${ENV_FILE})"
    INC_OUT_ICMP=skip
    INC_OUT_TCP443=skip
  fi

  echo "--- SOCKS egress (host → 127.0.0.1:${SOCKS_PORT}, same as make check phase 10) ---"
  if [[ -n "${SOCKS_USER:-}" && -n "${SOCKS_PASSWORD:-}" ]]; then
    _socks_out="$(mktemp)"
    _socks_meta="$(mktemp)"
    if curl -4 -sS -m 15 -x "socks5h://127.0.0.1:${SOCKS_PORT}" \
      --proxy-user "${SOCKS_USER}:${SOCKS_PASSWORD}" \
      -w 'curl_time_connect=%{time_connect} curl_time_total=%{time_total}\n' \
      -o "${_socks_out}" "${PREFLIGHT_EGRESS_URL}" 2>"${_socks_meta}"; then
      INC_SOCKS_EGRESS=ok
      INC_SOCKS_EGRESS_IP="$(tr -d '\n\r' < "${_socks_out}")"
      echo "socks_body: ${INC_SOCKS_EGRESS_IP}"
      cat "${_socks_meta}"
      if [[ -n "${OUT_EXPECTED_EGRESS_ADDRESS:-}" && "${INC_SOCKS_EGRESS_IP}" != "${OUT_EXPECTED_EGRESS_ADDRESS}" ]]; then
        echo "socks_egress_mismatch: got=${INC_SOCKS_EGRESS_IP} expected=${OUT_EXPECTED_EGRESS_ADDRESS}"
      fi
    else
      INC_SOCKS_EGRESS=timeout
      echo "(SOCKS curl failed)"
      cat "${_socks_meta}" 2>/dev/null || true
      grep -qi reject "${_socks_meta}" 2>/dev/null && INC_SOCKS_EGRESS=reject
    fi
    rm -f "${_socks_out}" "${_socks_meta}"
  else
    echo "(SOCKS credentials not loaded — skip)"
    INC_SOCKS_EGRESS=skip
  fi

  section "DNS depth (coredns local + client path @ CoreDNS)"
  if docker inspect "${COREDNS_CONTAINER}" >/dev/null 2>&1; then
    echo "--- dig @127.0.0.1 cached cloudflare.com ---"
    if coredns_exec dig @127.0.0.1 +time=5 +tries=1 cloudflare.com A +stats; then
      INC_DNS_LOCAL=ok
    else
      INC_DNS_LOCAL=fail
    fi
    _probe="probe-$(date +%s).invalid.example.com"
    echo "--- dig @127.0.0.1 cold (+norecurse) ${_probe} ---"
    coredns_exec dig @127.0.0.1 +norecurse +time=10 +tries=1 "${_probe}" A +stats || true
    echo "--- dig @127.0.0.1 api.telegram.org ---"
    coredns_exec dig @127.0.0.1 +time=5 +tries=2 api.telegram.org A +short || INC_DNS_LOCAL=fail
    echo "--- client path: dig @${COREDNS_IP} from ${AWG_CONTAINER} (as router DNS DNAT target) ---"
    if docker exec "${AWG_CONTAINER}" sh -c "command -v dig >/dev/null" 2>/dev/null; then
      if docker exec "${AWG_CONTAINER}" dig @"${COREDNS_IP}" +time=5 +tries=1 api.telegram.org A +stats 2>&1; then
        INC_DNS_CLIENT_PATH=ok
      else
        INC_DNS_CLIENT_PATH=fail
      fi
    else
      echo "(dig not in ${AWG_CONTAINER} — skip client path)"
    fi
    echo "--- xray tail: DoT via socks-in (hint) ---"
    dc_logs xray | grep '1.1.1.1:853' | tail -3 || echo "(no :853 accepted lines in window)"
  fi
  echo "--- coredns logs since ${LOG_SINCE} (timestamped; ERR/deadline/reset/peer/EOF) ---"
  INC_RST_COREDNS_LOG="$(dc_logs_ts coredns | grep -ciE 'reset by peer|Connection reset' || true)"
  dc_logs_ts coredns | grep -iE 'ERR|ERROR|deadline|timeout|reset|peer|EOF' | tail -"${LOG_TAIL_COREDNS}" || true
  echo "coredns_rst_or_reset_lines_in_tail: ${INC_RST_COREDNS_LOG}"

  section "load signals (SPOF SOCKS — artifact heuristics)"
  _socks_conn="$(incident_awg_socks_conn_count "${AWG_CONTAINER}" "${XRAY_IP}" "${SOCKS_PORT}")"
  _fd_awg="$(incident_ipt2socks_max_fd "${AWG_CONTAINER}")"
  _fd_cd="$(incident_ipt2socks_max_fd "${COREDNS_CONTAINER}")"
  echo "awg_socks_tcp_conn_to_${XRAY_IP}:${SOCKS_PORT}=${_socks_conn}  warn_above=${INCIDENT_WARN_SOCKS_CONN}"
  echo "ipt2socks_fd_max awg=${_fd_awg} coredns=${_fd_cd}  warn_above=${INCIDENT_WARN_IPT2SOCKS_FD}"
  echo "--- teleproxy burst hint (xray accepted from ${TELEPROXY_IP}, last 15) ---"
  dc_logs xray | grep "from tcp:${TELEPROXY_IP}" | tail -15 || echo "(none)"
  _tg_accept="$(dc_logs xray | grep -c "from tcp:${TELEPROXY_IP}" || true)"
  echo "teleproxy_accept_lines_in_log_since=${_tg_accept}"
  echo "--- P2P heuristic: ${CLIENT_IP} sessions to :6881 (count + samples) ---"
  _p2p_n="$(awg_logs | grep "${CLIENT_IP}" | grep -c ':6881' || true)"
  echo "client_${CLIENT_IP}_6881_log_lines=${_p2p_n}"
  awg_logs | grep "${CLIENT_IP}" | grep ':6881' | tail -5 || echo "(no :6881 samples)"
  echo "--- last associate health ---"
  awg_logs | grep 'associate health' | tail -1 || echo "(none)"
  if awg_logs | grep -qE 'associate reconnected|action=associate_reconnect|path_scenario=SCEN-F'; then
    INC_UDP_RELAY=degraded
  elif awg_logs | grep -q 'associate health'; then
    INC_UDP_RELAY=ok
  else
    INC_UDP_RELAY=unknown
  fi

  section "make check (phases 9–10)"
  if [[ -x "${REPO_ROOT}/scripts/deployment/check.sh" ]]; then
    (cd "${REPO_ROOT}" && CHECK_STRICT="" ./scripts/deployment/check.sh 9 10) 2>&1 || true
  else
    echo "(kit check.sh not found)"
  fi

  section "AWG peers (full)"
  if docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
    awg_exec wg show awg0
  fi

  section "client ${CLIENT_IP} — WireGuard (WAN vs server)"
  if docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
    echo "--- dump row (allowed-ips, latest_handshake epoch, rx/tx bytes) ---"
    awg_exec wg show awg0 dump | grep "${CLIENT_IP}" || echo "(no peer with allowed-ips containing ${CLIENT_IP})"
    echo "--- latest-handshakes (all peers, epoch seconds) ---"
    awg_exec wg show awg0 latest-handshakes
    echo "--- transfer (all peers) ---"
    awg_exec wg show awg0 transfer
    echo "--- peer summary (stale handshake / shared endpoint hints) ---"
    awg_exec wg show awg0 | grep -E 'peer:|endpoint:|latest handshake:' || true
    if awg_exec wg show awg0 dump | grep -q "${CLIENT_IP}"; then
      INC_AWG_TUNNEL=ok
    else
      INC_AWG_TUNNEL=unknown
    fi
  fi

  section "amneziawg — iptables NFQUEUE (lifetime packet counters, iptables -x)"
  if docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
    echo "--- mangle PREROUTING NFQUEUE rule (queue ${NFQUEUE_NUM}; cols: pkts bytes target…) ---"
    awg_exec iptables -t mangle -L PREROUTING -v -n -x \
      | awk -v q="${NFQUEUE_NUM}" '/NFQUEUE/ && $0 ~ q {print; exit}' || echo "(NFQUEUE rule not found)"
    INC_CANON_NFQ_PKTS="$(incident_iptables_pkts_field "$(incident_awg_nfqueue_pkts "${AWG_CONTAINER}" "${NFQUEUE_NUM}")")"
    echo "canonical_nfqueue_pkts: ${INC_CANON_NFQ_PKTS}"
    echo "--- FORWARD udp DROP !53 (anti-leak; lifetime pkts) ---"
    awg_exec iptables -L FORWARD -v -n -x \
      | awk '/DROP/ && /udp/ && /dpt:!53/ {print; exit}' || echo "(rule not found)"
  fi

  section "amneziawg — ipt2socks / TCP exit (since ${LOG_SINCE})"
  echo "note: recv from client stream = client side of proxied TCP, not necessarily SOCKS/OUT failure"
  echo "--- grep: ${IPT2SOCKS_GREP} ---"
  awg_logs | grep -iE "${IPT2SOCKS_GREP}" | tail -"${LOG_TAIL_IPT2SOCKS}" || echo "(no matches)"

  section "coredns — ipt2socks / DoT upstream (since ${LOG_SINCE})"
  echo "--- grep: ${IPT2SOCKS_GREP} ---"
  coredns_logs | grep -iE "${IPT2SOCKS_GREP}" | tail -"${LOG_TAIL_IPT2SOCKS}" || echo "(no matches)"
  echo "--- reset/peer on socks5 stream (only if present in this tail) ---"
  coredns_logs | grep -iE 'socks5 stream|reset by peer' | tail -20 || echo "(no matches in tail)"

  section "amneziawg — udp-relay (since ${LOG_SINCE})"
  echo "--- udp-relay signals (grep: ${UDP_RELAY_GREP}; last ${LOG_TAIL_UDP}) ---"
  awg_logs | grep -E "${UDP_RELAY_GREP}" | tail -"${LOG_TAIL_UDP}" || echo "(no matches)"
  echo "--- client ${CLIENT_IP} highlights (session / one-way / evict; no DEBUG relayed outbound) ---"
  awg_logs | grep "${CLIENT_IP}" \
    | grep -E 'session |one-way|action=|inject reply failed' \
    | grep -v 'relayed outbound udp' \
    | tail -30 || echo "(no matches)"
  echo "--- associate health / closed (gen inject port; last ${LOG_TAIL_ASSOC}) ---"
  awg_logs | grep -E "${ASSOC_SNAPSHOT_GREP}" | tail -"${LOG_TAIL_ASSOC}" || echo "(no matches)"

  section "diagnose-udp-path (static L0–L4, noninteractive)"
  if [[ -x "${REPO_ROOT}/scripts/smoke/diagnose-udp-path.sh" ]]; then
    # shellcheck source=../lib/voice-smoke-metrics.sh
    source "${REPO_ROOT}/scripts/lib/voice-smoke-metrics.sh"
    INC_DIAG_NFQ_PKTS="$(voice_smoke_to_int "$(voice_smoke_counter_nfqueue)")"
    NONINTERACTIVE=1 SMOKE_CLIENT_IP="${CLIENT_IP}" AWG_CONTAINER="${AWG_CONTAINER}" NFQUEUE_NUM="${NFQUEUE_NUM}" \
      "${REPO_ROOT}/scripts/smoke/diagnose-udp-path.sh" 2>&1 || true
    if [[ "${INC_DIAG_NFQ_PKTS}" -lt 1 && "${INC_CANON_NFQ_PKTS}" -gt 0 ]]; then
      echo "WARN: diagnose L2 nfqueue pkts (${INC_DIAG_NFQ_PKTS}) disagrees with canonical (${INC_CANON_NFQ_PKTS}) — trust canonical section"
    fi
  else
    echo "(diagnose-udp-path.sh not found)"
  fi

  section "xray tail (errors + accepted count hint)"
  echo "--- grep error/reject since ${LOG_SINCE} ---"
  dc_logs xray | grep -iE 'rejected|error|fail|timeout' | tail -20 || echo "(none)"
  echo "--- last accepted lines ---"
  dc_logs xray | grep accepted | tail -15 || true

  section "verdict (artifact summary — rules over this file only)"
  echo "collection_end_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  _trigger=unknown
  if [[ "${INC_SOCKS_EGRESS}" == timeout && "${INC_OUT_ICMP}" == ok ]]; then
    if [[ "${_socks_conn}" != n/a && "${_socks_conn}" -gt "${INCIDENT_WARN_SOCKS_CONN}" ]]; then
      _trigger=load_suspected
    elif [[ "$(incident_swap_used_mb)" != n/a && "$(incident_swap_used_mb)" -gt 512 ]]; then
      _trigger=memory_suspected
    else
      _trigger=egress_data_plane_suspected
    fi
  fi
  if [[ "${INC_OUT_TCP443}" == fail && "${INC_OUT_ICMP}" == ok ]]; then
    _trigger=out_tcp_suspected
  fi
  if [[ "${INC_RST_COREDNS_LOG}" -gt 0 ]]; then
    echo "h4_xray_socks_rst: evidence_in_coredns_tail=yes (see coredns logs section)"
  else
    echo "h4_xray_socks_rst: evidence_in_coredns_tail=no — do not claim RST without log lines"
  fi
  echo "IN_UPLINK=${INC_HOST_UPLINK}"
  echo "OUT_ICMP=${INC_OUT_ICMP}"
  echo "OUT_TCP${OUT_REALITY_PORT}=${INC_OUT_TCP443}"
  echo "SOCKS_EGRESS=${INC_SOCKS_EGRESS}"
  echo "SOCKS_EGRESS_IP=${INC_SOCKS_EGRESS_IP:-}"
  echo "OUT_EXPECTED_EGRESS=${OUT_EXPECTED_EGRESS_ADDRESS:-not_set}"
  echo "DNS_LOCAL=${INC_DNS_LOCAL}"
  echo "DNS_CLIENT_PATH=${INC_DNS_CLIENT_PATH}"
  echo "AWG_TUNNEL=${INC_AWG_TUNNEL}"
  echo "UDP_RELAY=${INC_UDP_RELAY}"
  echo "LOAD_SOCKS_CONN=${_socks_conn}"
  echo "LOAD_FD_AWG_MAX=${_fd_awg}"
  echo "LOAD_FD_COREDNS_MAX=${_fd_cd}"
  echo "LOAD_SWAP_USED_MB=$(incident_swap_used_mb)"
  echo "CANON_NFQUEUE_PKTS=${INC_CANON_NFQ_PKTS}"
  echo "TRIGGER=${_trigger}"
  echo "TRIGGER_note: time-series before peak needs ~/log/metrics CSV (make incident-metrics-tick)"

  section "verdict hints (read-only)"
  echo "Compare host ping/curl vs xray→OUT vs SOCKS curl:"
  echo "  host bad + all bad     → IN provider / host uplink"
  echo "  host ok, OUT/SOCKS bad → OUT or IN→OUT path or stack data-plane"
  echo "  OUT_ICMP ok + OUT_TCP fail → REALITY/TCP layer, not raw reachability"
  echo "  SOCKS ok, TG bad       → UDP associate (amneziawg logs) or DNS flaps"
  echo "  ipt2socks client stream timeout → client-side TCP stall (see note in awg ipt2socks section)"
  echo "  coredns RST only if coredns_rst_or_reset_lines_in_tail > 0"
  echo "  action=session_evict   → one bad UDP flow; not always full associate swap"
  echo "  action=associate_reconnect → global UDP session reset (closeAll)"
  echo "  WG handshake stale     → client offline / WAN change (not udp-relay alone)"
  echo "Optional: make voice-fail-snapshot for tcpdump; copy ${OUT} off-box for archives"

} | tee "${OUT}"

chmod 600 "${OUT}" 2>/dev/null || true
printf '\nSaved: %s\n' "${OUT}"
printf 'Artifacts live under ~/log/snapshots; make recreate/refresh-full in pub does not remove them.\n'
printf 'Recreate only clears in-container state — run this while the fault is still happening if you need that detail.\n'
