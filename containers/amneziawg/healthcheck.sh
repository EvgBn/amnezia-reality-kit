#!/bin/sh
set -e

# shellcheck disable=SC1091
. /etc/ipt2socks/ports.env

# Check 1: awg0 interface exists and is UP
if ! ip link show awg0 | grep -qE 'state UP|LOWER_UP'; then
  echo "FAIL: awg0 interface not UP" >&2
  exit 1
fi

# Check 2: ipt2socks TCP + udp-relay processes
IPT2_COUNT="$(pgrep -x ipt2socks 2>/dev/null | wc -l | tr -d ' ')"
if [ "${IPT2_COUNT}" -lt 2 ]; then
  echo "FAIL: expected 2 ipt2socks processes (tcp v4/v6), got ${IPT2_COUNT}" >&2
  exit 1
fi
if ! pgrep -f '/usr/local/bin/udp-relay' >/dev/null 2>&1; then
  echo "FAIL: udp-relay process not running" >&2
  exit 1
fi

# Check 3: iptables REDIRECT (TCP v4)
if ! iptables -t nat -C PREROUTING -i awg0 -p tcp ! --dport 53 -j REDIRECT --to-port "${AWG_IPT2SOCKS_PORT}" 2>/dev/null; then
  echo "FAIL: iptables REDIRECT rule missing (port ${AWG_IPT2SOCKS_PORT})" >&2
  exit 1
fi

# Check 4: ip6tables REDIRECT (TCP v6)
if ! ip6tables -t nat -C PREROUTING -i awg0 -p tcp ! --dport 53 -j REDIRECT --to-port "${AWG_IPT2SOCKS_PORT_IPV6}" 2>/dev/null; then
  echo "FAIL: ip6tables REDIRECT rule missing (port ${AWG_IPT2SOCKS_PORT_IPV6})" >&2
  exit 1
fi

# Check 5: iptables NFQUEUE (UDP v4 exit)
if ! iptables -t mangle -C PREROUTING -i awg0 -p udp -m multiport ! --dports 53,784,8853 \
    -m addrtype ! --dst-type LOCAL \
    -j NFQUEUE --queue-num "${AWG_NFQUEUE_NUM}" --queue-bypass 2>/dev/null \
  && ! iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -q "NFQUEUE num ${AWG_NFQUEUE_NUM}"; then
  echo "FAIL: iptables NFQUEUE rule missing (queue ${AWG_NFQUEUE_NUM})" >&2
  exit 1
fi

echo "OK: amneziawg healthy (awg0 UP, ipt2socks tcp, udp-relay nfqueue, redirect+nfqueue rules OK)"
exit 0
