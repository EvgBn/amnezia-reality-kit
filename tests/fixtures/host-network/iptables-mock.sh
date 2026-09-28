#!/usr/bin/env bash
# Mock iptables for unit tests.
#
# contract:
#   iptables -C | -I | -D  (state file IPTABLES_MOCK_STATE)
#
# env:
#   IPTABLES_MOCK_STATE — one rule per line
#
# consumers: test_host_network_remove, test_host_remove_integration
set -euo pipefail

state="${IPTABLES_MOCK_STATE:?IPTABLES_MOCK_STATE not set}"
touch "${state}"

_rule_line() {
  printf '%s\n' "$*"
}

case "${1:-}" in
  -C)
    shift
    line="$(_rule_line "$@")"
    grep -qxF "${line}" "${state}"
    ;;
  -D)
    shift
    line="$(_rule_line "$@")"
    awk -v l="${line}" 'BEGIN{done=0} $0==l && done==0 {done=1; next} {print}' "${state}" > "${state}.tmp"
    mv -f "${state}.tmp" "${state}"
    ;;
  -I)
    shift
    _rule_line "$@" >> "${state}"
    ;;
  *)
    echo "iptables-mock: unsupported: $*" >&2
    exit 2
    ;;
esac
