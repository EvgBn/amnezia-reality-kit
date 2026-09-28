#!/usr/bin/env bash
# Unit tests for mtproxy export helper (mocked docker logs).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
EXPORT_SH="${REPO_ROOT}/scripts/clients/mtproxy/export.sh"
LIST_SH="${REPO_ROOT}/scripts/clients/mtproxy/list.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

chmod +x "${EXPORT_SH}" "${LIST_SH}"

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
fixture_use_docker_mock
export DOCKER_MOCK_PS='vpn-teleproxy'
export DOCKER_MOCK_EXTERNAL_PORT='8444'
cat > "${TMP}/teleproxy-logs.txt" <<'LOGS'
[teleproxy] ready
Connection Links:
https://t.me/proxy?server=198.51.100.10&port=443&secret=ee0123456789abcdef0123456789abcdef
LOGS
export DOCKER_MOCK_LOGS_FILE="${TMP}/teleproxy-logs.txt"

export MTPROXY_TEST_ROOT="${TMP}"
export DATA_DIR="${TMP}"
export ENV_FILE="${TMP}/.env"
mkdir -p "${TMP}/clients_mtproxy"
cat > "${TMP}/.env" <<'EOF'
ENABLE_MTPROXY=1
MTPROXY_MODE=standalone
MTPROXY_HOST_PORT=8444
EOF

curl() {
  if [[ "$1" == "-sf" && "$3" == http://127.0.0.1:8888/stats ]]; then
    return 0
  fi
  if [[ "$1" == "-sf" && "$2" == http://127.0.0.1:8888/ ]]; then
    return 1
  fi
  command curl "$@"
}

_mtproxy_smoke_tcp_probe() { return 0; }

export -f docker curl _mtproxy_smoke_tcp_probe
export REPO_ROOT

SKIP_MTPROXY_SMOKE=1 bash "${EXPORT_SH}" staging-main
[[ -f "${TMP}/clients_mtproxy/staging-main.txt" ]] || fail "export file not created"
grep -q 'tg://proxy?' "${TMP}/clients_mtproxy/staging-main.txt" || fail "missing tg link"
grep -q '^PORT=8444' "${TMP}/clients_mtproxy/staging-main.txt" || fail "missing PORT field"

bash "${EXPORT_SH}" staging-main 2>/dev/null && fail "duplicate without FORCE should fail"
FORCE=1 bash "${EXPORT_SH}" staging-main

out="$(bash "${LIST_SH}")"
[[ "${out}" == *"staging-main"* ]] || fail "list missing entry"

echo "OK: test_mtproxy_export"
