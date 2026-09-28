#!/usr/bin/env bash
# Phase 7: NETWORK — XRAY inbound / :443 policy, UDP AWG_PORT, route (when stack up).

preflight_phase_07_network() {
  phase_header "Phase 7: Network"

  preflight_check_xray_inbound_port
  preflight_check_udp_port "${AWG_PORT:-58285}" vpn-amneziawg
  preflight_check_awg_host_route \
    "${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}" \
    "${AMNEZIAWG_IP:-10.200.97.3}"
}
