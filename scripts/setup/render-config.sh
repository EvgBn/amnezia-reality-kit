#!/usr/bin/env bash
# Render config/templates/* + .data/.env → .data/build/*
# Preserves AWG [Peer] blocks and VLESS clients from existing build files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/docker-network-plan.sh
source "${SCRIPT_DIR}/../lib/docker-network-plan.sh"

# coredns: rendered ipt2socks scripts must be executable (shebang scripts).
normalize_build_modes() {
  local f mode
  for f in \
    "${BUILD_DIR}/ipt2socks-amneziawg-v4.sh" \
    "${BUILD_DIR}/ipt2socks-amneziawg-v6.sh" \
    "${BUILD_DIR}/udp-relay-run.sh" \
    "${BUILD_DIR}/ipt2socks-coredns.sh"; do
    [[ -f "${f}" ]] || continue
    mode="$(stat -c '%a' "${f}" 2>/dev/null || echo '')"
    if [[ "${mode}" != "755" ]]; then
      chmod 755 "${f}"
      echo "[render-config] normalized ${f}: mode ${mode} → 755"
    fi
  done
}

remove_obsolete_build_artifacts() {
  local f base
  for f in "${BUILD_DIR}"/*.conf; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    [[ "${base}" == "awg0.conf" ]] && continue
    rm -f "${f}"
    echo "[render-config] removed obsolete build/${base}"
  done
  for f in \
    xray-tproxy.json \
    xray-tproxy-run.sh \
    ipt2socks-amneziawg-udp-v4.sh \
    ipt2socks-amneziawg-udp-v6.sh; do
    [[ -f "${BUILD_DIR}/${f}" ]] || continue
    rm -f "${BUILD_DIR}/${f}"
    echo "[render-config] removed obsolete build/${f}"
  done
}

DRY_RUN=0
DIFF=0
NO_BACKUP=0
EXTRACT_ENV=0
BOOTSTRAP=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  --extract-env   Populate .data/.env from .data/build/ (production migration)
  --bootstrap     Allow zero AWG peers (first-time create-data only)
  --dry-run       Write to temp dir only, do not modify .data/build/
  --diff          Implies --dry-run; show diff vs current build files
  --no-backup     Skip backup when applying (not recommended in prod)
  -h, --help      Show this help

Default: write to .data/build/ with backup; no container restart.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --extract-env) EXTRACT_ENV=1; shift ;;
    --bootstrap) BOOTSTRAP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --diff) DRY_RUN=1; DIFF=1; shift ;;
    --no-backup) NO_BACKUP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[render-config] unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ "$EXTRACT_ENV" -eq 1 ]]; then
  exec "${SCRIPT_DIR}/extract-env.sh"
fi

[[ -f "${ENV_FILE}" ]] || {
  echo "[render-config] ERROR: ${ENV_FILE} not found. Run: $0 --extract-env" >&2
  exit 1
}

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

docker_network_plan_resolve "${ENV_FILE}" || exit 1
echo "[render-config] docker bridge ${DOCKER_NETWORK_SUBNET_IPV4} → gateway ${DOCKER_NETWORK_GATEWAY_IPV4}, awg ${AMNEZIAWG_IP}, xray ${XRAY_IP}, teleproxy ${TELEPROXY_IP}"

# Legacy env keys (AMNEZIAWG_POD_* etc., pre-2026-09 rename) — only if plan left empty
AMNEZIAWG_IP="${AMNEZIAWG_IP:-${AMNEZIAWG_POD_IP:-}}"
AMNEZIAWG_IPV6="${AMNEZIAWG_IPV6:-${AMNEZIAWG_POD_IPV6:-}}"
COREDNS_IP="${COREDNS_IP:-${COREDNS_POD_IP:-}}"
COREDNS_IPV6="${COREDNS_IPV6:-${COREDNS_POD_IPV6:-}}"
XRAY_IP="${XRAY_IP:-${XRAY_POD_IP:-}}"
XRAY_IPV6="${XRAY_IPV6:-${XRAY_POD_IPV6:-}}"
AMNEZIAWG_MEM_LIMIT="${AMNEZIAWG_MEM_LIMIT:-${AMNEZIAWG_POD_MEM_LIMIT:-512m}}"
COREDNS_MEM_LIMIT="${COREDNS_MEM_LIMIT:-${COREDNS_POD_MEM_LIMIT:-256m}}"

# Legacy alias (old .env used REALITY_SERVER_NAME for OUT outbound SNI)
if [[ -z "${OUT_REALITY_SERVER_NAME:-}" && -n "${REALITY_SERVER_NAME:-}" ]]; then
  OUT_REALITY_SERVER_NAME="${REALITY_SERVER_NAME}"
fi

# shellcheck source=../lib/endpoint.sh
source "${SCRIPT_DIR}/../lib/endpoint.sh"
endpoint_resolve_env || exit 1

ENABLE_XRAY_INBOUND="$(parse_bool "${ENABLE_XRAY_INBOUND:-}" 1)"
XRAY_INBOUND_PORT="${XRAY_INBOUND_PORT:-443}"
OUT_REALITY_PORT="${OUT_REALITY_PORT:-443}"

# IPv6 ULA validated in docker-network-plan.py (RFC3849 rejected).
AWG_IPT2SOCKS_PORT="${AWG_IPT2SOCKS_PORT:-12345}"
AWG_IPT2SOCKS_PORT_IPV6="${AWG_IPT2SOCKS_PORT_IPV6:-12346}"
COREDNS_IPT2SOCKS_PORT="${COREDNS_IPT2SOCKS_PORT:-12347}"
COREDNS_UPSTREAM="${COREDNS_UPSTREAM:-tls://1.1.1.1}"
COREDNS_UPSTREAM_TLS_SNI="${COREDNS_UPSTREAM_TLS_SNI:-cloudflare-dns.com}"
XRAY_IMAGE="${XRAY_IMAGE:-teddysun/xray:26.6.27}"
COREDNS_IMAGE="${COREDNS_IMAGE:-coredns:1.11.1}"
AWG_UDP_RELAY_PORT="${AWG_UDP_RELAY_PORT:-12348}"
AWG_UDP_RELAY_PORT_IPV6="${AWG_UDP_RELAY_PORT_IPV6:-12349}"
AWG_NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-100}"
AWG_UDP_RELAY_LOG_LEVEL="${AWG_UDP_RELAY_LOG_LEVEL:-info}"
AWG_TUNNEL_GATEWAY_IPV4="${AWG_TUNNEL_GATEWAY_IPV4:-${AWG_TUNNEL_IPV4%%/*}}"
if [[ -z "${AWG_TUNNEL_SUBNET_IPV6:-}" && -n "${AWG_TUNNEL_IPV6:-}" ]]; then
  AWG_TUNNEL_SUBNET_IPV6="${AWG_TUNNEL_IPV6%/*}/$(echo "${AWG_TUNNEL_IPV6}" | cut -d/ -f2)"
fi
AWG_TUNNEL_SUBNET_IPV6="${AWG_TUNNEL_SUBNET_IPV6:-fd86:ea04:1115::/64}"
AWG_TUNNEL_GATEWAY_IPV6="${AWG_TUNNEL_GATEWAY_IPV6:-${AWG_TUNNEL_IPV6%%/*}}"
IPT2SOCKS_THREADS="${IPT2SOCKS_THREADS:-2}"
IPT2SOCKS_NOFILE_LIMIT="${IPT2SOCKS_NOFILE_LIMIT:-8192}"
IPT2SOCKS_UDP_TIMEOUT="${IPT2SOCKS_UDP_TIMEOUT:-60}"

export AWG_IPT2SOCKS_PORT AWG_IPT2SOCKS_PORT_IPV6 COREDNS_IPT2SOCKS_PORT \
  COREDNS_UPSTREAM COREDNS_UPSTREAM_TLS_SNI XRAY_IMAGE COREDNS_IMAGE \
  AWG_UDP_RELAY_PORT AWG_UDP_RELAY_PORT_IPV6 AWG_NFQUEUE_NUM AWG_UDP_RELAY_LOG_LEVEL \
  AWG_TUNNEL_GATEWAY_IPV4 AWG_TUNNEL_GATEWAY_IPV6 AWG_TUNNEL_SUBNET_IPV6 \
  IPT2SOCKS_THREADS IPT2SOCKS_NOFILE_LIMIT IPT2SOCKS_UDP_TIMEOUT \
  DOCKER_NETWORK_SUBNET_IPV4 DOCKER_NETWORK_SUBNET_IPV6 \
  DOCKER_NETWORK_GATEWAY_IPV4 DOCKER_NETWORK_GATEWAY_IPV6 VPN_DOCKER_SUBNET_CIDR \
  AMNEZIAWG_IP COREDNS_IP XRAY_IP AMNEZIAWG_IPV6 COREDNS_IPV6 XRAY_IPV6 TELEPROXY_IP TELEPROXY_IPV6 \
  AMNEZIAWG_MEM_LIMIT COREDNS_MEM_LIMIT

if [[ "${ENABLE_XRAY_INBOUND}" == "1" ]]; then
  if ! [[ "${XRAY_INBOUND_PORT}" =~ ^[0-9]+$ ]] || [[ "${XRAY_INBOUND_PORT}" -lt 1 || "${XRAY_INBOUND_PORT}" -gt 65535 ]]; then
    echo "[render-config] ERROR: XRAY_INBOUND_PORT must be 1-65535 (got ${XRAY_INBOUND_PORT})" >&2
    exit 1
  fi
fi
if ! [[ "${OUT_REALITY_PORT}" =~ ^[0-9]+$ ]] || [[ "${OUT_REALITY_PORT}" -lt 1 || "${OUT_REALITY_PORT}" -gt 65535 ]]; then
  echo "[render-config] ERROR: OUT_REALITY_PORT must be 1-65535 (got ${OUT_REALITY_PORT})" >&2
  exit 1
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[render-config] ERROR: ${name} is empty in ${ENV_FILE}" >&2
    exit 1
  fi
}

ENABLE_MTPROXY="$(parse_bool "${ENABLE_MTPROXY:-}" 0)"
MTPROXY_MODE="${MTPROXY_MODE:-standalone}"
TELEPROXY_VERSION="${TELEPROXY_VERSION:-4.12.0}"
MTPROXY_SECRET="${MTPROXY_SECRET:-}"
MTPROXY_EE_DOMAIN="${MTPROXY_EE_DOMAIN:-}"
MTPROXY_SNI="${MTPROXY_SNI:-}"
MTPROXY_CONTAINER_PORT="${MTPROXY_CONTAINER_PORT:-443}"
MTPROXY_HOST_PORT="${MTPROXY_HOST_PORT:-8444}"
MTPROXY_PUBLISH="${MTPROXY_PUBLISH:-0.0.0.0}"
MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT:-8888}"
MTPROXY_DIRECT_MODE="${MTPROXY_DIRECT_MODE:-true}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_DC_PROBE_INTERVAL="${MTPROXY_DC_PROBE_INTERVAL:-30}"
MTPROXY_MEM_LIMIT="${MTPROXY_MEM_LIMIT:-128m}"

if [[ "${MTPROXY_MODE}" != "standalone" && "${MTPROXY_MODE}" != "sni" ]]; then
  echo "[render-config] ERROR: MTPROXY_MODE must be standalone or sni (got ${MTPROXY_MODE})" >&2
  exit 1
fi

if [[ "${ENABLE_MTPROXY}" == "1" ]]; then
  require_var MTPROXY_EE_DOMAIN
  if [[ "${MTPROXY_MODE}" == "sni" ]]; then
    require_var MTPROXY_SNI
    MTPROXY_PUBLISH="127.0.0.1"
    MTPROXY_EXTERNAL_PORT="${MTPROXY_EXTERNAL_PORT:-443}"
  else
    MTPROXY_EXTERNAL_PORT="${MTPROXY_EXTERNAL_PORT:-${MTPROXY_HOST_PORT}}"
  fi
  if ! [[ "${MTPROXY_HOST_PORT}" =~ ^[0-9]+$ ]] || [[ "${MTPROXY_HOST_PORT}" -lt 1 || "${MTPROXY_HOST_PORT}" -gt 65535 ]]; then
    echo "[render-config] ERROR: MTPROXY_HOST_PORT must be 1-65535 (got ${MTPROXY_HOST_PORT})" >&2
    exit 1
  fi
  if [[ "${MTPROXY_HOST_PORT}" == "443" && "${MTPROXY_MODE}" == "standalone" && "${MTPROXY_PUBLISH}" != "127.0.0.1" ]]; then
    echo "[render-config] ERROR: MTPROXY_HOST_PORT=443 conflicts with host nginx/xray — use 8444 or MTPROXY_MODE=sni" >&2
    exit 1
  fi
else
  MTPROXY_EXTERNAL_PORT="${MTPROXY_EXTERNAL_PORT:-${MTPROXY_HOST_PORT}}"
  : "${MTPROXY_EE_DOMAIN:=}"
fi

IN_INGRESS_ADDR="${IN_SERVER_IP:-}"
MTPROXY_SOCKS5_PROXY="socks5://${SOCKS_USER}:${SOCKS_PASSWORD}@${XRAY_IP}:${SOCKS_PORT}"
MTPROXY_CONFIG_DOWNLOAD_PROXY="${MTPROXY_CONFIG_DOWNLOAD_PROXY:-${MTPROXY_SOCKS5_PROXY}}"

export ENABLE_MTPROXY MTPROXY_MODE TELEPROXY_VERSION MTPROXY_SECRET MTPROXY_EE_DOMAIN MTPROXY_SNI \
  MTPROXY_CONTAINER_PORT MTPROXY_HOST_PORT MTPROXY_PUBLISH MTPROXY_EXTERNAL_PORT MTPROXY_STATS_PORT \
  MTPROXY_DIRECT_MODE MTPROXY_SOCKS5_PROXY MTPROXY_CONFIG_DOWNLOAD_PROXY MTPROXY_WORKERS \
  MTPROXY_DC_PROBE_INTERVAL MTPROXY_MEM_LIMIT IN_INGRESS_ADDR TELEPROXY_IP TELEPROXY_IPV6

for v in AWG_SERVER_PRIVATE_KEY SOCKS_PASSWORD SOCKS_USER \
         OUT_EXIT_ADDRESS OUT_VLESS_UUID OUT_REALITY_PUBLIC_KEY OUT_REALITY_SHORT_ID \
         OUT_REALITY_SERVER_NAME AMNEZIAWG_IP COREDNS_IP XRAY_IP COREDNS_IPV6 \
         AWG_TOOLS_REF AWG_PORT DOCKER_NETWORK_SUBNET_IPV4; do
  require_var "$v"
done

if [[ "${ENABLE_XRAY_INBOUND}" == "1" ]]; then
  for v in REALITY_DEST REALITY_INBOUND_SERVER_NAME REALITY_PRIVATE_KEY REALITY_SHORT_ID; do
    require_var "$v"
  done
else
  : "${REALITY_DEST:=cloudflare.com:443}"
  : "${REALITY_INBOUND_SERVER_NAME:=apple.com}"
  : "${REALITY_PRIVATE_KEY:=unused}"
  : "${REALITY_SHORT_ID:=00000000}"
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/render-config.XXXXXX")"
WORK="${STAGING}"
cleanup_staging() { rm -rf "${STAGING}"; }
if [[ "$DRY_RUN" -eq 1 ]]; then
  trap cleanup_staging EXIT
else
  trap cleanup_staging EXIT
fi

mkdir -p "${WORK}"

ENVSUBST_TMPLS=(
  "${CONFIG_TEMPLATES}/awg0.conf.tmpl"
  "${CONFIG_TEMPLATES}/ipt2socks-amneziawg-v4.sh.tmpl"
  "${CONFIG_TEMPLATES}/ipt2socks-amneziawg-v6.sh.tmpl"
  "${CONFIG_TEMPLATES}/udp-relay-run.sh.tmpl"
  "${CONFIG_TEMPLATES}/ipt2socks-coredns.sh.tmpl"
  "${CONFIG_TEMPLATES}/ipt2socks-ports.env.tmpl"
  "${CONFIG_TEMPLATES}/docker-compose.yml.tmpl"
  "${CONFIG_TEMPLATES}/Corefile.tmpl"
)
ENVSUBST_VARS="$(python3 "${SCRIPT_DIR}/collect-envsubst-vars.py" "${ENVSUBST_TMPLS[@]}")"

assert_no_placeholders() {
  local f
  for f in "$@"; do
    if grep -q '\${' "${f}"; then
      echo "[render-config] ERROR: unsubstituted placeholder in ${f}:" >&2
      grep '\${' "${f}" | head -5 >&2
      exit 1
    fi
  done
}

validate_xray_config() {
  local cfg="$1"
  local image="${XRAY_IMAGE}"
  if [[ "$(parse_bool "${RENDER_SKIP_XRAY_VALIDATE:-}" 0)" == "1" ]]; then
    echo "[render-config] SKIP: xray -test (RENDER_SKIP_XRAY_VALIDATE=1)"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "[render-config] WARN: skip xray -test (docker not in PATH)"
    return 0
  fi
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    echo "[render-config] WARN: skip xray -test (${image} not local — pull or set XRAY_IMAGE)"
    return 0
  fi
  docker run --rm \
    -v "${cfg}:/etc/xray/config.json:ro" \
    --entrypoint xray \
    "${image}" run -test -c /etc/xray/config.json
}

render_envsubst() {
  local tmpl="$1" out="$2"
  envsubst "$ENVSUBST_VARS" < "$tmpl" > "$out"
  assert_no_placeholders "${out}"
}

echo "[render-config] rendering to ${WORK}/"

# awg0.conf — merge peers from existing production file (never read from staging)
PEER_SOURCE="${AWG_CONF}"
if ! grep -q '^\[Peer\]' "${PEER_SOURCE}" 2>/dev/null; then
  LATEST_BACKUP="$(ls -dt "${BUILD_SNAPSHOTS_DIR}"/pre-build-* "${BUILD_SNAPSHOTS_DIR}"/pre-build-* 2>/dev/null | head -1 || true)"
  if [[ -n "${LATEST_BACKUP}" && -f "${LATEST_BACKUP}/awg0.conf" ]] \
     && grep -q '^\[Peer\]' "${LATEST_BACKUP}/awg0.conf"; then
    PEER_SOURCE="${LATEST_BACKUP}/awg0.conf"
    echo "[render-config] WARN: ${AWG_CONF} has no peers — using ${PEER_SOURCE}" >&2
  fi
fi

AWG_HEADER="${WORK}/awg0.header"
render_envsubst "${CONFIG_TEMPLATES}/awg0.conf.tmpl" "${AWG_HEADER}"
"${SCRIPT_DIR}/merge-awg-peers.sh" \
  "${AWG_HEADER}" \
  "${PEER_SOURCE}" \
  "${WORK}/awg0.conf"
rm -f "${AWG_HEADER}"

PEERS="$(grep -c '^\[Peer\]' "${WORK}/awg0.conf" || true)"
if [[ "${PEERS}" -lt 1 && "${BOOTSTRAP}" -eq 0 ]]; then
  echo "[render-config] ERROR: render would drop all AWG peers — aborting" >&2
  exit 1
fi

# ipt2socks launch scripts (rendered with secrets/ports baked in)
render_envsubst "${CONFIG_TEMPLATES}/ipt2socks-amneziawg-v4.sh.tmpl" "${WORK}/ipt2socks-amneziawg-v4.sh"
render_envsubst "${CONFIG_TEMPLATES}/ipt2socks-amneziawg-v6.sh.tmpl" "${WORK}/ipt2socks-amneziawg-v6.sh"
render_envsubst "${CONFIG_TEMPLATES}/udp-relay-run.sh.tmpl" "${WORK}/udp-relay-run.sh"
render_envsubst "${CONFIG_TEMPLATES}/ipt2socks-coredns.sh.tmpl" "${WORK}/ipt2socks-coredns.sh"
render_envsubst "${CONFIG_TEMPLATES}/ipt2socks-ports.env.tmpl" "${WORK}/ipt2socks-ports.env"
render_envsubst "${CONFIG_TEMPLATES}/Corefile.tmpl" "${WORK}/Corefile"
chmod 755 "${WORK}/ipt2socks-amneziawg-v4.sh" "${WORK}/ipt2socks-amneziawg-v6.sh" \
  "${WORK}/udp-relay-run.sh" \
  "${WORK}/ipt2socks-coredns.sh"
chmod 644 "${WORK}/ipt2socks-ports.env" "${WORK}/Corefile"

# docker-compose.yml
render_envsubst "${CONFIG_TEMPLATES}/docker-compose.yml.tmpl" "${WORK}/docker-compose.yml"
chmod +x "${SCRIPT_DIR}/apply-compose-xray-ports.sh"
ENABLE_XRAY_INBOUND="${ENABLE_XRAY_INBOUND}" XRAY_INBOUND_PORT="${XRAY_INBOUND_PORT}" \
  MTPROXY_MODE="${MTPROXY_MODE}" \
  "${SCRIPT_DIR}/apply-compose-xray-ports.sh" "${WORK}/docker-compose.yml"
if [[ "${ENABLE_MTPROXY}" != "1" ]]; then
  render_compose "${WORK}/docker-compose.yml" "teleproxy,teleproxy-data" > "${WORK}/docker-compose.stripped.yml"
  mv "${WORK}/docker-compose.stripped.yml" "${WORK}/docker-compose.yml"
else
  chmod +x "${SCRIPT_DIR}/apply-compose-mtproxy.sh"
  ENABLE_MTPROXY="${ENABLE_MTPROXY}" MTPROXY_MODE="${MTPROXY_MODE}" MTPROXY_PUBLISH="${MTPROXY_PUBLISH}" \
    MTPROXY_HOST_PORT="${MTPROXY_HOST_PORT}" MTPROXY_CONTAINER_PORT="${MTPROXY_CONTAINER_PORT}" \
    MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT}" \
    "${SCRIPT_DIR}/apply-compose-mtproxy.sh" "${WORK}/docker-compose.yml"
fi
chmod 600 "${WORK}/docker-compose.yml"

# config.json — template subst + merge VLESS clients + inbound/outbound ports
XRAY_RENDERED="${WORK}/config.json.rendered"
XRAY_JSON_VARS="$(python3 "${SCRIPT_DIR}/collect-envsubst-vars.py" "${CONFIG_TEMPLATES}/config.json.tmpl")"
export XRAY_INBOUND_PORT OUT_REALITY_PORT OUT_EXIT_ADDRESS OUT_EXIT_DOMAIN_STRATEGY
envsubst "$XRAY_JSON_VARS" < "${CONFIG_TEMPLATES}/config.json.tmpl" > "${XRAY_RENDERED}"
python3 -m json.tool "${XRAY_RENDERED}" >/dev/null
assert_no_placeholders "${XRAY_RENDERED}"
XR_RENDERED="${XRAY_RENDERED}" XR_EXISTING="${XRAY_CONF}" XR_OUTPUT="${WORK}/config.json" \
  python3 "${SCRIPT_DIR}/merge-xray-config.py"
rm -f "${XRAY_RENDERED}"
ENABLE_XRAY_INBOUND="${ENABLE_XRAY_INBOUND}" XRAY_INBOUND_PORT="${XRAY_INBOUND_PORT}" \
  OUT_REALITY_PORT="${OUT_REALITY_PORT}" \
  python3 "${SCRIPT_DIR}/apply-xray-inbound.py" "${WORK}/config.json"
python3 -m json.tool "${WORK}/config.json" >/dev/null
validate_xray_config "${WORK}/config.json"

if [[ "${ENABLE_XRAY_INBOUND}" == "1" ]]; then
  if [[ "${MTPROXY_MODE}" == "sni" ]]; then
    echo "[render-config] XRAY inbound: loopback TCP ${XRAY_INBOUND_PORT} (nginx SNI → :443)"
  else
    echo "[render-config] XRAY inbound: public TCP ${XRAY_INBOUND_PORT}"
  fi
else
  echo "[render-config] XRAY inbound: disabled (host :443 free for other services)"
fi

if [[ "${ENABLE_MTPROXY}" == "1" ]]; then
  echo "[render-config] MTProxy: ${MTPROXY_MODE} publish ${MTPROXY_PUBLISH}:${MTPROXY_HOST_PORT} → container ${MTPROXY_CONTAINER_PORT} (links port ${MTPROXY_EXTERNAL_PORT})"
else
  echo "[render-config] MTProxy: disabled"
fi

PEERS="$(grep -c '^\[Peer\]' "${WORK}/awg0.conf" || true)"
CLIENTS="$(python3 -c "import json; c=json.load(open('${WORK}/config.json')); ibs=[x for x in c['inbounds'] if x.get('protocol')=='vless']; print(len((ibs[0].get('settings') or {}).get('clients') or []) if ibs else 0)")"

if [[ "$DIFF" -eq 1 ]]; then
  echo "[render-config] diff vs ${BUILD_DIR}/:"
  for f in awg0.conf config.json ipt2socks-amneziawg-v4.sh ipt2socks-amneziawg-v6.sh \
           udp-relay-run.sh ipt2socks-coredns.sh ipt2socks-ports.env Corefile docker-compose.yml; do
    if [[ -f "${BUILD_DIR}/${f}" ]]; then
      echo "--- ${f} ---"
      diff -u "${BUILD_DIR}/${f}" "${WORK}/${f}" || true
    fi
  done
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[render-config] dry-run OK (peers=${PEERS}, vless_clients=${CLIENTS})"
  exit 0
fi

# Skip write if identical (zero client impact)
UNCHANGED=1
for f in awg0.conf ipt2socks-amneziawg-v4.sh ipt2socks-amneziawg-v6.sh \
         udp-relay-run.sh ipt2socks-coredns.sh ipt2socks-ports.env Corefile docker-compose.yml; do
  if [[ ! -f "${BUILD_DIR}/${f}" ]] || ! cmp -s "${BUILD_DIR}/${f}" "${WORK}/${f}"; then
    UNCHANGED=0
    break
  fi
done
if [[ "$UNCHANGED" -eq 1 ]] && [[ -f "${BUILD_DIR}/config.json" ]]; then
  python3 - <<PY || UNCHANGED=0
import json
a = json.load(open("${BUILD_DIR}/config.json"))
b = json.load(open("${WORK}/config.json"))
raise SystemExit(0 if a == b else 1)
PY
fi
if [[ "$UNCHANGED" -eq 1 ]] && [[ -f "${BUILD_DIR}/awg0.conf" ]]; then
  if ! cmp -s "${BUILD_DIR}/awg0.conf" "${WORK}/awg0.conf"; then
    UNCHANGED=0
  fi
fi

if [[ "$UNCHANGED" -eq 1 ]]; then
  normalize_build_modes
  remove_obsolete_build_artifacts
  echo "[render-config] no changes — production files unchanged (peers=${PEERS}, vless_clients=${CLIENTS})"
  exit 0
fi

if [[ "${PEERS}" -lt 1 && "${BOOTSTRAP}" -eq 0 ]]; then
  echo "[render-config] ERROR: refusing to write awg0.conf without peers" >&2
  exit 1
fi

if [[ "$NO_BACKUP" -eq 0 ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  BACKUP="${BUILD_SNAPSHOTS_DIR}/pre-build-${STAMP}"
  mkdir -p "${BACKUP}"
  for f in awg0.conf config.json ipt2socks-amneziawg-v4.sh ipt2socks-amneziawg-v6.sh \
           udp-relay-run.sh ipt2socks-coredns.sh ipt2socks-ports.env Corefile docker-compose.yml; do
    [[ -f "${BUILD_DIR}/${f}" ]] && cp -a "${BUILD_DIR}/${f}" "${BACKUP}/"
  done
  echo "[render-config] backup: ${BACKUP}/"
fi

  for f in awg0.conf config.json ipt2socks-amneziawg-v4.sh ipt2socks-amneziawg-v6.sh \
           udp-relay-run.sh ipt2socks-coredns.sh ipt2socks-ports.env Corefile docker-compose.yml; do
  if [[ -f "${BUILD_DIR}/${f}" ]] && cmp -s "${WORK}/${f}" "${BUILD_DIR}/${f}"; then
    continue
  fi
  if [[ ! -f "${WORK}/${f}" ]] || [[ ! -s "${WORK}/${f}" ]]; then
    echo "[render-config] ERROR: render produced empty/missing ${f}" >&2
    exit 1
  fi
  cp -a "${WORK}/${f}" "${BUILD_DIR}/${f}"
done

normalize_build_modes
remove_obsolete_build_artifacts

echo "[render-config] OK — wrote ${BUILD_DIR}/ (peers=${PEERS}, vless_clients=${CLIENTS})"
echo "[render-config] containers NOT restarted — run: make refresh-full (if configs changed)"
