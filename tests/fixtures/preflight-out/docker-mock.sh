#!/usr/bin/env bash
# Thin wrapper: OUT phase exec ping → common/docker-mock.sh.
#
# contract:
#   docker exec vpn-xray sh -c 'ping…'  (OUT_MOCK_PING_RC)
#   other docker subcommands → common/docker-mock.sh
#
# env:
#   OUT_MOCK_PING_RC — exit code for ping exec probes
#
# consumers: test_preflight_out
set -euo pipefail

_common="$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/docker-mock.sh"

case "${1:-}" in
  exec)
    if [[ "$*" == *ping* ]]; then
      export DOCKER_MOCK_PING_RC="${OUT_MOCK_PING_RC:-0}"
      exec "${_common}" exec "$@"
    fi
    ;;
esac

exec "${_common}" "$@"
