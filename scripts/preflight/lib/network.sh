#!/usr/bin/env bash
# Network probes: ports, AWG subnet route (phase 7).
# Uses preflight_stack_any_running from lib/probes.sh

preflight_port_holder_name() {
  local proto="$1" port="$2"
  case "${proto}" in
    tcp)
      ss -Hltnp 2>/dev/null | grep -E ":${port}([^0-9]|$)" | head -1 || true
      ;;
    udp)
      ss -Hlunp 2>/dev/null | grep -E ":${port}([^0-9]|$)" | head -1 || true
      ;;
  esac
}

preflight_check_xray_inbound_port() {
  # shellcheck source=../../lib/common.sh
  source "${REPO_ROOT}/scripts/lib/common.sh"
  local enable port holder
  enable="$(parse_bool "${ENABLE_XRAY_INBOUND:-}" 1)"
  if [[ "${enable}" == "1" ]]; then
    port="${XRAY_INBOUND_PORT:-443}"
    preflight_check_tcp_port "${port}" vpn-xray
    return
  fi

  if preflight_port_in_use tcp 443; then
    holder="$(preflight_port_holder_name tcp 443)"
    if [[ "${holder}" == *vpn-xray* ]] || [[ "${holder}" == *docker-proxy* ]]; then
      emit FAIL PORTS "tcp/443" "vpn-xray still binds :443" \
        "set ENABLE_XRAY_INBOUND=0, make build && make recreate"
    else
      emit OK PORTS "tcp/443" "in use (inbound disabled — OK for website)"
    fi
  else
    emit OK PORTS "tcp/443" "free (inbound disabled)"
  fi
}

preflight_check_tcp_port() {
  local port="$1" expected_container="$2"
  if preflight_port_in_use tcp "${port}"; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${expected_container}"; then
      emit OK PORTS "tcp/${port}" "in use by ${expected_container}"
    else
      emit FAIL PORTS "tcp/${port}" "port busy (not ${expected_container})" \
        "free ${port}/tcp or stop conflicting service"
    fi
  else
    emit OK PORTS "tcp/${port}" "free"
  fi
}

preflight_check_udp_port() {
  local port="$1" expected_container="$2"
  if preflight_port_in_use udp "${port}"; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${expected_container}"; then
      emit OK PORTS "udp/${port}" "in use by ${expected_container}"
    else
      emit FAIL PORTS "udp/${port}" "UDP port busy" \
        "stop conflicting stack or change AWG_PORT"
    fi
  else
    emit OK PORTS "udp/${port}" "free"
  fi
}

preflight_check_awg_host_route() {
  local subnet="${1:-${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}}"
  local gw="${2:-${AMNEZIAWG_IP:-10.200.97.3}}"

  if ! preflight_stack_any_running; then
    emit SKIP ROUTE "${subnet}" "stack not running"
    return
  fi

  local route_line
  route_line="$(ip route show "${subnet}" 2>/dev/null | head -1 || true)"
  if [[ -n "${route_line}" ]] && [[ "${route_line}" == *"via ${gw}"* ]]; then
    emit OK ROUTE "${subnet}" "${route_line}"
  elif [[ -n "${route_line}" ]]; then
    emit WARN ROUTE "${subnet}" "route present but not via ${gw}" "make start"
  else
    emit WARN ROUTE "${subnet}" "no host route" "make start"
  fi
}
