#!/usr/bin/env bash
# Phase 10: OUT — reachability (ping, non-blocking) + egress match via SOCKS.

preflight_phase_10_out() {
  local got_ip

  phase_header "Phase 10: OUT path"

  if ! preflight_docker_accessible; then
    emit SKIP OUT docker "daemon not accessible"
    return
  fi

  if ! preflight_stack_configured; then
    emit SKIP OUT stack "not deployed yet" "make create-data && make first-start"
    return
  fi

  if ! preflight_stack_any_running; then
    emit SKIP OUT stack "not running" "make start"
    return
  fi

  if ! preflight_out_stack_ready; then
    emit SKIP OUT xray "not running or unhealthy" "make ps && make logs"
    return
  fi

  if [[ -z "${OUT_EXIT_ADDRESS:-}" || -z "${OUT_EXIT_FAMILY:-}" ]]; then
    emit SKIP OUT OUT_EXIT "address not resolved" "set OUT_EXIT in .data/.env"
    return
  fi

  # Probe A: ping — informative only; never FAIL, never blocks probe B.
  if preflight_out_ping "${OUT_EXIT_FAMILY}" "${OUT_EXIT_ADDRESS}"; then
    emit OK OUT OUT_EXIT-reach "replies from ${OUT_EXIT_ADDRESS}"
  else
    emit WARN OUT OUT_EXIT-reach "not received (icmp)" \
      "OUT may still work via TCP — check egress probe below"
  fi

  # Probe B: SOCKS egress vs OUT_EXPECTED_EGRESS.
  if [[ -z "${OUT_EXPECTED_EGRESS_ADDRESS:-}" ]]; then
    emit SKIP OUT egress-match "OUT_EXPECTED_EGRESS not set" \
      "set OUT_EXPECTED_EGRESS=4; <expected curl IP>"
    return
  fi

  if [[ -z "${SOCKS_USER:-}" || -z "${SOCKS_PASSWORD:-}" ]]; then
    emit SKIP OUT egress-match "SOCKS credentials missing" "check .data/.env"
    return
  fi

  got_ip="$(preflight_out_curl_egress "${SOCKS_USER}" "${SOCKS_PASSWORD}" "${SOCKS_PORT:-1080}")" || {
    preflight_emit WARN OUT egress-match \
      "connection not established (curl via SOCKS failed)" \
      "make logs; verify OUT_* keys and OUT server REALITY"
    return
  }

  if [[ "${got_ip}" == "${OUT_EXPECTED_EGRESS_ADDRESS}" ]]; then
    emit OK OUT egress-match "${got_ip} == ${OUT_EXPECTED_EGRESS_ADDRESS}"
  else
    preflight_emit WARN OUT egress-match \
      "got ${got_ip}, expected ${OUT_EXPECTED_EGRESS_ADDRESS}" \
      "verify OUT_EXIT / OUT credentials / OUT server egress"
  fi
}
