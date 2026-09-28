#!/usr/bin/env bash
# Unit test verify-inbound-config.sh against temp .data fixtures.
# Matrix aligned with docs/PORT-443.md (website on :443 vs VLESS inbound).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
VERIFY="${REPO_ROOT}/scripts/maintenance/verify-inbound-config.sh"
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
    COMPOSE_FILE="${TMP}/build/docker-compose.yml" XRAY_CONF="${TMP}/build/config.json" \
    bash "${VERIFY}"
}

expect_verify_ok() {
  local label="$1"
  local out
  if ! out="$(run_verify 2>&1)"; then
    echo "${out}" >&2
    fail "expected OK: ${label}"
  fi
  echo "  OK: ${label} — ${out#\[verify-inbound\] }"
}

expect_verify_fail() {
  local label="$1"
  local needle="${2:-}"
  local out rc=0
  out="$(run_verify 2>&1)" || rc=$?
  [[ "${rc}" -eq 1 ]] || { echo "${out}" >&2; fail "expected fail: ${label} (exit ${rc})"; }
  if [[ -n "${needle}" && "${out}" != *"${needle}"* ]]; then
    echo "${out}" >&2
    fail "expected fail message containing '${needle}': ${label}"
  fi
  echo "  OK expected fail: ${label}"
}

load_case() {
  fixture_load_case verify-inbound "$1" "${TMP}"
}

load_case disabled-socks-loopback
expect_verify_ok "inbound disabled — no vless, loopback SOCKS only"

load_case enabled-vless-8443
expect_verify_ok "inbound enabled on 8443"

load_case enabled-vless-443
expect_verify_ok "inbound enabled on 443"

load_case fail-stale-compose-443
expect_verify_fail "stale compose publishes :443 while inbound disabled" \
  "xray service publishes public TCP"

load_case ok-disabled-with-mtproxy-8444
expect_verify_ok "inbound disabled with MTProxy on 8444 (not xray)"

load_case fail-stale-vless-config
expect_verify_fail "stale vless inbound while ENABLE_XRAY_INBOUND=0" \
  "vless inbound present"

echo "OK: test_verify_inbound"
