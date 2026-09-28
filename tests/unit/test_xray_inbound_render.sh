#!/usr/bin/env bash
# Unit tests for ENABLE_XRAY_INBOUND render helpers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPLY="${REPO_ROOT}/scripts/setup/apply-xray-inbound.py"
COMPOSE_SH="${REPO_ROOT}/scripts/setup/apply-compose-xray-ports.sh"
TMPL="${REPO_ROOT}/config/templates/config.json.tmpl"
fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

export XRAY_INBOUND_PORT=443 OUT_REALITY_PORT=443
export SOCKS_USER=u SOCKS_PASSWORD=p REALITY_DEST=x:443 REALITY_INBOUND_SERVER_NAME=apple.com
export REALITY_PRIVATE_KEY=k REALITY_SHORT_ID=sid
export OUT_EXIT_ADDRESS=2001:db8::1 OUT_EXIT_DOMAIN_STRATEGY=UseIPv6
export OUT_VLESS_UUID=uuid OUT_REALITY_PUBLIC_KEY=pk
export OUT_REALITY_SHORT_ID=s OUT_REALITY_SERVER_NAME=dl.google.com

envsubst '${SOCKS_USER} ${SOCKS_PASSWORD} ${REALITY_DEST} ${REALITY_INBOUND_SERVER_NAME} \
${REALITY_PRIVATE_KEY} ${REALITY_SHORT_ID} ${OUT_EXIT_ADDRESS} ${OUT_EXIT_DOMAIN_STRATEGY} ${OUT_VLESS_UUID} \
${OUT_REALITY_PUBLIC_KEY} ${OUT_REALITY_SHORT_ID} ${OUT_REALITY_SERVER_NAME} \
${XRAY_INBOUND_PORT} ${OUT_REALITY_PORT}' \
  < "${TMPL}" > "${TMP}/config.json"

ENABLE_XRAY_INBOUND=0 XRAY_INBOUND_PORT=443 OUT_REALITY_PORT=443 \
  python3 "${APPLY}" "${TMP}/config.json"

python3 -c "
import json
c=json.load(open('${TMP}/config.json'))
assert not any(ib.get('protocol')=='vless' for ib in c['inbounds']), 'vless should be removed'
exit_ob=next(ob for ob in c['outbounds'] if ob.get('tag')=='exit')
assert exit_ob['settings']['vnext'][0]['port']==443
assert exit_ob['settings']['vnext'][0]['address']=='2001:db8::1', 'exit address'
assert exit_ob['settings']['domainStrategy']=='UseIPv6', 'exit domainStrategy'
"

ENABLE_XRAY_INBOUND=1 XRAY_INBOUND_PORT=8443 OUT_REALITY_PORT=443 \
  envsubst '${SOCKS_USER} ${SOCKS_PASSWORD} ${REALITY_DEST} ${REALITY_INBOUND_SERVER_NAME} \
${REALITY_PRIVATE_KEY} ${REALITY_SHORT_ID} ${OUT_EXIT_ADDRESS} ${OUT_EXIT_DOMAIN_STRATEGY} ${OUT_VLESS_UUID} \
${OUT_REALITY_PUBLIC_KEY} ${OUT_REALITY_SHORT_ID} ${OUT_REALITY_SERVER_NAME} \
${XRAY_INBOUND_PORT} ${OUT_REALITY_PORT}' \
  < "${TMPL}" > "${TMP}/config.json"

ENABLE_XRAY_INBOUND=1 XRAY_INBOUND_PORT=8443 OUT_REALITY_PORT=443 \
  python3 "${APPLY}" "${TMP}/config.json"

python3 -c "
import json
c=json.load(open('${TMP}/config.json'))
ib=next(x for x in c['inbounds'] if x.get('protocol')=='vless')
assert ib['port']==8443
"

cp "${REPO_ROOT}/config/templates/docker-compose.yml.tmpl" "${TMP}/docker-compose.yml"
chmod +x "${COMPOSE_SH}"
ENABLE_XRAY_INBOUND=0 bash "${COMPOSE_SH}" "${TMP}/docker-compose.yml"
grep -q '0.0.0.0:.*:.*tcp' "${TMP}/docker-compose.yml" && fail "compose should not publish inbound when disabled"

ENABLE_XRAY_INBOUND=1 XRAY_INBOUND_PORT=8443 bash "${COMPOSE_SH}" "${TMP}/docker-compose.yml"
grep -q '0.0.0.0:8443:8443/tcp' "${TMP}/docker-compose.yml" || fail "compose missing 8443 publish"

cp "${REPO_ROOT}/config/templates/docker-compose.yml.tmpl" "${TMP}/docker-compose-sni.yml"
ENABLE_XRAY_INBOUND=1 MTPROXY_MODE=sni XRAY_INBOUND_PORT=8443 bash "${COMPOSE_SH}" "${TMP}/docker-compose-sni.yml"
grep -q '127.0.0.1:8443:8443/tcp' "${TMP}/docker-compose-sni.yml" || fail "sni compose missing loopback 8443"
grep -q '0.0.0.0:8443:8443/tcp' "${TMP}/docker-compose-sni.yml" && fail "sni compose must not publish 0.0.0.0:8443"

echo "OK: test_xray_inbound_render"
