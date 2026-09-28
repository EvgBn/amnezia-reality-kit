#!/usr/bin/env bash
# Runtime smoke: MTProxy link + TCP + stats (requires running vpn-teleproxy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/mtproxy-common.sh
source "${SCRIPT_DIR}/../lib/mtproxy-common.sh"
# shellcheck source=../lib/mtproxy-smoke.sh
source "${SCRIPT_DIR}/../lib/mtproxy-smoke.sh"

[[ -f "${ENV_FILE}" ]] || {
  echo "[verify-mtproxy-smoke] ERROR: ${ENV_FILE} missing — run make create-data" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ "$(parse_bool "${ENABLE_MTPROXY:-}" 0)" != "1" ]]; then
  echo "[verify-mtproxy-smoke] OK — ENABLE_MTPROXY=0 (skipped)"
  exit 0
fi

mtproxy_smoke_run || exit 1
