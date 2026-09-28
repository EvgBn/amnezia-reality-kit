#!/usr/bin/env bash
# Mock docker compose for ensure-boot unit tests.
#
# contract:
#   docker compose up -d --wait  (fails when ENSURE_COMPOSE_FAIL=1)
#
# env:
#   ENSURE_COMPOSE_FAIL — 1 → exit 1 on up --wait
#
# consumers: test_ensure_boot_exit
set -euo pipefail

if [[ "${ENSURE_COMPOSE_FAIL:-0}" == "1" ]]; then
  case "$*" in
    *"up -d --wait"*) exit 1 ;;
  esac
fi
exit 0
