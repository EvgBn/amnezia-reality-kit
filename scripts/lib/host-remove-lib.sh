#!/usr/bin/env bash
# Host VPN network teardown — testable via DOCKER, HOST_ENV_FILE, HOST_SYSTEMD_DIR overrides.

_HOST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-network.sh
source "${_HOST_LIB_DIR}/host-network.sh"
# shellcheck source=host-kmod-remove.sh
source "${_HOST_LIB_DIR}/host-kmod-remove.sh"
# shellcheck source=host-autoboot.sh
source "${_HOST_LIB_DIR}/host-autoboot.sh"

host_remove_run() {
  local HOST_REPO STACK_REPO STACK_ENV SUBNET GATEWAY
  local removed_routes removed_rules unit f

  HOST_REPO="$(read_host_repo_root)"
  STACK_REPO="${HOST_REMOVE_STACK_REPO:-${HOST_REPO:-${REPO_ROOT}}}"
  STACK_ENV="${HOST_REMOVE_STACK_ENV:-${STACK_REPO}/.data/.env}"

  if [[ -n "${HOST_REPO}" && "${HOST_REPO}" != "${REPO_ROOT}" ]]; then
    log_warn "Host registered at ${HOST_REPO} (${HOST_ENV_FILE}); running from ${REPO_ROOT}."
  fi
  SUBNET="${AWG_TUNNEL_SUBNET_DEFAULT}"
  GATEWAY="${AWG_BRIDGE_GATEWAY_DEFAULT}"
  if [[ -f "${STACK_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${STACK_ENV}"
    # shellcheck source=docker-network-plan.sh
    source "${_HOST_LIB_DIR}/docker-network-plan.sh"
    docker_network_plan_resolve "${STACK_ENV}" || true
    SUBNET="${AWG_TUNNEL_SUBNET_IPV4:-${SUBNET}}"
    GATEWAY="${AMNEZIAWG_IP:-${GATEWAY}}"
  fi

  for ctr in vpn-xray vpn-amneziawg vpn-coredns; do
    if _host_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${ctr}"; then
      log_error "Container '${ctr}' is still running. Stop the stack first:"
      log_error "  cd ${STACK_REPO} && make down"
      return 1
    fi
  done

  log_info "Removing host VPN network artifacts (stack repo: ${STACK_REPO})…"

  removed_routes="$(host_awg_routes_remove "${SUBNET}" "${GATEWAY}")"
  if [[ "${removed_routes}" -gt 0 ]]; then
    log_info "Removed ${removed_routes} host route(s) for ${SUBNET} via ${GATEWAY}."
  else
    log_info "No host route for ${SUBNET} via ${GATEWAY}."
  fi

  for unit in "${HOST_REMOVE_SYSTEMD_UNITS[@]}"; do
    if host_systemd_unit_remove "${unit}"; then
      log_info "Removed ${unit}"
    fi
  done

  removed_rules=0
  for fw_try in "${VPN_DOCKER_SUBNET_CIDR:-}" "10.200.97.0/24" "172.28.0.0/24" "172.20.0.0/24"; do
    [[ -n "${fw_try}" ]] || continue
    VPN_DOCKER_SUBNET_CIDR="${fw_try}"
    n="$(host_input_vpn_drop_rules_remove)"
    removed_rules=$((removed_rules + n))
  done
  if [[ "${removed_rules}" -gt 0 ]]; then
    log_info "Removed ${removed_rules} iptables INPUT rule(s) for ${VPN_DOCKER_SUBNET_CIDR}."
  else
    log_info "No iptables INPUT rule for ${VPN_DOCKER_SUBNET_CIDR}."
  fi

  for f in "${HOST_DROPIN_FILES[@]}"; do
    if [[ -f "${f}" ]]; then
      rm -f "${f}"
      log_info "Removed ${f}"
    fi
  done

  host_l2_teardown

  log_info "Removing AmneziaWG kernel module…"
  if ! kmod_remove_run; then
    return 1
  fi

  log_warn "Left unchanged: net.ipv4.ip_forward in /etc/sysctl.conf (if set by deploy-host)."
  log_warn "Live conntrack sysctl values persist until reboot."
  log_info "Done. Host network teardown complete. Redeploy: cd ${STACK_REPO} && sudo make deploy-host"
  return 0
}
