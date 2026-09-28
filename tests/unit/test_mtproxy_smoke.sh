#!/usr/bin/env bash
# Unit tests for mtproxy-smoke.sh (mocked docker/curl/TCP).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
SMOKE_SH="${REPO_ROOT}/scripts/lib/mtproxy-smoke.sh"
COMMON_SH="${REPO_ROOT}/scripts/lib/mtproxy-common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
fixture_use_docker_mock
export DOCKER_MOCK_PS='vpn-teleproxy'
export DOCKER_MOCK_EXTERNAL_PORT='8444'

# shellcheck source=../../scripts/lib/paths.sh
source "${REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

export MTPROXY_TEST_ROOT="${TMP}"
export DATA_DIR="${TMP}"
export ENV_FILE="${TMP}/.env"
export REPO_ROOT
mkdir -p "${TMP}/clients_mtproxy"
cat > "${TMP}/.env" <<'EOF'
ENABLE_MTPROXY=1
MTPROXY_MODE=standalone
MTPROXY_HOST_PORT=8444
MTPROXY_CONTAINER_PORT=443
MTPROXY_STATS_PORT=8888
TELEPROXY_VERSION=4.12.0
IN_SERVER_IP=198.51.100.10
MTPROXY_EE_DOMAIN=www.google.com
EOF

curl() {
  if [[ "$1" == "-sf" && "$3" == http://127.0.0.1:8888/stats ]]; then
    return 0
  fi
  command curl "$@"
}

_mtproxy_smoke_tcp_probe() { return 0; }

# shellcheck source=../../scripts/lib/mtproxy-common.sh
source "${COMMON_SH}"
# shellcheck source=../../scripts/lib/mtproxy-smoke.sh
source "${SMOKE_SH}"

export -f docker curl _mtproxy_smoke_tcp_probe

LINK='tg://proxy?server=198.51.100.10&port=8444&secret=ee0123456789abcdef0123456789abcdef'
out="$(mtproxy_smoke_run "${LINK}")" || fail "smoke should pass with mocks"
[[ "${out}" == *"[mtproxy-smoke] OK"* ]] || fail "expected OK line: ${out}"

# Wrong port → fail
bad='tg://proxy?server=198.51.100.10&port=443&secret=ee0123456789abcdef0123456789abcdef'
mtproxy_smoke_run "${bad}" 2>/dev/null && fail "wrong port should fail"

echo "OK: test_mtproxy_smoke"
