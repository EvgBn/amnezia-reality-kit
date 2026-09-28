#!/usr/bin/env bash
# Export current Telegram MTProxy link from vpn-teleproxy to .data/clients_mtproxy/<name>.txt
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/mtproxy-common.sh
source "${SCRIPT_DIR}/../../lib/mtproxy-common.sh"
# shellcheck source=../../lib/mtproxy-smoke.sh
source "${SCRIPT_DIR}/../../lib/mtproxy-smoke.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <name>" >&2
  exit 1
fi

readonly CLIENT_NAME="$1"
validate_client_name "${CLIENT_NAME}"

if [[ -n "${MTPROXY_TEST_ROOT:-}" ]]; then
  MTPROXY_CLIENTS_DIR="${MTPROXY_TEST_ROOT}/clients_mtproxy"
  ENV_FILE="${MTPROXY_TEST_ROOT}/.env"
fi

mtproxy_require_enabled
mkdir -p "${MTPROXY_CLIENTS_DIR}"
chmod 700 "${MTPROXY_CLIENTS_DIR}" 2>/dev/null || true

OUT_FILE="$(mtproxy_client_path "${CLIENT_NAME}")"
if [[ -f "${OUT_FILE}" && "${FORCE:-0}" != "1" ]]; then
  log_error "Export file already exists: ${OUT_FILE} (set FORCE=1 to overwrite)"
  exit 1
fi

LINK="$(mtproxy_resolve_link)"
SERVER="$(mtproxy_parse_link_field "${LINK}" server)"
PORT="$(mtproxy_parse_link_field "${LINK}" port)"
SECRET="$(mtproxy_parse_link_field "${LINK}" secret)"

{
  echo "# MTProxy export — ${CLIENT_NAME}"
  echo "# saved: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# mode: ${MTPROXY_MODE:-standalone}"
  echo ""
  echo "LINK=${LINK}"
  echo "SERVER=${SERVER}"
  echo "PORT=${PORT}"
  echo "SECRET=${SECRET}"
} > "${OUT_FILE}"
chmod 600 "${OUT_FILE}"

echo "[mtproxy-export] saved ${OUT_FILE}"
echo "  server: ${SERVER}"
echo "  port:   ${PORT}"
echo "  secret: $(mtproxy_mask_secret "${SECRET}")"
echo "  link:   ${LINK}"

if [[ "$(parse_bool "${SKIP_MTPROXY_SMOKE:-}" 0)" != "1" ]]; then
  echo "[mtproxy-export] running ingress smoke..."
  mtproxy_smoke_run "${LINK}" || {
    log_error "Smoke failed — fix issues above or export with SKIP_MTPROXY_SMOKE=1"
    exit 1
  }
fi
