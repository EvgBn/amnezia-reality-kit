#!/usr/bin/env bash
# Unit test verify-sni-443.sh skip path and sni env validation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
VERIFY="${REPO_ROOT}/scripts/maintenance/verify-sni-443.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

mkdir -p "${TMP}/build"
chmod +x "${VERIFY}" "${REPO_ROOT}/scripts/maintenance/verify-inbound-config.sh" \
  "${REPO_ROOT}/scripts/maintenance/verify-mtproxy-config.sh"

fixture_copy_data env/standalone-skip.env "${TMP}/.env"
fixture_copy_data compose/xray-socks-only.yml "${TMP}/build/docker-compose.yml"
fixture_copy_data json/xray-socks-only.json "${TMP}/build/config.json"

out="$(DATA_DIR="${TMP}" ENV_FILE="${TMP}/.env" BUILD_DIR="${TMP}/build" \
  COMPOSE_FILE="${TMP}/build/docker-compose.yml" XRAY_CONF="${TMP}/build/config.json" \
  bash "${VERIFY}")"
[[ "${out}" == *"skipped"* ]] || fail "expected skip for standalone"

fixture_copy_data env/sni-mode.env "${TMP}/.env"
fixture_copy_data compose/verify-sni-sni-mode.yml "${TMP}/build/docker-compose.yml"
fixture_copy_data json/xray-inbound-sni.json "${TMP}/build/config.json"
fixture_copy_data nginx/sni-map-verify-good.conf "${TMP}/nginx-good.conf"

NGINX_STREAM_SNIPPET="${TMP}/nginx-good.conf" \
  DATA_DIR="${TMP}" ENV_FILE="${TMP}/.env" BUILD_DIR="${TMP}/build" \
  COMPOSE_FILE="${TMP}/build/docker-compose.yml" XRAY_CONF="${TMP}/build/config.json" \
  bash "${VERIFY}" >/dev/null 2>&1 || fail "expected OK with good nginx map"

out="$(NGINX_STREAM_SNIPPET="${TMP}/missing-nginx.conf" \
  DATA_DIR="${TMP}" ENV_FILE="${TMP}/.env" BUILD_DIR="${TMP}/build" \
  COMPOSE_FILE="${TMP}/build/docker-compose.yml" XRAY_CONF="${TMP}/build/config.json" \
  bash "${VERIFY}" 2>&1)" || true
[[ "${out}" == *"snippet missing"* ]] || fail "expected warn for missing nginx snippet: ${out}"

echo "OK: test_verify_sni"
