#!/usr/bin/env bash
# Phase 5: host sysctl (ip_forward, conntrack).

preflight_phase_05_host_sysctl() {
  phase_header "Phase 5: Host sysctl"

  local fwd
  fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  if [[ "${fwd}" == "1" ]]; then
    emit OK SYSCTL ip_forward "net.ipv4.ip_forward=1"
  else
    emit WARN SYSCTL ip_forward "net.ipv4.ip_forward=${fwd}" \
      "sudo make deploy-host"
  fi

  if [[ -f /etc/sysctl.d/99-vpn-conntrack.conf ]]; then
    emit OK SYSCTL conntrack "99-vpn-conntrack.conf present"
  else
    emit WARN SYSCTL conntrack "99-vpn-conntrack.conf missing" \
      "sudo make deploy-host"
  fi

  if [[ -d /proc/sys/net/netfilter ]] || lsmod 2>/dev/null | grep -q nf_conntrack; then
    emit OK SYSCTL nf_conntrack "module/sysfs present"
  else
    emit WARN SYSCTL nf_conntrack "nf_conntrack not loaded" \
      "sudo make deploy-host"
  fi
}
