#!/usr/bin/env bash
# Unit test verify-mtproxy-config.sh against temp .data fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
VERIFY="${REPO_ROOT}/scripts/maintenance/verify-mtproxy-config.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

mkdir -p "${TMP}/build"
chmod +x "${VERIFY}"

run_verify() {
  DATA_DIR="${TMP}" ENV_FILE="${TMP}/.env" BUILD_DIR="${TMP}/build" \
    COMPOSE_FILE="${TMP}/build/docker-compose.yml" \
    bash "${VERIFY}"
}

expect_ok() {
  local label="$1"
  run_verify >/dev/null 2>&1 || fail "expected OK: ${label}"
  echo "  OK: ${label}"
}

expect_fail() {
  local label="$1" needle="${2:-}"
  local out rc=0
  out="$(run_verify 2>&1)" || rc=$?
  [[ "${rc}" -eq 1 ]] || { echo "${out}" >&2; fail "expected fail: ${label}"; }
  if [[ -n "${needle}" && "${out}" != *"${needle}"* ]]; then
    echo "${out}" >&2
    fail "expected needle '${needle}' in: ${label}"
  fi
  echo "  OK fail: ${label}"
}

fixture_copy_data env/disabled-mtproxy.env "${TMP}/.env"
fixture_copy_data compose/xray-socks-only.yml "${TMP}/build/docker-compose.yml"
expect_ok "disabled, no teleproxy"

fixture_copy_data env/enabled-standalone.env "${TMP}/.env"
fixture_copy_data compose/teleproxy-standalone.yml "${TMP}/build/docker-compose.yml"
expect_ok "enabled standalone"

fixture_copy_data env/disabled-mtproxy.env "${TMP}/.env"
fixture_copy_data compose/teleproxy-stale.yml "${TMP}/build/docker-compose.yml"
expect_fail "disabled but teleproxy present" "vpn-teleproxy present"

fixture_copy_data env/enabled-standalone.env "${TMP}/.env"
fixture_copy_data compose/xray-socks-only.yml "${TMP}/build/docker-compose.yml"
expect_fail "enabled but teleproxy missing" "vpn-teleproxy service missing"

echo "OK: test_verify_mtproxy"
