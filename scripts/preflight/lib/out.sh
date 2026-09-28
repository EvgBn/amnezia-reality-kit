#!/usr/bin/env bash
# Phase 10: OUT path probes — reachability (ping) + egress via SOCKS.

preflight_out_docker() {
  "${PREFLIGHT_OUT_DOCKER:-docker}" "$@"
}

preflight_out_curl() {
  "${PREFLIGHT_OUT_CURL:-curl}" "$@"
}

# True when vpn-xray is running and not unhealthy.
preflight_out_stack_ready() {
  local status health
  status="$(preflight_container_status "${XRAY_CONTAINER:-vpn-xray}")"
  [[ "${status}" == "running" ]] || return 1
  health="$(preflight_container_health "${XRAY_CONTAINER:-vpn-xray}")"
  [[ "${health}" == "unhealthy" ]] && return 1
  return 0
}

# ICMP probe from vpn-xray to OUT_EXIT_ADDRESS. Returns 0 on reply.
preflight_out_ping() {
  local family="$1" addr="$2" count="${3:-2}"
  if [[ "${family}" == "6" ]]; then
    preflight_out_docker exec "${XRAY_CONTAINER:-vpn-xray}" \
      sh -c "ping6 -c ${count} -W 3 $(printf '%q' "${addr}")" >/dev/null 2>&1
  else
    preflight_out_docker exec "${XRAY_CONTAINER:-vpn-xray}" \
      sh -c "ping -c ${count} -W 3 $(printf '%q' "${addr}")" >/dev/null 2>&1
  fi
}

# Public IPv4 via SOCKS (same path as AWG → ipt2socks → xray exit). Prints IP or fails.
preflight_out_curl_egress() {
  local user="$1" pass="$2" port="${3:-1080}" ip
  # Do not embed user:pass in the proxy URL — base64 SOCKS passwords often contain '/' and break curl -x parsing.
  ip="$(preflight_out_curl -sf --max-time "${PREFLIGHT_OUT_CURL_TIMEOUT:-15}" -4 \
    -x "socks5h://127.0.0.1:${port}" --proxy-user "${user}:${pass}" \
    "${PREFLIGHT_OUT_EGRESS_URL:-https://api.ipify.org}" 2>/dev/null)" || return 1
  ip="${ip//$'\n'/}"
  ip="${ip//$'\r'/}"
  # shellcheck source=../../lib/common.sh
  source "${REPO_ROOT}/scripts/lib/common.sh"
  validate_ipv4 "${ip}" || return 1
  printf '%s' "${ip}"
}
