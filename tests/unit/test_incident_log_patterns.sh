#!/usr/bin/env bash
# Contract: incident grep patterns stay defined (scripts/lib/incident-udp-log-patterns.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/incident-udp-log-patterns.sh
source "${ROOT}/scripts/lib/incident-udp-log-patterns.sh"

[[ -n "${UDP_RELAY_GREP:-}" ]] || { echo "UDP_RELAY_GREP empty"; exit 1; }
[[ -n "${ASSOC_SNAPSHOT_GREP:-}" ]] || { echo "ASSOC_SNAPSHOT_GREP empty"; exit 1; }
[[ -n "${IPT2SOCKS_GREP:-}" ]] || { echo "IPT2SOCKS_GREP empty"; exit 1; }
[[ -n "${INCIDENT_AWG_INJECT_FAIL_GREP:-}" ]] || { echo "INCIDENT_AWG_INJECT_FAIL_GREP empty"; exit 1; }
[[ -n "${INCIDENT_AWG_IPT2SOCKS_CLIENT_TO_GREP:-}" ]] || {
  echo "INCIDENT_AWG_IPT2SOCKS_CLIENT_TO_GREP empty"
  exit 1
}

echo "ok incident log patterns"
