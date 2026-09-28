#!/usr/bin/env bash
# Mock ip for unit tests.
#
# contract:
#   ip route show <prefix>
#   ip route del <subnet> via <gw> dev <dev>
#
# env:
#   IP_MOCK_ROUTES — one full route line per line
#
# consumers: test_host_network_remove, test_host_remove_integration
set -euo pipefail

routes="${IP_MOCK_ROUTES:?IP_MOCK_ROUTES not set}"
touch "${routes}"

case "${1:-}" in
  route)
    case "${2:-}" in
      show)
        prefix="${3:-}"
        if [[ -n "${prefix}" ]]; then
          grep "${prefix}" "${routes}" 2>/dev/null || true
        else
          cat "${routes}" 2>/dev/null || true
        fi
        ;;
      del)
        shift 2
        # ip route del 10.8.0.0/24 via 172.20.0.3 dev br-abc
        subnet="" via="" dev=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            via) via="$2"; shift 2 ;;
            dev) dev="$2"; shift 2 ;;
            *) subnet="$1"; shift ;;
          esac
        done
        pat="${subnet} via ${via} dev ${dev}"
        grep -vxF "${pat}" "${routes}" > "${routes}.tmp" 2>/dev/null || true
        mv -f "${routes}.tmp" "${routes}"
        ;;
      *)
        echo "ip-mock: unsupported route subcommand: $*" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "ip-mock: unsupported: $*" >&2
    exit 2
    ;;
esac
