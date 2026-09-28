#!/bin/sh
set -e

if ! pgrep -x ipt2socks >/dev/null; then
  echo "FAIL: ipt2socks process not running" >&2
  exit 1
fi

if ! pgrep -f '/usr/local/bin/coredns' >/dev/null; then
  echo "FAIL: coredns process not running" >&2
  exit 1
fi

if ! dig @127.0.0.1 +time=2 +tries=1 cloudflare.com A >/dev/null 2>&1; then
  echo "FAIL: DNS lookup via CoreDNS failed" >&2
  exit 1
fi

echo "OK: coredns healthy (ipt2socks + coredns running, DNS OK)"
exit 0
