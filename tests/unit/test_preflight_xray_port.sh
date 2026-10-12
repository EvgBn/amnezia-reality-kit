#!/usr/bin/env bash
# Unit tests for preflight xray inbound port policy (phase 7) — mocked ss/docker.
set -euo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${_LIB}/preflight.sh"
# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
fixture_use_docker_mock
fixture_use_ss_mock

PREFLIGHT_STRICT=0
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"; fixture_teardown' EXIT

# shellcheck source=../../scripts/preflight/lib/emit.sh
source "${REPO_ROOT}/scripts/preflight/lib/emit.sh"
preflight_init_colors
preflight_test_bootstrap
# shellcheck source=../../scripts/preflight/lib/probes.sh
source "${REPO_ROOT}/scripts/preflight/lib/probes.sh"
# shellcheck source=../../scripts/preflight/lib/network.sh
source "${REPO_ROOT}/scripts/preflight/lib/network.sh"

fixture_source_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
  fi
}

run_xray_port() {
  unset ENABLE_XRAY_INBOUND XRAY_INBOUND_PORT
  fixture_source_env_file
  preflight_check_xray_inbound_port
}

export REPO_ROOT COMPOSE_FILE="${REPO_ROOT}/.data/build/docker-compose.yml"

# 1 — no .env (unkp bootstrap)
export ENV_FILE="${TMP}/missing.env"
export SS_MOCK_PORTS='tcp:443'
export SS_MOCK_PROCESS_tcp_443='nginx'
unset DOCKER_MOCK_PS
preflight_expect_skips 1 "skip without .env" run_xray_port
preflight_capture_has SKIP "xray-inbound-policy" || fail "expected SKIP xray-inbound-policy"

# 2 — website profile (IN-1)
printf 'ENABLE_XRAY_INBOUND=0\n' > "${TMP}/website.env"
export ENV_FILE="${TMP}/website.env"
preflight_expect_no_fails "inbound disabled + nginx on 443" run_xray_port

# 3 — inbound=1 conflicts with nginx
printf 'ENABLE_XRAY_INBOUND=1\nXRAY_INBOUND_PORT=443\n' > "${TMP}/inbound.env"
export ENV_FILE="${TMP}/inbound.env"
unset DOCKER_MOCK_PS
preflight_expect_fails 1 "inbound=1 vs nginx" run_xray_port
preflight_capture_has FAIL "ENABLE_XRAY_INBOUND=0" || fail "expected PORT-443 style fix hint"

export SS_MOCK_PROCESS_tcp_443='caddy'
preflight_expect_fails 1 "inbound=1 vs caddy" run_xray_port
preflight_capture_has FAIL "ENABLE_XRAY_INBOUND=0" || fail "expected PORT-443 hint for caddy"

# 4 — inbound=1, vpn-xray holds port
export DOCKER_MOCK_PS='vpn-xray'
export SS_MOCK_PROCESS_tcp_443='docker-proxy'
preflight_expect_no_fails "inbound=1 + vpn-xray" run_xray_port

# 5 — stale: inbound=0 but xray still on 443
export ENV_FILE="${TMP}/website.env"
export DOCKER_MOCK_PS='vpn-xray'
preflight_expect_fails 1 "stale xray on 443 with inbound=0" run_xray_port

echo "OK: test_preflight_xray_port"
