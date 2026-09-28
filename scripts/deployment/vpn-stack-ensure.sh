#!/usr/bin/env bash
# Stable systemd ExecStart target — resolves repo from HOST_ENV_FILE (see install-ensure-wrapper.sh).
set -euo pipefail

readonly DEFAULT_HOST_ENV_FILE="/etc/vpn-bridge/env"
HOST_ENV_FILE="${HOST_ENV_FILE:-${DEFAULT_HOST_ENV_FILE}}"
readonly BOOT_REL="scripts/maintenance/vpn-stack-boot.sh"

if [[ ! -f "${HOST_ENV_FILE}" ]]; then
  echo "vpn-stack-ensure: ${HOST_ENV_FILE} missing — run: sudo make deploy-host" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${HOST_ENV_FILE}"

if [[ -z "${REPO_ROOT:-}" ]]; then
  echo "vpn-stack-ensure: REPO_ROOT unset in ${HOST_ENV_FILE}" >&2
  exit 1
fi

ensure_script="${REPO_ROOT}/${BOOT_REL}"
if [[ ! -x "${ensure_script}" ]]; then
  echo "vpn-stack-ensure: ${ensure_script} not found or not executable" >&2
  echo "vpn-stack-ensure: run sudo make deploy-host after moving the clone" >&2
  exit 1
fi

exec "${ensure_script}"
