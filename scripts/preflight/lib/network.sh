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

# ss -Hltnp users:(("procname",…)) — common host TLS fronts (see docs/PORT-443.md).
preflight_port_holder_is_website_front() {
  local holder_lc
  holder_lc="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "${holder_lc}" in
    *nginx*|*caddy*|*haproxy*|*apache*|*httpd*)
      return 0
      ;;
  esac
  return 1
}

preflight_xray_inbound_busy_fix() {
  local port="$1" holder="$2"
  if preflight_port_holder_is_website_front "${holder}"; then
    printf '%s' "set ENABLE_XRAY_INBOUND=0 or XRAY_INBOUND_PORT=8443; make build && make recreate (docs/PORT-443.md)"
    return
  fi
  if ! preflight_stack_any_running; then
    printf '%s' "make start or set ENABLE_XRAY_INBOUND=0 in .data/.env"
    return
  fi
  printf 'free %s/tcp or stop conflicting service' "${port}"
}

preflight_check_xray_inbound_port() {
  # shellcheck source=../../lib/common.sh
  source "${REPO_ROOT}/scripts/lib/common.sh"
  local enable port holder fix

  if [[ ! -f "${ENV_FILE:-}" ]]; then
    emit SKIP PORTS xray-inbound-policy "no .data/.env" \
      "make create-data COPY_FROM=…; if host :443 is a website set ENABLE_XRAY_INBOUND=0 (docs/PORT-443.md)"
    return
  fi

  enable="$(parse_bool "${ENABLE_XRAY_INBOUND:-}" 1)"
  if [[ "${enable}" == "1" ]]; then
    port="${XRAY_INBOUND_PORT:-443}"
    if ! preflight_port_in_use tcp "${port}"; then
      emit OK PORTS "tcp/${port}" "free"
      return
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx vpn-xray; then
      emit OK PORTS "tcp/${port}" "in use by vpn-xray"
      return
    fi
    holder="$(preflight_port_holder_name tcp "${port}")"
    fix="$(preflight_xray_inbound_busy_fix "${port}" "${holder}")"
    emit FAIL PORTS "tcp/${port}" "port busy (not vpn-xray)" "${fix}"
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
