#!/usr/bin/env bash
# Unit tests for preflight phase 11 MTProxy (mocked).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${_LIB}/preflight.sh"
# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
fixture_use_docker_mock

export REPO_ROOT ENV_FILE="${REPO_ROOT}/.data/.env" COMPOSE_FILE="${REPO_ROOT}/.data/build/docker-compose.yml"

# shellcheck source=../../scripts/preflight/lib/emit.sh
source "${REPO_ROOT}/scripts/preflight/lib/emit.sh"
preflight_init_colors
preflight_test_bootstrap
# shellcheck source=../../scripts/preflight/lib/probes.sh
source "${REPO_ROOT}/scripts/preflight/lib/probes.sh"
# shellcheck source=../../scripts/preflight/lib/stack.sh
source "${REPO_ROOT}/scripts/preflight/lib/stack.sh"
# shellcheck source=../../scripts/preflight/lib/env.sh
source "${REPO_ROOT}/scripts/preflight/lib/env.sh"
# shellcheck source=../../scripts/preflight/lib/mtproxy.sh
source "${REPO_ROOT}/scripts/preflight/lib/mtproxy.sh"
# shellcheck source=../../scripts/preflight/phases/11-mtproxy.sh
source "${REPO_ROOT}/scripts/preflight/phases/11-mtproxy.sh"

run_phase() {
  preflight_phase_11_mtproxy
}

# disabled — skip
ENABLE_MTPROXY=0
export DOCKER_MOCK_PS=''
preflight_expect_skips 1 "phase 11 skip when disabled" run_phase

# disabled — stale container
ENABLE_MTPROXY=0
export DOCKER_MOCK_PS='vpn-teleproxy'
preflight_expect_warns 1 "phase 11 stale warn" run_phase

# stack list — always 3 core containers (no emit)
names=()
ENABLE_MTPROXY=1
preflight_stack_containers_expected names
[[ "${#names[@]}" -eq 3 ]] || fail "expected 3 core stack containers"
echo "ok stack expects 3 containers only"

echo "OK: test_preflight_mtproxy_phase"
