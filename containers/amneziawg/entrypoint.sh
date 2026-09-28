#!/usr/bin/env bash
set -euo pipefail

# ── Pre-flight check: amneziawg kernel module must be loaded on the host ──
if ! grep -q '^amneziawg ' /proc/modules; then
  echo "Error: amneziawg kernel module is not loaded on the host." >&2
  echo "First install:        sudo make deploy-host" >&2
  echo "After kernel upgrade: sudo make deploy-host  # or:" >&2
  echo "                      docker compose -f .data/build/docker-compose.yml stop amneziawg &&" >&2
  echo "                      sudo ./scripts/maintenance/rebuild-amneziawg.sh &&" >&2
  echo "                      make start" >&2
  exit 1
fi

echo "Starting amneziawg (AmneziaWG + ipt2socks tcp + udp-relay)..."

# Start supervisord
exec /usr/bin/supervisord -c /etc/supervisord.conf
