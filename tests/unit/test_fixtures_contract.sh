#!/usr/bin/env bash
# Contract smoke tests for tests/fixtures (mocks + static data + manifest).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures"
COMMON="${FIXTURES}/common"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

require_contract_header() {
  local f="$1"
  grep -q '^# contract:' "${f}" || fail "missing contract header: ${f}"
}

# --- manifest paths exist ---
while IFS= read -r rel; do
  [[ -z "${rel}" ]] && continue
  [[ -f "${FIXTURES}/${rel}" ]] || fail "manifest path missing: ${rel}"
done < <(grep -E '^\s+- path:' "${FIXTURES}/manifest.yaml" | sed -E 's/^[[:space:]]+- path:[[:space:]]*//')

# --- every fixture file listed in manifest ---
while IFS= read -r f; do
  rel="${f#${FIXTURES}/}"
  grep -qF "path: ${rel}" "${FIXTURES}/manifest.yaml" || fail "manifest missing entry for: ${rel}"
done < <(find "${FIXTURES}" -type f ! -name manifest.yaml ! -name README.md)

# --- manifest consumers resolve to test files ---
while IFS= read -r consumer; do
  [[ -z "${consumer}" ]] && continue
  found=0
  for dir in unit integration guards; do
    if [[ -f "${REPO_ROOT}/tests/${dir}/${consumer}.sh" ]]; then
      found=1
      break
    fi
  done
  [[ "${found}" -eq 1 ]] || fail "manifest consumer not found: ${consumer}.sh"
done < <(grep -E '^\s+- test_' "${FIXTURES}/manifest.yaml" | sed -E 's/^[[:space:]]+- //')

# --- contract headers on all shell mocks ---
while IFS= read -r f; do
  require_contract_header "${f}"
done < <(find "${FIXTURES}" -name '*.sh' -type f | sort)

# --- docker-mock ---
DOCKER="${COMMON}/docker-mock.sh"
chmod +x "${DOCKER}"
export DOCKER_MOCK_PS='vpn-teleproxy'
export DOCKER_MOCK_EXTERNAL_PORT='8444'
export DOCKER_MOCK_LOGS_FILE="${TMP}/logs.txt"
printf 'ready\n' > "${DOCKER_MOCK_LOGS_FILE}"
out="$("${DOCKER}" ps --format '{{.Names}}')"
[[ "${out}" == *vpn-teleproxy* ]] || fail "docker-mock ps"
[[ "$("${DOCKER}" inspect --format '{{.State.Health.Status}}' vpn-teleproxy)" == "healthy" ]] \
  || fail "docker-mock health inspect"
"${DOCKER}" image inspect teleproxy:1.0 >/dev/null || fail "docker-mock image inspect"
[[ "$("${DOCKER}" logs vpn-teleproxy)" == *ready* ]] || fail "docker-mock logs"
export DOCKER_MOCK_PING_RC=0
"${DOCKER}" exec vpn-xray sh -c 'ping -c 1 127.0.0.1' >/dev/null || fail "docker-mock exec ping"

# --- docker trace mode ---
TRACE_LOG="${TMP}/docker-trace.log"
: > "${TRACE_LOG}"
export DOCKER_MOCK_COMMAND_LOG_FILE="${TRACE_LOG}"
export DOCKER_MOCK_TRACE_ONLY=1
"${DOCKER}" pull ghcr.io/example/img:1.0 >/dev/null
grep -q 'docker pull ghcr.io/example/img:1.0' "${TRACE_LOG}" || fail "docker trace log"
unset DOCKER_MOCK_TRACE_ONLY DOCKER_MOCK_COMMAND_LOG_FILE

# --- awg-docker-mock ---
AWG="${COMMON}/awg-docker-mock.sh"
chmod +x "${AWG}"
export DOCKER_MOCK_PS='vpn-amneziawg'
export DOCKER_MOCK_AWG_PUBKEY_MAP=$'SERVERKEY=SERVER_PUB\nDROP_PRIV=PUB_DROP'
export DOCKER_MOCK_AWG_DEFAULT_PUB=PUB
[[ "$("${AWG}" ps --format '{{.Names}}')" == *vpn-amneziawg* ]] || fail "awg-docker-mock ps"
pub="$({ printf '%s' SERVERKEY; } | "${AWG}" exec vpn-amneziawg awg pubkey)"
[[ "${pub}" == "SERVER_PUB" ]] || fail "awg-docker-mock pubkey map"
gen="$("${AWG}" exec vpn-amneziawg sh -c 'awg genkey')"
[[ "${gen}" == $'NEW_PRIV\nNEW_PUB' ]] || fail "awg-docker-mock genkey"

# --- ss-mock ---
SS="${COMMON}/ss-mock.sh"
chmod +x "${SS}"
export SS_MOCK_PORTS='tcp:8444,tcp:443'
export SS_MOCK_PROCESS_tcp_8444='vpn-teleproxy'
export SS_MOCK_PROCESS_tcp_443='vpn-teleproxy'
ss_out="$("${SS}" -Hltn)"
[[ "${ss_out}" == *':8444'* ]] || fail "ss-mock -Hltn"
ss_p_out="$("${SS}" -Hltnp)"
[[ "${ss_p_out}" == *'vpn-teleproxy'* ]] || fail "ss-mock -Hltnp"

# --- curl-mock ---
CURL="${COMMON}/curl-mock.sh"
chmod +x "${CURL}"
export OUT_MOCK_CURL_IP='198.51.100.20'
[[ "$("${CURL}" -sf http://example)" == "198.51.100.20" ]] || fail "curl-mock"
unset OUT_MOCK_CURL_IP
"${CURL}" -sf http://example 2>/dev/null && fail "curl-mock should fail when unset"

# --- openssl-mock ---
OPENSSL="${COMMON}/openssl-mock.sh"
chmod +x "${OPENSSL}"
export OPENSSL_MOCK_STATE_DIR="${TMP}/ossl"
mkdir -p "${OPENSSL_MOCK_STATE_DIR}"
export OPENSSL_MOCK_CN_MAP=$'www.google.com=www.google.com\ngoogle.com=*.google.com'
cert="$({ echo | "${OPENSSL}" s_client -connect 127.0.0.1:443 -servername www.google.com; } \
  | "${OPENSSL}" x509 -noout -subject)"
[[ "${cert}" == *"www.google.com"* ]] || fail "openssl-mock pipeline: ${cert}"

# --- fixture-env helpers ---
export DOCKER_MOCK_PS='vpn-teleproxy'
fixture_use_docker_mock
docker ps --format '{{.Names}}' | grep -qx vpn-teleproxy || fail "fixture_use_docker_mock pipeline"
fixture_teardown

# --- static data readable ---
[[ -f "$(fixture_data_path nginx/sni-map-good.conf)" ]] || fail "data nginx map"
[[ -f "$(fixture_data_path env/sni-mode.env)" ]] || fail "data env sni-mode"
[[ -d "$(fixture_data_path cases/verify-inbound/disabled-socks-loopback)" ]] || fail "verify-inbound case"
[[ -f "$(fixture_data_path awg/awg0-with-peer.conf)" ]] || fail "awg fixture"

echo "OK: test_fixtures_contract"
