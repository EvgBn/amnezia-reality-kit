#!/usr/bin/env bash
# Phase 9: STACK — vpn-* healthy, route ↔ bridge not stale.

preflight_phase_09_stack() {
  phase_header "Phase 9: Stack runtime"

  if ! preflight_docker_accessible; then
    emit SKIP STACK docker "daemon not accessible"
    return
  fi

  if ! preflight_stack_configured; then
    emit SKIP STACK stack "not deployed yet" "make create-data && make first-start"
    return
  fi

  if ! preflight_stack_any_running; then
    if stack_state_is_stopped; then
      emit OK STACK stack "intentionally stopped (.stack-stopped)"
      return
    fi
    if preflight_boot_unit_enabled; then
      preflight_emit WARN STACK stack \
        "stopped — boot will auto-start on reboot (no .stack-stopped)" \
        "make down to persist stop, or make start"
    else
      preflight_emit WARN STACK stack "stopped (no vpn-* containers)" "make start"
    fi
    return
  fi

  local -a expected=()
  local name
  preflight_stack_containers_expected expected
  for name in "${expected[@]}"; do
    preflight_check_stack_container "${name}"
  done

  preflight_check_route_bridge "${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}"
}
