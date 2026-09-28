#!/usr/bin/env bash
# Remove host-level VPN stack artifacts (network route, firewall, conntrack drop-ins,
# /etc/vpn-bridge/env, AmneziaWG kernel module). Does not remove Docker images or .data/.
#
# Stack must be stopped first: make down (host-remove also removes the AWG host route).
# Does not revert net.ipv4.ip_forward in /etc/sysctl.conf (may be used by other services).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/host-network.sh
source "${SCRIPT_DIR}/../lib/host-network.sh"
# shellcheck source=../lib/host-remove-lib.sh
source "${SCRIPT_DIR}/../lib/host-remove-lib.sh"

if [[ "${EUID}" -ne 0 ]]; then
  log_error "Run as root: sudo $0"
  exit 1
fi

host_remove_run
