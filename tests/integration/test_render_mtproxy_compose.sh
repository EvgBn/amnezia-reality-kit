#!/usr/bin/env bash
# Ensure render-config bakes MTProxy/Teleproxy vars into docker-compose.yml (no runtime ${...}).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
RENDER="${REPO_ROOT}/scripts/setup/render-config.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

DATA_DIR="${TMP}/data"
BUILD_DIR="${DATA_DIR}/build"
ENV_FILE="${DATA_DIR}/.env"
export DATA_DIR BUILD_DIR ENV_FILE AWG_CONF="${BUILD_DIR}/awg0.conf" XRAY_CONF="${BUILD_DIR}/config.json"
COMPOSE="${BUILD_DIR}/docker-compose.yml"

mkdir -p "${BUILD_DIR}"
fixture_copy_data awg/awg0-with-peer.conf "${AWG_CONF}"
fixture_copy_data env/render-out-exit-v4.env "${ENV_FILE}"
cat >> "${ENV_FILE}" <<'EOF'
ENABLE_MTPROXY=1
MTPROXY_MODE=standalone
TELEPROXY_VERSION=4.12.0
MTPROXY_SECRET=ee0123456789abcdef0123456789abcdef
MTPROXY_EE_DOMAIN=example.com
MTPROXY_PUBLISH=0.0.0.0
MTPROXY_HOST_PORT=8444
MTPROXY_CONTAINER_PORT=443
MTPROXY_STATS_PORT=8888
MTPROXY_DIRECT_MODE=true
MTPROXY_WORKERS=1
MTPROXY_DC_PROBE_INTERVAL=30
MTPROXY_MEM_LIMIT=128m
EOF

chmod +x "${RENDER}"
bash "${RENDER}" --no-backup >/dev/null

[[ -f "${COMPOSE}" ]] || fail "compose not rendered"

for var in TELEPROXY_IP TELEPROXY_IPV6 IN_INGRESS_ADDR MTPROXY_SOCKS5_PROXY; do
  grep -q "\${${var}}" "${COMPOSE}" && fail "compose still contains unset placeholder \${${var}}"
done

grep -q 'ipv4_address: 10\.200\.97\.5' "${COMPOSE}" || fail "teleproxy ipv4 not baked"
grep -q 'SOCKS5_PROXY: socks5://' "${COMPOSE}" || fail "MTPROXY_SOCKS5_PROXY not baked"
grep -q '0\.0\.0\.0:8444:443/tcp' "${COMPOSE}" || fail "standalone publish missing"

echo "OK: test_render_mtproxy_compose"
