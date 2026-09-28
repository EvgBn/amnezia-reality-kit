#!/usr/bin/env bash
# Remove AmneziaWG kernel module from the host (unload + boot units + .ko).
# Inverse of the kernel bits installed by sudo make deploy-host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/host-network.sh
source "${SCRIPT_DIR}/../lib/host-network.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/host-kmod-remove.sh
source "${SCRIPT_DIR}/../lib/host-kmod-remove.sh"

if [[ "${EUID}" -ne 0 ]]; then
  log_error "Run as root: sudo $0"
  exit 1
fi

kmod_remove_run
