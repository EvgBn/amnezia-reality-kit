#!/usr/bin/env bash
# voice-path-probe.sh — classify voice return-path failure (read-only, no call needed).
#
# Run when voice-gate FAILs or Telegram hangs on Connecting…
#   make voice-path-probe
#
# Modes (theory under test):
#   OK       — inject seen on current associate port
#   MODE-A   — stale associate idle (xray udp window low/zero, inject=0)
#   MODE-B   — half-path: xray accepts outbound, inject never on this port
#   MODE-B+  — zombie after partial restart (multiple associate ports in container lifetime)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/paths.sh" 2>/dev/null || true

AWG_CONTAINER="${VPN_AWG_CONTAINER:-${VPN_AWG_POD:-vpn-amneziawg}}"
XRAY_CONTAINER="${VPN_XRAY_CONTAINER:-${VPN_XRAY_POD:-vpn-xray}}"
# Legacy: VPN_AWG_POD, VPN_XRAY_POD
WINDOW="${PROBE_WINDOW:-300}"

if ! command -v docker >/dev/null 2>&1; then
  log_error "docker not found"
  exit 1
fi

if ! docker inspect "${AWG_CONTAINER}" >/dev/null 2>&1; then
  log_error "container ${AWG_CONTAINER} not running — make start"
  exit 1
fi

awg_log="$(docker logs "${AWG_CONTAINER}" 2>&1 || true)"
xray_log="$(docker logs "${XRAY_CONTAINER}" 2>&1 || true)"

associate_line="$(printf '%s\n' "${awg_log}" | grep 'shared socks udp associate ready' | tail -1 || true)"
associate_port="$(sed -n 's/.*local_port=\([0-9][0-9]*\).*/\1/p' <<<"${associate_line}")"
associate_ts="$(sed -n 's/time=\([^ ]*\).*/\1/p' <<<"${associate_line}")"

if [[ -z "${associate_port}" ]]; then
  log_error "no 'shared socks udp associate ready' in ${AWG_CONTAINER} logs"
  exit 1
fi

inject_on_port="$(printf '%s\n' "${awg_log}" | grep "socks_local_port=${associate_port}" | grep -c 'session first inject' || true)"
inject_recent="$(docker logs "${AWG_CONTAINER}" --since "${WINDOW}s" 2>&1 | grep -c 'session first inject' || true)"
one_way_recent="$(docker logs "${AWG_CONTAINER}" --since "${WINDOW}s" 2>&1 | grep -c 'session one-way' || true)"
read_loop_exits="$(printf '%s\n' "${awg_log}" | grep -c 'shared socks read loop exited' || true)"
reconnect_skipped_recent="$(docker logs "${AWG_CONTAINER}" --since "${WINDOW}s" 2>&1 | grep -c 'reconnect skipped' || true)"
last_closed_line="$(printf '%s\n' "${awg_log}" | grep 'associate closed' | tail -1 || true)"
last_scenario="$(sed -n 's/.*path_scenario=\([^ ]*\).*/\1/p' <<<"${last_closed_line}")"
last_socks_rx="$(sed -n 's/.*socks_udp_rx=\([0-9][0-9]*\).*/\1/p' <<<"${last_closed_line}")"
socks_first_rx_port="$(printf '%s\n' "${awg_log}" | grep 'socks first udp rx' | grep "port=${associate_port}" | tail -1 || true)"
xray_udp_port="$(printf '%s\n' "${xray_log}" | grep -c ":${associate_port} accepted udp" || true)"
xray_udp_recent="$(docker logs "${XRAY_CONTAINER}" --since "${WINDOW}s" 2>&1 | grep -ciE 'accepted udp|from udp:' || true)"

# All associate ports seen this container lifetime (detect partial-restart zombies)
mapfile -t all_ports < <(printf '%s\n' "${awg_log}" | sed -n 's/.*local_port=\([0-9][0-9]*\).*/\1/p' | sort -u)
multi_associate=0
[[ "${#all_ports[@]}" -gt 1 ]] && multi_associate=1

awg_started="$(docker inspect "${AWG_CONTAINER}" --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')"
xray_started="$(docker inspect "${XRAY_CONTAINER}" --format '{{.State.StartedAt}}' 2>/dev/null || echo '?')"

