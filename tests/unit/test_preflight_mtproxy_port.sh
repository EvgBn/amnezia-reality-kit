#!/usr/bin/env bash
# Unit tests for preflight MTProxy port probes (mocked ss/docker) — phase 11.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${_LIB}/preflight.sh"
# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
fixture_use_docker_mock
fixture_use_ss_mock

export REPO_ROOT ENV_FILE="${REPO_ROOT}/.data/.env" COMPOSE_FILE="${REPO_ROOT}/.data/build/docker-compose.yml"
PREFLIGHT_STRICT=0

# shellcheck source=../../scripts/preflight/lib/emit.sh
source "${REPO_ROOT}/scripts/preflight/lib/emit.sh"
preflight_init_colors
preflight_test_bootstrap
# shellcheck source=../../scripts/preflight/lib/probes.sh
source "${REPO_ROOT}/scripts/preflight/lib/probes.sh"
# shellcheck source=../../scripts/preflight/lib/network.sh
source "${REPO_ROOT}/scripts/preflight/lib/network.sh"
# shellcheck source=../../scripts/preflight/lib/mtproxy.sh
source "${REPO_ROOT}/scripts/preflight/lib/mtproxy.sh"

run_port_check() {
  ENABLE_MTPROXY=1
  preflight_check_mtproxy_port
}

# standalone enabled — teleproxy on 8444
MTPROXY_MODE=standalone MTPROXY_HOST_PORT=8444 MTPROXY_PUBLISH=0.0.0.0
export SS_MOCK_PORTS='tcp:8444'
export SS_MOCK_PROCESS_tcp_8444='vpn-teleproxy'
export DOCKER_MOCK_PS='vpn-teleproxy'
preflight_expect_no_fails "standalone 8444 held by teleproxy" run_port_check

# standalone — must not bind public :443 (two probe FAILs)
MTPROXY_MODE=standalone MTPROXY_HOST_PORT=443 MTPROXY_PUBLISH=0.0.0.0
export SS_MOCK_PORTS='tcp:443'
export SS_MOCK_PROCESS_tcp_443='vpn-teleproxy'
export DOCKER_MOCK_PS='vpn-teleproxy'
preflight_expect_fails 2 "standalone public :443" run_port_check

fixture_teardown
echo "OK: test_preflight_mtproxy_port"
