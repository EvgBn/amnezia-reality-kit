#!/usr/bin/env bash
set -euo pipefail

echo "Starting coredns (CoreDNS + ipt2socks)..."

# Start supervisord
exec /usr/bin/supervisord -c /etc/supervisord.conf