echo "=== voice-path-probe (theory check) ==="
echo "container:       ${AWG_CONTAINER}  started=${awg_started}"
echo "xray:      ${XRAY_CONTAINER}  started=${xray_started}"
echo "window:    last ${WINDOW}s"
echo ""
echo "── Current SOCKS UDP associate ──"
echo "  port:        ${associate_port}"
echo "  ready_at:    ${associate_ts:-?}"
echo "  inject_ever: ${inject_on_port}  (on this port)"
echo "  inject_${WINDOW}s: ${inject_recent}"
echo "  one-way_${WINDOW}s: ${one_way_recent}"
echo "  reconnect_skipped_${WINDOW}s: ${reconnect_skipped_recent}"
echo "  read_loop_exited (lifetime): ${read_loop_exits}"
echo "  last_associate_closed_scenario: ${last_scenario:-?}"
echo "  last_associate_socks_udp_rx: ${last_socks_rx:-?}"
echo "  socks_first_rx (current port): $([[ -n "${socks_first_rx_port}" ]] && echo yes || echo no)"
echo ""
echo "── xray SOCKS inbound (outbound leg) ──"
echo "  accepted_udp lifetime (port ${associate_port}): ${xray_udp_port}"
echo "  accepted_udp last ${WINDOW}s (all ports): ${xray_udp_recent}"
echo ""
echo "── Partial-restart detector ──"
echo "  associate_ports_this_container: ${#all_ports[@]}  (${all_ports[*]})"
echo ""

# Host ops (orphan bridge / route — teardown theory)
if command -v ip >/dev/null 2>&1; then
  route_line="$(ip route show 10.8.0.0/24 2>/dev/null | head -1 || true)"
  orphan_bridges="$(ip -br link show type bridge 2>/dev/null | awk '/^br-/ {print $1, $2}' | grep -c DOWN || true)"
  echo "── Host ops ──"
  echo "  route 10.8.0.0/24: ${route_line:-none}"
  echo "  dead bridges (DOWN): ${orphan_bridges}"
  echo ""
fi

verdict="UNKNOWN"
hint="collect: make voice-gate artifacts + docker logs"

# Current path health (not lifetime — inject_ever alone caused false OK after decay)
path_broken_now=0
if [[ "${one_way_recent}" -gt 0 ]]; then
  path_broken_now=1
elif [[ "${inject_recent}" -eq 0 && "${xray_udp_recent}" -eq 0 && "${inject_on_port}" -gt 0 ]]; then
  # Was OK earlier on this port; no recent inject/xray udp → associate likely stale (Mode A)
  path_broken_now=1
fi

if [[ "${path_broken_now}" -eq 0 && "${inject_recent}" -gt 0 ]]; then
  verdict="OK"
  hint="return path active in last ${WINDOW}s"
elif [[ "${path_broken_now}" -eq 0 && "${inject_on_port}" -gt 0 && "${one_way_recent}" -eq 0 ]]; then
  verdict="OK-IDLE"
  hint="return worked earlier on port ${associate_port}; no voice in last ${WINDOW}s — run voice-gate to test now"
elif [[ "${xray_udp_recent}" -eq 0 && "${one_way_recent}" -gt 0 ]]; then
  verdict="MODE-A"
  if [[ "${inject_on_port}" -gt 0 ]]; then
    hint="associate decayed (had inject on port ${associate_port}, now one-way, xray udp=0 in window)"
  else
    hint="stale/idle associate — xray not accepting UDP on this port"
  fi
  hint+=" → make refresh-full, then reconnect VPN on phone"
elif [[ "${xray_udp_recent}" -gt 0 && "${inject_recent}" -eq 0 ]]; then
  verdict="MODE-B"
  hint="half-path — xray accepts outbound, inject=0 (SOCKS return dead)"
  if [[ -n "${last_scenario}" ]]; then
    hint+="; last_closed=${last_scenario}"
  fi
  if [[ "${last_socks_rx:-x}" == "0" ]]; then
    hint+="; socks_udp_rx=0 at close → xray not returning on SOCKS UDP"
  elif [[ -n "${last_socks_rx}" && "${last_socks_rx}" != "0" ]]; then
    hint+="; socks_udp_rx=${last_socks_rx} → replies arrived but not injected (session/inject)"
  fi
  if [[ "${multi_associate}" -eq 1 ]]; then
    verdict="MODE-B+"
    hint+="; ${#all_ports[@]} associate ports (tcp-eof reconnects — check associate closed stats)"
  fi
  hint+=" → make refresh-full; do NOT pkill udp-relay alone"
elif [[ "${inject_on_port}" -eq 0 && "${xray_udp_port}" -eq 0 ]]; then
  verdict="MODE-A"
  hint="no inject and no xray udp on port ${associate_port} → make refresh-full"
else
  verdict="DEGRADED"
  hint="inject_ever=${inject_on_port} but path unhealthy now (one-way=${one_way_recent}) → make refresh-full"
fi

echo "── Verdict ──"
if [[ "${verdict}" == OK || "${verdict}" == OK-IDLE ]]; then
  log_info "VERDICT: ${verdict} — ${hint}"
  exit 0
fi
log_warn "VERDICT: ${verdict} — ${hint}"
log_warn "fix (does not run automatically): make refresh-full"
exit 1
