#!/usr/bin/env bash
# Host network helpers (iptables, routes, systemd unit files).
# Testable via IPTABLES= and IP= command overrides.
# shellcheck source=host-artifacts.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host-artifacts.sh"

VPN_DOCKER_SUBNET_CIDR="${VPN_DOCKER_SUBNET_CIDR:-}"
AWG_TUNNEL_SUBNET_DEFAULT="${AWG_TUNNEL_SUBNET_DEFAULT:-10.8.0.0/24}"
AWG_BRIDGE_GATEWAY_DEFAULT="${AWG_BRIDGE_GATEWAY_DEFAULT:-}"
HOST_IPTABLES_CHAIN="${HOST_IPTABLES_CHAIN:-INPUT}"
HOST_SYSTEMD_DIR="${HOST_SYSTEMD_DIR:-/etc/systemd/system}"

_host_iptables() {
  "${IPTABLES:-iptables}" "$@"
}

_host_ip() {
  "${IP:-ip}" "$@"
}

_host_systemctl() {
  "${SYSTEMCTL:-systemctl}" "$@"
}

_host_docker() {
  "${DOCKER:-docker}" "$@"
}

host_systemd_unit_path() {
  printf '%s/%s' "${HOST_SYSTEMD_DIR}" "$1"
}

host_systemd_unit_present() {
  [[ -f "$(host_systemd_unit_path "$1")" ]]
}

# Remove a unit file and disable it. Returns 0 if removed, 1 if unit file was absent.
host_systemd_unit_remove() {
  local unit="$1" path
  path="$(host_systemd_unit_path "${unit}")"
  [[ -f "${path}" ]] || return 1
  _host_systemctl disable --now "${unit}" >/dev/null 2>&1 || true
  rm -f "${path}"
  _host_systemctl daemon-reload
  return 0
}

host_systemd_units_remove() {
  local unit removed=0
  for unit in "$@"; do
    if host_systemd_unit_remove "${unit}"; then
      removed=$((removed + 1))
    fi
  done
  printf '%s' "${removed}"
}

host_input_vpn_drop_rule_present() {
  _host_iptables -C "${HOST_IPTABLES_CHAIN}" \
    -s "${VPN_DOCKER_SUBNET_CIDR}" -m conntrack --ctstate NEW -j DROP 2>/dev/null
}

host_input_vpn_drop_rules_remove() {
  local removed=0
  while host_input_vpn_drop_rule_present; do
    _host_iptables -D "${HOST_IPTABLES_CHAIN}" \
      -s "${VPN_DOCKER_SUBNET_CIDR}" -m conntrack --ctstate NEW -j DROP
    removed=$((removed + 1))
  done
  printf '%s' "${removed}"
}

host_awg_route_lines() {
  local subnet="$1" gateway="$2"
  _host_ip route show "${subnet}" 2>/dev/null | grep "via ${gateway}" || true
}

host_awg_routes_remove() {
  local subnet="$1" gateway="$2"
  local removed=0 line dev
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    dev="$(awk '{print $NF}' <<<"${line}")"
    _host_ip route del "${subnet}" via "${gateway}" dev "${dev}" 2>/dev/null || true
    removed=$((removed + 1))
  done < <(host_awg_route_lines "${subnet}" "${gateway}")
  printf '%s' "${removed}"
}
