#!/bin/sh
set -e

echo "[coredns-init] Starting CoreDNS..."

# Wait for ipt2socks to be ready
timeout=15
while [ $timeout -gt 0 ]; do
  if pgrep -x ipt2socks >/dev/null; then
    echo "[coredns-init] ipt2socks process detected."
    break
  fi
  sleep 1
  timeout=$((timeout - 1))
done

if [ $timeout -eq 0 ]; then
  echo "[coredns-init] WARNING: ipt2socks not detected, continuing anyway..." >&2
fi

# Start CoreDNS (no exec — supervisord manages)
exec /usr/local/bin/coredns -conf /Corefile
