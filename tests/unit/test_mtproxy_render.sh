#!/usr/bin/env bash
# Unit tests for ENABLE_MTPROXY compose post-process + marker stripping.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_SH="${REPO_ROOT}/scripts/setup/apply-compose-mtproxy.sh"
TMPL="${REPO_ROOT}/config/templates/docker-compose.yml.tmpl"
fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

chmod +x "${COMPOSE_SH}"

render_base() {
  export TELEPROXY_VERSION=4.11.0 TELEPROXY_IP=10.200.97.5 TELEPROXY_IPV6=fd87:172:20::5
  export IN_INGRESS_ADDR=198.51.100.10 MTPROXY_SECRET= MTPROXY_EE_DOMAIN=example.com
  export MTPROXY_CONTAINER_PORT=443 MTPROXY_EXTERNAL_PORT=8444 MTPROXY_STATS_PORT=8888
  export MTPROXY_DIRECT_MODE=true MTPROXY_SOCKS5_PROXY=socks5://u:p@10.200.97.4:1080
  export MTPROXY_CONFIG_DOWNLOAD_PROXY=socks5://u:p@10.200.97.4:1080
  export MTPROXY_WORKERS=1 MTPROXY_DC_PROBE_INTERVAL=30 MTPROXY_MEM_LIMIT=128m
  export LOG_MAX_SIZE=5m LOG_MAX_FILE=2
  export XRAY_IMAGE=teddysun/xray:26.6.27 COREDNS_IMAGE=coredns:1.11.1
  ENVSUBST_VARS="$(python3 "${REPO_ROOT}/scripts/setup/collect-envsubst-vars.py" "${TMPL}")"
  # shellcheck disable=SC2086
  envsubst "${ENVSUBST_VARS}" < "${TMPL}" > "${TMP}/docker-compose.yml"
}

export AWG_PORT=58285 AWG_TOOLS_REF=abc AMNEZIAWG_RELEASE=latest
export AMNEZIAWG_IP=10.200.97.3 AMNEZIAWG_IPV6=fd87:172:20::3
export COREDNS_IP=10.200.97.2 COREDNS_IPV6=fd87:172:20::2
export XRAY_IP=10.200.97.4 XRAY_IPV6=fd87:172:20::4
export IPT2SOCKS_NOFILE_LIMIT=8192 AMNEZIAWG_MEM_LIMIT=512m COREDNS_MEM_LIMIT=256m
export DOCKER_NETWORK_SUBNET_IPV4=10.200.97.0/24 DOCKER_NETWORK_GATEWAY_IPV4=10.200.97.1
export DOCKER_NETWORK_SUBNET_IPV6=fd87:172:20::/64 DOCKER_NETWORK_GATEWAY_IPV6=fd87:172:20::1

render_base
render_compose "${TMP}/docker-compose.yml" "teleproxy,teleproxy-data" > "${TMP}/docker-compose.stripped.yml"
mv "${TMP}/docker-compose.stripped.yml" "${TMP}/docker-compose.yml"
grep -q 'vpn-teleproxy' "${TMP}/docker-compose.yml" && fail "teleproxy should be stripped when disabled"
grep -q 'teleproxy-data' "${TMP}/docker-compose.yml" && fail "teleproxy volume should be stripped when disabled"

render_base
ENABLE_MTPROXY=1 MTPROXY_MODE=standalone MTPROXY_PUBLISH=0.0.0.0 MTPROXY_HOST_PORT=8444 \
  MTPROXY_CONTAINER_PORT=443 MTPROXY_STATS_PORT=8888 \
  bash "${COMPOSE_SH}" "${TMP}/docker-compose.yml"
grep -q 'vpn-teleproxy' "${TMP}/docker-compose.yml" || fail "teleproxy missing when enabled"
grep -q '0.0.0.0:8444:443/tcp' "${TMP}/docker-compose.yml" || fail "standalone publish missing"
grep -q '127.0.0.1:8888:8888/tcp' "${TMP}/docker-compose.yml" || fail "stats publish missing"

render_base
ENABLE_MTPROXY=1 MTPROXY_MODE=sni MTPROXY_PUBLISH=127.0.0.1 MTPROXY_HOST_PORT=8444 \
  MTPROXY_CONTAINER_PORT=443 MTPROXY_STATS_PORT=8888 \
  bash "${COMPOSE_SH}" "${TMP}/docker-compose.yml"
grep -q '127.0.0.1:8444:443/tcp' "${TMP}/docker-compose.yml" || fail "sni loopback publish missing"

render_base
ENABLE_MTPROXY=1 MTPROXY_MODE=sni MTPROXY_PUBLISH=0.0.0.0 MTPROXY_HOST_PORT=8444 \
  MTPROXY_CONTAINER_PORT=443 MTPROXY_STATS_PORT=8888 \
  bash "${COMPOSE_SH}" "${TMP}/docker-compose.yml" 2>/dev/null && fail "sni with 0.0.0.0 publish should fail"

echo "OK: test_mtproxy_render"
