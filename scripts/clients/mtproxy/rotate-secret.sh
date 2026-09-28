#!/usr/bin/env bash
# Generate new MTPROXY_SECRET in .data/.env (requires make refresh-full).
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/mtproxy-common.sh
source "${SCRIPT_DIR}/../../lib/mtproxy-common.sh"

if [[ -n "${MTPROXY_TEST_ROOT:-}" ]]; then
  ENV_FILE="${MTPROXY_TEST_ROOT}/.env"
fi

mtproxy_require_enabled

NEW_SECRET="$(openssl rand -hex 16)"
if grep -q '^MTPROXY_SECRET=' "${ENV_FILE}"; then
  sed -i "s|^MTPROXY_SECRET=.*|MTPROXY_SECRET=${NEW_SECRET}|" "${ENV_FILE}"
else
  printf 'MTPROXY_SECRET=%s\n' "${NEW_SECRET}" >> "${ENV_FILE}"
fi
chmod 600 "${ENV_FILE}"

echo "[mtproxy-rotate-secret] updated MTPROXY_SECRET in ${ENV_FILE}"
echo "  new secret (masked): $(mtproxy_mask_secret "${NEW_SECRET}")"
echo ""
echo "Next: make build && make refresh-full"
echo "Then: make mtproxy-export NAME=<name> FORCE=1"
echo "Clients must update proxy settings — old secret stops working."
