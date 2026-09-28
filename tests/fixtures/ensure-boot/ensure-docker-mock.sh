#!/usr/bin/env bash
# Mock docker CLI for ensure-boot unit tests.
#
# contract:
#   docker info | ps | stop  → exit 0
#
# consumers: test_ensure_boot_exit
set -euo pipefail

cmd="${1:-}"
shift || true

case "${cmd}" in
  info|ps|stop)
    exit 0
    ;;
esac
exit 0
