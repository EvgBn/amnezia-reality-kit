#!/usr/bin/env bash
# Remove legacy Track B (TPROXY / policy-routing) iptables state before NFQUEUE + udp-relay.
# Safe to run on every container start; no-op when nothing to clean.
set -euo pipefail

: "${IFACE:?IFACE required}"
: "${CONF:?CONF required}"
: "${UDP_DPORTS:?UDP_DPORTS required}"
: "${AWG_UDP_RELAY_PORT:=12348}"
: "${AWG_UDP_RELAY_PORT_IPV6:=12349}"
: "${AWG_NFQUEUE_NUM:=100}"

tproxy_on_ip4=""
tproxy_on_ip6=""
if [[ -f "${CONF}" ]]; then
  tproxy_on_ip4="$(awk -F' = ' '/^Address = / && !/:/ {print $2; exit}' "${CONF}" | cut -d/ -f1)"
  tproxy_on_ip6="$(awk -F' = ' '/^Address = / && /:/ {print $2; exit}' "${CONF}" | cut -d/ -f1)"
fi
: "${tproxy_on_ip4:=10.8.0.1}"
: "${tproxy_on_ip6:=fd86:ea04:1115::1}"

echo "[awg-migrate] Removing legacy TPROXY / old NFQUEUE rules on ${IFACE}…"

# IPv4 mangle: drop jumps before deleting custom chains
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -d 10.0.0.0/8 -j RETURN 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -d 172.16.0.0/12 -j RETURN 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -d 192.168.0.0/16 -j RETURN 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -d 100.64.0.0/10 -j RETURN 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m multiport ! --dports "${UDP_DPORTS}" -m conntrack --ctdir ORIGINAL -m addrtype ! --dst-type LOCAL -j NFQUEUE --queue-num "${AWG_NFQUEUE_NUM}" --queue-bypass 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m multiport ! --dports "${UDP_DPORTS}" -m conntrack ! --ctdir REPLY -m addrtype ! --dst-type LOCAL -j NFQUEUE --queue-num "${AWG_NFQUEUE_NUM}" --queue-bypass 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m multiport ! --dports "${UDP_DPORTS}" -m conntrack --ctdir REPLY -j RETURN 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m multiport ! --dports "${UDP_DPORTS}" -j AWG_UDP4_TPROXY 2>/dev/null; do :; done
while iptables -t mangle -D OUTPUT -p udp -m mark --mark 0x1/0x1 -j CONNMARK --restore-mark 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m mark --mark 0x1/0x1 -j TPROXY --on-ip 127.0.0.1 --on-port "${AWG_UDP_RELAY_PORT}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m connmark --mark 0x1/0x1 -j TPROXY --on-ip 127.0.0.1 --on-port "${AWG_UDP_RELAY_PORT}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m mark --mark 0x1/0x1 -j TPROXY --on-ip "${tproxy_on_ip4}" --on-port "${AWG_UDP_RELAY_PORT}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
while iptables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m connmark --mark 0x1/0x1 -j TPROXY --on-ip "${tproxy_on_ip4}" --on-port "${AWG_UDP_RELAY_PORT}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
iptables -t mangle -F AWG_UDP4_TPROXY 2>/dev/null || true
iptables -t mangle -X AWG_UDP4_TPROXY 2>/dev/null || true

# IPv6 mangle
while ip6tables -t mangle -D OUTPUT -p udp -m mark --mark 0x1/0x1 -j CONNMARK --restore-mark 2>/dev/null; do :; done
while ip6tables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m mark --mark 0x1/0x1 -j TPROXY --on-ip ::1 --on-port "${AWG_UDP_RELAY_PORT_IPV6}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
while ip6tables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m connmark --mark 0x1/0x1 -j TPROXY --on-ip ::1 --on-port "${AWG_UDP_RELAY_PORT_IPV6}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
while ip6tables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m mark --mark 0x1/0x1 -j TPROXY --on-ip "${tproxy_on_ip6}" --on-port "${AWG_UDP_RELAY_PORT_IPV6}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
while ip6tables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m connmark --mark 0x1/0x1 -j TPROXY --on-ip "${tproxy_on_ip6}" --on-port "${AWG_UDP_RELAY_PORT_IPV6}" --tproxy-mark 0x1/0x1 2>/dev/null; do :; done
while ip6tables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m multiport ! --dports "${UDP_DPORTS}" -j AWG_UDP6_TPROXY 2>/dev/null; do :; done
while ip6tables -t mangle -D PREROUTING -i "${IFACE}" -p udp -m multiport ! --dports "${UDP_DPORTS}" -m conntrack --ctdir REPLY -j RETURN 2>/dev/null; do :; done
ip6tables -t mangle -F AWG_UDP6_TPROXY 2>/dev/null || true
ip6tables -t mangle -X AWG_UDP6_TPROXY 2>/dev/null || true

# Policy routing leftovers from TPROXY era
ip -4 rule del fwmark 1 lookup 100 2>/dev/null || true
ip -4 route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
ip -4 route del local "${tproxy_on_ip4}"/32 dev awg0 table 100 2>/dev/null || true
ip -6 rule del fwmark 1 lookup 100 2>/dev/null || true
ip -6 route del local default dev lo table 100 2>/dev/null || true
ip -6 route del local "${tproxy_on_ip6}"/128 dev awg0 table 100 2>/dev/null || true
