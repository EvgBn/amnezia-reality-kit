#!/usr/bin/env bash
set -euo pipefail

IFACE="awg0"
CONF="/etc/awg/awg0.conf"
UDP_DPORTS="53,784,8853"

if [[ -f /etc/ipt2socks/ports.env ]]; then
  # shellcheck disable=SC1091
  . /etc/ipt2socks/ports.env
fi
: "${AWG_IPT2SOCKS_PORT:=12345}"
: "${AWG_IPT2SOCKS_PORT_IPV6:=12346}"
: "${AWG_UDP_RELAY_PORT:=12348}"
: "${AWG_UDP_RELAY_PORT_IPV6:=12349}"
: "${AWG_NFQUEUE_NUM:=100}"

echo "[awg-init] Starting AmneziaWG interface ${IFACE}..."

export IFACE CONF UDP_DPORTS AWG_UDP_RELAY_PORT AWG_UDP_RELAY_PORT_IPV6 AWG_NFQUEUE_NUM
/awg-migrate-tproxy.sh

cleanup_duplicate_postup_rules() {
  local coredns_ip=""
  local coredns_ipv6=""
  if [[ -f "${CONF}" ]]; then
    coredns_ip="$(awk -F': ' '/^PostUp = iptables.*DNAT --to-destination/ {gsub(/:.*/, "", $2); print $2; exit}' "${CONF}")"
    coredns_ipv6="$(awk -F'[][]' '/^PostUp = ip6tables.*DNAT --to-destination/ {print $2; exit}' "${CONF}")"
  fi

  # NAT duplicates from interrupted awg-quick runs (not TPROXY — see awg-migrate-tproxy.sh)
  if [[ -n "${coredns_ip}" ]]; then
    while iptables -t nat -D PREROUTING -i "${IFACE}" -p udp --dport 53 -j DNAT --to-destination "${coredns_ip}:53" 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -i "${IFACE}" -p tcp --dport 53 -j DNAT --to-destination "${coredns_ip}:53" 2>/dev/null; do :; done
  fi
  if [[ -n "${coredns_ipv6}" ]]; then
    while ip6tables -t nat -D PREROUTING -i "${IFACE}" -p udp --dport 53 -j DNAT --to-destination "[${coredns_ipv6}]:53" 2>/dev/null; do :; done
    while ip6tables -t nat -D PREROUTING -i "${IFACE}" -p tcp --dport 53 -j DNAT --to-destination "[${coredns_ipv6}]:53" 2>/dev/null; do :; done
  fi
  while iptables -t nat -D PREROUTING -i "${IFACE}" -p tcp ! --dport 53 -j REDIRECT --to-port "${AWG_IPT2SOCKS_PORT}" 2>/dev/null; do :; done
  while ip6tables -t nat -D PREROUTING -i "${IFACE}" -p tcp ! --dport 53 -j REDIRECT --to-port "${AWG_IPT2SOCKS_PORT_IPV6}" 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -d 127.0.0.1/32 ! -s 127.0.0.1/32 -j SNAT --to-source 127.0.0.1 2>/dev/null; do :; done
  while ip6tables -t nat -D POSTROUTING -d ::1/128 ! -s ::1/128 -j SNAT --to-source ::1 2>/dev/null; do :; done
}

cleanup_duplicate_postup_rules

# Cleanup stale interface
ip link delete "${IFACE}" 2>/dev/null || true

# Bring up interface via awg-quick
awg-quick up "${CONF}"

echo "[awg-init] Interface ${IFACE} is UP."
ip addr show "${IFACE}"
awg show

# Keep process alive (supervisord manages it)
exec sleep infinity
