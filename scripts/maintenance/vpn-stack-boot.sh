#!/usr/bin/env bash
# Boot-time guard invoked by vpn-stack-boot.service (installed by deploy-host.sh).
#
# 1. Ensure amneziawg.ko matches the running kernel (modprobe / rebuild).
# 2. Re-orchestrate the compose stack (depends_on is ignored on docker daemon restart).
# 3. Apply host AWG route when .data/ is deployed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/ensure-boot.sh
source "${SCRIPT_DIR}/../lib/ensure-boot.sh"

ensure_boot_run
