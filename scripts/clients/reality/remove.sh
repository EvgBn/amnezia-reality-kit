#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/reality-common.sh
source "${SCRIPT_DIR}/../../lib/reality-common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <client_name>" >&2
  exit 1
fi

readonly CLIENT_NAME="$1"
validate_client_name "${CLIENT_NAME}"

readonly VLESS_FILE
VLESS_FILE="$(reality_vless_path "${CLIENT_NAME}")"
readonly REMOVE_CLIENT="${SCRIPT_DIR}/remove-client.py"

load_env
xray_require_container

if [[ ! -f "${XRAY_CONF}" ]]; then
  log_error "Missing ${XRAY_CONF}."
  exit 1
fi

RC=0
(
  flock -x 200 || { log_error "Could not acquire lock on ${XRAY_CONF}"; exit 1; }

  XR_CLIENT="${CLIENT_NAME}" XR_CONFIG="${XRAY_CONF}" python3 "${REMOVE_CLIENT}" || exit

  xray_restart || { log_error "Failed to restart ${XRAY_CONTAINER}"; exit 1; }
) 200>"${XRAY_LOCK}" || RC=$?

if [[ "${RC}" -eq 3 ]]; then
  if [[ ! -f "${VLESS_FILE}" ]]; then
    log_error "Client '${CLIENT_NAME}' not found (not in ${XRAY_CONF}, no ${VLESS_FILE})."
    exit 1
  fi
  log_warn "Client '${CLIENT_NAME}' not in ${XRAY_CONF} — removing export only."
elif [[ "${RC}" -ne 0 ]]; then
  log_error "Failed to update ${XRAY_CONF} (exit ${RC})."
  exit "${RC}"
fi

rm -f "${VLESS_FILE}"

log_info "Client '${CLIENT_NAME}' removed."
