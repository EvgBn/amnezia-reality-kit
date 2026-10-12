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
unset _script_dir

INCIDENT_OUT_DIR="${INCIDENT_OUT_DIR:-${OUT_DIR:-${HOME}/log/snapshots}}"
CLIENT_IP="${CLIENT_IP:-10.8.0.7}"
LOG_SINCE="${LOG_SINCE:-45m}"
readonly LOG_TAIL_DOCKER_EVENTS=40

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

awg_exec() {
  docker exec "${AWG_CONTAINER}" "$@" 2>&1 || echo "(command failed in ${AWG_CONTAINER}: $*)"
}

awg_logs() {
  dc_logs amneziawg
}

# ── Load compose / OUT address (no secrets printed) ──
COMPOSE_FILE="${COMPOSE_FILE:-${BUILD_DIR}/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-${DATA_DIR}/.env}"
OUT_EXIT_FAMILY=""
OUT_EXIT_ADDRESS=""
SOCKS_PORT="1080"

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
fi

{
  section "meta"
  echo "time_local: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "hostname: $(hostname 2>/dev/null || echo '?')"
  echo "repo_root: ${REPO_ROOT}"
  echo "client_ip: ${CLIENT_IP}"
  echo "log_since: ${LOG_SINCE}"
  echo "nfqueue_num: ${NFQUEUE_NUM}"
  echo "output: ${OUT}"
  if [[ -d "${REPO_ROOT}/.git" ]]; then
    echo "kit_git: $(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo '?')"
  fi
  echo "tip: run while users report issues; artifacts under ~/log/snapshots — independent of recreate in pub"

  section "host (IN uplink — provider vs local stack)"
  uptime 2>/dev/null || true
  free -h 2>/dev/null | head -3 || true
  echo "--- ping 1.1.1.1 from host (3) ---"
  ping -c 3 -W 2 1.1.1.1 2>&1 || echo "(host ping failed)"
  echo "--- curl https://1.1.1.1/cdn-cgi/trace (host, 8s) ---"
  curl -4 -sS -m 8 https://1.1.1.1/cdn-cgi/trace 2>&1 | head -5 || echo "(host curl failed)"

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

  section "make check (phases 9–10)"
  if [[ -x "${REPO_ROOT}/scripts/deployment/check.sh" ]]; then
    (cd "${REPO_ROOT}" && CHECK_STRICT="" ./scripts/deployment/check.sh 9 10) 2>&1 || true
  else
    echo "(kit check.sh not found)"
  fi

  section "OUT reachability (xray container → OUT_EXIT)"
  if [[ -n "${OUT_EXIT_ADDRESS}" ]]; then
    echo "OUT_EXIT: family=${OUT_EXIT_FAMILY} addr=${OUT_EXIT_ADDRESS}"
    if docker inspect "${XRAY_CONTAINER}" >/dev/null 2>&1; then
      if [[ "${OUT_EXIT_FAMILY}" == "6" ]]; then
        docker exec "${XRAY_CONTAINER}" sh -c "ping6 -c 5 -W 3 $(printf '%q' "${OUT_EXIT_ADDRESS}")" 2>&1 || echo "(ping6 failed)"
      else
        docker exec "${XRAY_CONTAINER}" sh -c "ping -c 5 -W 3 $(printf '%q' "${OUT_EXIT_ADDRESS}")" 2>&1 || echo "(ping failed)"
      fi
    fi
  else
    echo "(OUT_EXIT not resolved — check ${ENV_FILE})"
  fi

  section "SOCKS egress (same path as make check phase 10)"
  if [[ -n "${SOCKS_USER:-}" && -n "${SOCKS_PASSWORD:-}" ]]; then
    curl -4 -sS -m 15 -x "socks5h://127.0.0.1:${SOCKS_PORT}" \
      --proxy-user "${SOCKS_USER}:${SOCKS_PASSWORD}" \
      "${PREFLIGHT_OUT_EGRESS_URL:-https://api.ipify.org}" 2>&1 && echo || echo "(SOCKS curl failed)"
  else
    echo "(SOCKS credentials not loaded — skip)"
  fi

  section "DNS (coredns container)"
  if docker inspect "${COREDNS_CONTAINER}" >/dev/null 2>&1; then
    docker exec "${COREDNS_CONTAINER}" dig @127.0.0.1 +time=3 +tries=2 cloudflare.com A +short 2>&1 || true
    docker exec "${COREDNS_CONTAINER}" dig @127.0.0.1 +time=3 +tries=2 api.telegram.org A +short 2>&1 || true
  fi
  echo "--- coredns errors since ${LOG_SINCE} ---"
  dc_logs coredns | grep -iE 'ERR|ERROR|deadline|timeout|reset' | tail -40 || true

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
  fi

  section "amneziawg — iptables NFQUEUE (lifetime packet counters)"
  if docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
    echo "--- mangle PREROUTING NFQUEUE rule (queue ${NFQUEUE_NUM}; cols: pkts bytes target…) ---"
    awg_exec iptables -t mangle -L PREROUTING -v -n \
      | awk -v q="${NFQUEUE_NUM}" '/NFQUEUE/ && $0 ~ q {print; exit}' || echo "(NFQUEUE rule not found)"
    echo "--- FORWARD udp DROP !53 (anti-leak; lifetime pkts) ---"
    awg_exec iptables -L FORWARD -v -n \
      | awk '/DROP/ && /udp/ && /dpt:!53/ {print; exit}' || echo "(rule not found)"
  fi

  section "amneziawg — ipt2socks / TCP exit (since ${LOG_SINCE})"
  echo "--- grep: ${IPT2SOCKS_GREP} ---"
  awg_logs | grep -iE "${IPT2SOCKS_GREP}" | tail -"${LOG_TAIL_IPT2SOCKS}" || echo "(no matches)"

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
    NONINTERACTIVE=1 SMOKE_CLIENT_IP="${CLIENT_IP}" \
      "${REPO_ROOT}/scripts/smoke/diagnose-udp-path.sh" 2>&1 || true
  else
    echo "(diagnose-udp-path.sh not found)"
  fi

  section "xray tail (errors + accepted count hint)"
  echo "--- grep error/reject since ${LOG_SINCE} ---"
  dc_logs xray | grep -iE 'rejected|error|fail|timeout' | tail -20 || echo "(none)"
  echo "--- last accepted lines ---"
  dc_logs xray | grep accepted | tail -15 || true

  section "verdict hints (read-only)"
  echo "Compare host ping/curl vs xray→OUT vs SOCKS curl:"
  echo "  host bad + all bad     → IN provider / host uplink"
  echo "  host ok, OUT/SOCKS bad → OUT or IN→OUT path or stack data-plane"
  echo "  SOCKS ok, TG bad       → UDP associate (amneziawg logs) or DNS flaps"
  echo "  ipt2socks timeouts     → TCP exit/DNS upstream (coredns DoT path)"
  echo "  action=session_evict   → one bad UDP flow; not always full associate swap"
  echo "  action=associate_reconnect → global UDP session reset (closeAll)"
  echo "  WG handshake stale     → client offline / WAN change (not udp-relay alone)"
  echo "Optional: make voice-fail-snapshot for tcpdump; copy ${OUT} off-box for archives"

} | tee "${OUT}"

chmod 600 "${OUT}" 2>/dev/null || true
printf '\nSaved: %s\n' "${OUT}"
printf 'Artifacts live under ~/log/snapshots; make recreate/refresh-full in pub does not remove them.\n'
printf 'Recreate only clears in-container state — run this while the fault is still happening if you need that detail.\n'
