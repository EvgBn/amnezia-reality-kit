#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/awg-common.sh
source "${SCRIPT_DIR}/../../lib/awg-common.sh"

if [[ -n "${AWG_TEST_ROOT:-}" ]]; then
  AWG_CONF="${AWG_TEST_ROOT}/awg0.conf"
  AWG_CLIENTS_DIR="${AWG_TEST_ROOT}/clients_awg"
  ENV_FILE="${AWG_TEST_ROOT}/.env"
fi

load_env || true

if [[ ! -f "${AWG_CONF}" ]]; then
  log_error "Missing ${AWG_CONF}."
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "${AWG_CONTAINER}"; then
  export AWG_CONTAINER
else
  unset AWG_CONTAINER
fi

AWG_CONF="${AWG_CONF}" AWG_CLIENTS_DIR="${AWG_CLIENTS_DIR}" AWG_HIGHLIGHT_NAME="${AWG_HIGHLIGHT_NAME:-}" \
  python3 "${SCRIPT_DIR}/list-peers.py"
