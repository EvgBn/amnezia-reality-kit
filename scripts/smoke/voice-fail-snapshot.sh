#!/usr/bin/env bash
# voice-fail-snapshot.sh — forensic capture at voice degradation (BEFORE down/refresh-full).
#
# Run when Telegram voice fails / voice-gate FAIL, VPN may still work:
#   make voice-fail-snapshot
#   make voice-fail-snapshot OUT=/tmp/fail.log
#
# Best: run while reproducing (join group voice) so tcpdump/active metrics see traffic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/paths.sh" 2>/dev/null || true

AWG_CONTAINER="${VPN_AWG_CONTAINER:-${VPN_AWG_POD:-vpn-amneziawg}}"
XRAY_CONTAINER="${VPN_XRAY_CONTAINER:-${VPN_XRAY_POD:-vpn-xray}}"
# Legacy: VPN_AWG_POD, VPN_XRAY_POD
XRAY_IP="${XRAY_IP:-10.200.97.4}"
AWG_IP="${AMNEZIAWG_IP:-10.200.97.3}"
OUT="${OUT:-/tmp/voice-fail-snapshot.$(date +%Y%m%d-%H%M%S).log}"
TCPDUMP_SEC="${TCPDUMP_SEC:-8}"

section() {
  printf '\n══ %s ══\n' "$*"
}

awg_exec() {
  docker exec "${AWG_CONTAINER}" "$@" 2>/dev/null || echo "(command failed: $* in ${AWG_CONTAINER})"
}

xray_exec() {
  docker exec "${XRAY_CONTAINER}" "$@" 2>/dev/null || echo "(command failed: $* in ${XRAY_CONTAINER})"
}

if ! docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
  log_error "container ${AWG_CONTAINER} not running"
  exit 1
fi

