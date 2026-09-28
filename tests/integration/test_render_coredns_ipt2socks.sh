#!/usr/bin/env bash
# Render ipt2socks-coredns.sh: COREDNS_IPT2SOCKS_PORT must survive envsubst (no shell PORT alias).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
RENDER="${REPO_ROOT}/scripts/setup/render-config.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

DATA_DIR="${TMP}/data"
BUILD_DIR="${DATA_DIR}/build"
ENV_FILE="${DATA_DIR}/.env"
IPT2SOCKS_COREDNS="${BUILD_DIR}/ipt2socks-coredns.sh"
export DATA_DIR BUILD_DIR ENV_FILE AWG_CONF="${BUILD_DIR}/awg0.conf" XRAY_CONF="${BUILD_DIR}/config.json"

mkdir -p "${BUILD_DIR}"
fixture_copy_data awg/awg0-with-peer.conf "${AWG_CONF}"
fixture_copy_data env/render-out-exit-v4.env "${ENV_FILE}"

# Regression: empty PORT in the environment used to blank ${PORT} during envsubst.
unset PORT
export PORT=

bash "${RENDER}" --no-backup >/dev/null

[[ -f "${IPT2SOCKS_COREDNS}" ]] || fail "missing ${IPT2SOCKS_COREDNS}"

grep -qF -- '-l "12347"' "${IPT2SOCKS_COREDNS}" || fail 'expected -l "12347" in ipt2socks-coredns.sh'
grep -qF -- '--to-port "12347"' "${IPT2SOCKS_COREDNS}" || fail 'expected --to-port "12347" in ipt2socks-coredns.sh'
grep -qF -- '--to-port ""' "${IPT2SOCKS_COREDNS}" && fail 'found empty --to-port in ipt2socks-coredns.sh'
grep -qF -- '-l ""' "${IPT2SOCKS_COREDNS}" && fail 'found empty -l in ipt2socks-coredns.sh'
grep -q '${' "${IPT2SOCKS_COREDNS}" && fail 'unexpanded ${...} placeholder in ipt2socks-coredns.sh'
grep -qF -- '${PORT}' "${IPT2SOCKS_COREDNS}" && fail 'stale ${PORT} placeholder in ipt2socks-coredns.sh'

echo "OK: test_render_coredns_ipt2socks"
