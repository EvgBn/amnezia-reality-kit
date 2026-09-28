#!/usr/bin/env bash
# Stack runtime probes: container health, route ↔ docker bridge (phase 9).

preflight_vpn_network_bridge() {
  if ! docker network inspect vpn >/dev/null 2>&1; then
    return 1
  fi
  local net_id
  net_id="$(docker network inspect vpn -f '{{.Id}}')"
  printf 'br-%s' "${net_id:0:12}"
}

preflight_container_status() {
  local s
  s="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" || true
  s="${s//$'\n'/}"
  if [[ -z "${s}" ]]; then
    echo missing
  else
    echo "${s}"
  fi
}

preflight_container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$1" 2>/dev/null \
    || echo unknown
}

preflight_check_stack_container() {
  local name="$1"
  local status health fix

  status="$(preflight_container_status "${name}")"
  case "${status}" in
    missing)
      if preflight_stack_any_running; then
        emit FAIL STACK "${name}" "expected but not running" "make start"
      else
        emit SKIP STACK "${name}" "not running"
      fi
      ;;
    running)
      health="$(preflight_container_health "${name}")"
      case "${health}" in
        healthy)
          emit OK STACK "${name}" "running (healthy)"
          ;;
        unhealthy)
          fix="make logs; make recreate"
          [[ "${name}" == "vpn-coredns" ]] && \
            fix="make build && make recreate"
          emit FAIL STACK "${name}" "running (unhealthy)" "${fix}"
          ;;
        starting|no-healthcheck)
          emit OK STACK "${name}" "running (${health})"
          ;;
        *)
          emit WARN STACK "${name}" "running (${health})" "make ps && make logs"
          ;;
      esac
      ;;
    *)
      emit FAIL STACK "${name}" "state=${status}" "make ps && make up"
      ;;
  esac
}

preflight_check_route_bridge() {
  local subnet="${1:-${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}}"

  if ! preflight_stack_any_running; then
    emit SKIP STACK route-bridge "stack not running"
    return
  fi

  local br route_line
  br="$(preflight_vpn_network_bridge)" || {
    emit SKIP STACK route-bridge "docker network vpn missing"
    return
  }

  route_line="$(ip route show "${subnet}" 2>/dev/null | head -1 || true)"
  if [[ -z "${route_line}" ]]; then
    emit WARN STACK route-bridge "no route for ${subnet}" "make start"
  elif [[ "${route_line}" == *"${br}"* ]]; then
    emit OK STACK route-bridge "route uses ${br}"
  else
    emit WARN STACK route-bridge "stale (expected dev ${br})" "make start"
  fi
}
