#!/usr/bin/env bash
# L0 BASE_HOST — ip_forward, conntrack sizing, vpn-host-firewall.
# Always applied by deploy-host; no operator enable/disable flag.
# Teardown symmetry: host-remove (firewall unit + L0 drop-ins).

_host_base_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-artifacts.sh
source "${_host_base_lib_dir}/host-artifacts.sh"

host_l0_install() {
  local repo_root="${1:?repo_root required}"
  local stack_env="${repo_root}/.data/.env"
  local firewall_subnet="10.200.97.0/24"
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # shellcheck source=docker-network-plan.sh
  source "${lib_dir}/docker-network-plan.sh"

  # ── IP forwarding ───────────────────────────────────────────────────────
  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
    log_info "Enabling IP forwarding…"
    sysctl -w net.ipv4.ip_forward=1
  fi
  if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    log_info "Made IP forwarding persistent in /etc/sysctl.conf"
  fi

  # ── Conntrack sizing ─────────────────────────────────────────────────────
  modprobe nf_conntrack 2>/dev/null || true
  echo nf_conntrack > /etc/modules-load.d/vpn-conntrack.conf

  local ct_max_floor=32768 ct_hash_floor=8192 cur_max cur_hash ct_max ct_hash
  cur_max="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)"
  cur_hash="$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo 0)"
  [[ "${cur_max}"  =~ ^[0-9]+$ ]] || cur_max=0
  [[ "${cur_hash}" =~ ^[0-9]+$ ]] || cur_hash=0
  ct_max=$(( cur_max  > ct_max_floor  ? cur_max  : ct_max_floor  ))
  ct_hash=$(( cur_hash > ct_hash_floor ? cur_hash : ct_hash_floor ))

  cat > /etc/sysctl.d/99-vpn-conntrack.conf <<CONF
net.netfilter.nf_conntrack_max = ${ct_max}
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
CONF
  cat > /etc/modprobe.d/vpn-conntrack.conf <<CONF
options nf_conntrack hashsize=${ct_hash}
CONF

  if [[ -d /proc/sys/net/netfilter ]]; then
    sysctl -q -p /etc/sysctl.d/99-vpn-conntrack.conf || true
    if [[ -w /sys/module/nf_conntrack/parameters/hashsize && "${ct_hash}" -gt "${cur_hash}" ]]; then
      echo "${ct_hash}" > /sys/module/nf_conntrack/parameters/hashsize || true
    fi
  fi
  log_info "Conntrack table sized (nf_conntrack_max=${ct_max})."

  # ── Host INPUT hardening ─────────────────────────────────────────────────
  if [[ -f "${stack_env}" ]]; then
    if docker_network_plan_resolve "${stack_env}"; then
      firewall_subnet="${VPN_DOCKER_SUBNET_CIDR}"
      log_info "Host firewall subnet from .data/.env: ${firewall_subnet}"
    else
      log_warn "Could not resolve docker network from .data/.env — using ${firewall_subnet}"
    fi
  else
    log_warn "No .data/.env yet — firewall uses default ${firewall_subnet} (re-run deploy-host after make create-data)"
  fi

  cat > "/etc/systemd/system/${HOST_FIREWALL_UNIT}" <<UNIT
[Unit]
Description=Block new connections from the VPN docker subnet to the host
After=network-pre.target
Before=network.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/iptables -C INPUT -s ${firewall_subnet} -m conntrack --ctstate NEW -j DROP 2>/dev/null || /usr/sbin/iptables -I INPUT 1 -s ${firewall_subnet} -m conntrack --ctstate NEW -j DROP'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now "${HOST_FIREWALL_UNIT}" >/dev/null
  log_info "Installed ${HOST_FIREWALL_UNIT}"
}