{
  section "meta"
  echo "time_local: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "repo: ${ROOT}"
  echo "container: ${AWG_CONTAINER}  awg_ip: ${AWG_IP}"
  echo "xray: ${XRAY_CONTAINER}  xray_ip: ${XRAY_IP}"
  echo "tip: reproduce voice during snapshot for tcpdump/active deltas"

  section "associate (udp-relay logs)"
  associate_line="$(docker logs "${AWG_CONTAINER}" 2>&1 | grep 'shared socks udp associate ready' | tail -1 || true)"
  echo "${associate_line:-no associate ready line}"
  PORT="$(sed -n 's/.*local_port=\([0-9][0-9]*\).*/\1/p' <<<"${associate_line}")"
  echo "associate_port: ${PORT:-?}"
  awg_started="$(docker inspect "${AWG_CONTAINER}" --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')"
  xray_started="$(docker inspect "${XRAY_CONTAINER}" --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')"
  echo "awg_started: ${awg_started}"
  echo "xray_started: ${xray_started}"
  mapfile -t all_ports < <(docker logs "${AWG_CONTAINER}" 2>&1 | sed -n 's/.*local_port=\([0-9][0-9]*\).*/\1/p' | sort -u)
  echo "associate_ports_lifetime: ${#all_ports[@]} (${all_ports[*]:-none})"

  section "timeline (lifetime — when did path last work?)"
  echo "--- associate ready (all) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'shared socks udp associate ready' || echo "(none)"
  echo "--- last session first outbound (10) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'session first outbound' | tail -10 || echo "(none)"
  echo "--- last session first inject (10) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'session first inject' | tail -10 || echo "(none)"
  echo "--- last one-way warn (5) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'session one-way' | tail -5 || echo "(none)"
  echo "--- last associate closed (5) — per-gen stats at reconnect ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'associate closed' | tail -5 || echo "(none)"
  echo "--- last path_scenario one-way (3) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'path_scenario=SCEN-' | tail -10 || echo "(none)"
  echo "--- reconnect skipped / deferred (10) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep -E 'reconnect skipped|one-way reconnect deferred|one-way reconnect retry|one-way reconnect triggered' | tail -10 || echo "(none)"
  echo "--- socks first udp rx on current port ---"
  if [[ -n "${PORT:-}" ]]; then
    docker logs "${AWG_CONTAINER}" 2>&1 | grep 'socks first udp rx' | grep "port=${PORT}" | tail -3 || echo "(none — xray never returned UDP on this associate)"
  fi
  echo "--- associate health (last 3) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'associate health' | tail -3 || echo "(none)"
  echo "--- read loop exited (all) ---"
  docker logs "${AWG_CONTAINER}" 2>&1 | grep 'shared socks read loop exited' || echo "(none)"
  if [[ -n "${PORT:-}" ]]; then
    echo "--- events on current PORT=${PORT} ---"
    docker logs "${AWG_CONTAINER}" 2>&1 | grep "socks_local_port=${PORT}" \
      | grep -E 'first outbound|first inject|one-way|session opened' | tail -15 || echo "(none on this port)"
  fi

  section "TCP control (udp-relay → xray:1080)"
  tcp_present=0
  if awg_exec ss -tnp | grep -q udp-relay; then
    tcp_present=1
    echo "tcp_state: PRESENT"
    awg_exec ss -tnpi "dst ${XRAY_IP}:1080" | grep -A2 udp-relay || true
  else
    echo "tcp_state: MISSING  ← zombie associate (UDP socket may still be open)"
    awg_exec ss -tnp | grep udp-relay || echo "(no tcp sockets for udp-relay)"
  fi

  section "UDP associate socket"
  if [[ -n "${PORT:-}" ]]; then
    awg_exec ss -ulnp | grep ":${PORT}" || echo "no UDP socket on port ${PORT}"
  else
    awg_exec ss -ulnp | grep udp-relay || echo "no udp-relay udp sockets"
  fi

  section "udp-relay process / open fds"
  relay_pid="$(awg_exec pgrep -x udp-relay || true)"
  echo "udp-relay pid: ${relay_pid:-?}"
  if [[ -n "${relay_pid}" && "${relay_pid}" =~ ^[0-9]+$ ]]; then
    echo "--- /proc/${relay_pid}/fd ---"
    awg_exec ls -la "/proc/${relay_pid}/fd" || true
    echo "--- socket inodes (fd → socket) ---"
    for fd in $(awg_exec ls "/proc/${relay_pid}/fd" 2>/dev/null || true); do
      target="$(awg_exec readlink "/proc/${relay_pid}/fd/${fd}" 2>/dev/null || true)"
      if [[ "${target}" == socket:* ]]; then
        echo "  fd ${fd}: ${target}"
      fi
    done
  fi

  section "/proc/net/tcp in container (SOCKS 1080 = 0438 hex)"
  # 1080 decimal = 0x0438 → appears as 3804 in /proc/net/tcp (host-endian)
  awg_exec awk 'NR==1 || /:0438 |:3804 /' /proc/net/tcp || true
  if [[ -n "${PORT:-}" ]]; then
    port_hex="$(printf '%04X' "${PORT}")"
    port_hex_le="$(echo "${port_hex}" | sed 's/\(..\)\(..\)/\2\1/')"
    echo "associate PORT ${PORT} hex BE=${port_hex} LE=${port_hex_le} (search /proc/net/udp)"
    awg_exec awk -v p=":${port_hex_le}" 'NR==1 || index($2,p)' /proc/net/udp || true
  fi

  section "conntrack (container, if available)"
  if awg_exec which conntrack >/dev/null; then
    awg_exec conntrack -L 2>/dev/null | grep -E "${XRAY_IP}|${AWG_IP}" | head -30 || echo "(no matching entries)"
  else
    echo "conntrack CLI not installed in container (optional: apt install conntrack)"
    if awg_exec test -r /proc/net/nf_conntrack 2>/dev/null; then
      awg_exec grep -E "${XRAY_IP}|dport=1080" /proc/net/nf_conntrack 2>/dev/null | tail -10 || echo "(no nf_conntrack matches)"
    fi
  fi

  section "kernel TCP keepalive sysctl (container netns)"
  for key in tcp_keepalive_time tcp_keepalive_intvl tcp_keepalive_probes; do
    if awg_exec test -r "/proc/sys/net/ipv4/${key}"; then
      printf '%s: ' "${key}"
      awg_exec cat "/proc/sys/net/ipv4/${key}"
    fi
  done
  echo "note: SetKeepAlivePeriod(30s) ≠ first probe time; see tcp_keepalive_time"

  section "xray view (inbound :1080 from awg container)"
  xray_exec ss -tnp | grep ':1080' | grep "${AWG_IP}" || echo "(no ESTAB from ${AWG_IP} on xray :1080)"
  xray_exec ss -unp | grep ':1080' || echo "(no UDP listeners/sockets on :1080 summary)"

  section "xray SOCKS UDP (port ${PORT:-?})"
  if [[ -n "${PORT:-}" ]]; then
    echo "accepted_udp lifetime: $(docker logs "${XRAY_CONTAINER}" 2>&1 | grep -c ":${PORT} accepted udp" || true)"
    echo "accepted_udp last 2h: $(docker logs "${XRAY_CONTAINER}" --since 2h 2>&1 | grep -c ":${PORT} accepted udp" || true)"
    docker logs "${XRAY_CONTAINER}" --since 2h 2>&1 | grep ":${PORT} accepted udp" | tail -8 || true
  fi
  echo "--- xray access (last 2h, socks/1080/udp) ---"
  docker logs "${XRAY_CONTAINER}" --since 2h 2>&1 | grep -iE 'socks|1080|udp.*accepted|connection ends' | tail -20 || echo "(none)"

  section "active capture (${TCPDUMP_SEC}s tcpdump — join voice NOW if possible)"
  if awg_exec which tcpdump >/dev/null; then
    filter="tcp port 1080 and host ${XRAY_IP}"
    if [[ -n "${PORT:-}" ]]; then
      filter="(tcp port 1080 or udp port ${PORT}) and host ${XRAY_IP}"
    fi
    echo "filter: ${filter}"
    awg_exec timeout "${TCPDUMP_SEC}" tcpdump -ni eth0 -vv -c 30 "${filter}" 2>&1 || echo "(tcpdump done or no packets)"
  else
    echo "tcpdump not in container — skip or: docker exec ${AWG_CONTAINER} apk add tcpdump"
  fi

  section "verdict (voice-path-probe)"
  PROBE_WINDOW="${PROBE_WINDOW:-600}" "${ROOT}/scripts/smoke/voice-path-probe.sh" 2>&1 || true

  section "localization matrix"
  echo "Layer map:"
  echo "  L1 udp-relay process: $(awg_exec pgrep -x udp-relay >/dev/null && echo UP || echo DOWN)"
  echo "  L2 TCP SOCKS control:   $([[ ${tcp_present} -eq 1 ]] && echo UP || echo DOWN/MISSING)"
  echo "  L3 UDP associate sock:  $([[ -n "${PORT:-}" ]] && awg_exec ss -ulnp | grep -q ":${PORT}" && echo UP || echo DOWN)"
  echo "  L4 xray accepts PORT:   $(docker logs "${XRAY_CONTAINER}" --since 10m 2>&1 | grep -c ":${PORT:-0} accepted udp" || echo 0) (last 10m)"
  echo "  L5 inject return:     see probe inject_* / one-way above"
  echo ""
  if [[ "${tcp_present}" -eq 0 ]]; then
    echo "PRIMARY: TCP control gone, UDP zombie → xray closed associate OR path died; udp-relay no reconnect"
    echo "PROVE WHO CLOSED: tcpdump FIN/RST direction on next fail with voice active"
  else
    last_scenario="$(docker logs "${AWG_CONTAINER}" 2>&1 | grep 'path_scenario=SCEN-' | tail -1 | sed -n 's/.*path_scenario=\([^ ]*\).*/\1/p' || true)"
    last_rx="$(docker logs "${AWG_CONTAINER}" 2>&1 | grep 'associate closed' | tail -1 | sed -n 's/.*socks_udp_rx=\([0-9][0-9]*\).*/\1/p' || true)"
    echo "PRIMARY: TCP alive but return dead"
    echo "  path_scenario (last): ${last_scenario:-unknown}"
    echo "  socks_udp_rx at last associate close: ${last_rx:-?}"
    echo "  SCEN-B-XRAY-NO-RETURN → xray not sending SOCKS UDP replies (connIdle / xray bug)"
    echo "  SCEN-C-SESSION-MISMATCH → reply arrived but no session match"
    echo "  SCEN-F-RECONNECT-SKIPPED → one-way fired but reconnect blocked (cooldown/session age)"
  fi
  echo "SECONDARY CHECK: compare last 'first outbound' time vs fail time (~connIdle 1200s?)"

} | tee "${OUT}"

echo ""
log_info "snapshot saved: ${OUT}"
echo "Do NOT run refresh-full until you copied this file."
