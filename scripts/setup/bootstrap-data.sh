#!/usr/bin/env bash
# First-time .data/ scaffold: .env secrets + directory layout.
# Does not start containers. Follow with: make build (or create-data runs build --bootstrap).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/versions.sh
source "${SCRIPT_DIR}/../lib/versions.sh"
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"

FORCE="${FORCE:-0}"
COPY_FROM="${COPY_FROM:-}"
# Empty AWG_IMAGE from Makefile means auto-detect / build keygen image.
AWG_IMAGE="${AWG_IMAGE:-}"
XRAY_IMAGE="${XRAY_IMAGE:-teddysun/xray:26.6.27}"

docker_image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

build_awg_keygen_image() {
  local tag="$1" sha="$2"
  local image="amneziawg:${tag}"
  echo "[bootstrap] no local amneziawg image — building ${image} for key generation (one-time)..."
  docker build -f "${REPO_ROOT}/containers/amneziawg/Dockerfile" \
    --target keygen \
    --build-arg "AWG_TOOLS_REF=${sha}" \
    -t "${image}" \
    "${REPO_ROOT}/containers/amneziawg"
  echo "${image}"
}

# resolve_awg_bootstrap_image <tools_tag> <tools_sha>
# Prints image ref to stdout; logs hints to stderr.
resolve_awg_bootstrap_image() {
  local tools_tag="$1" tools_sha="$2" candidate image

  if [[ -n "${AWG_IMAGE}" ]]; then
    docker_image_exists "${AWG_IMAGE}" || {
      echo "[bootstrap] ERROR: AWG_IMAGE='${AWG_IMAGE}' not found locally." >&2
      echo "[bootstrap] Hint: docker images | grep amneziawg  — or omit AWG_IMAGE to auto-detect/build." >&2
      return 1
    }
    echo "${AWG_IMAGE}"
    return 0
  fi

  for candidate in "amneziawg:latest" "amneziawg:${tools_tag}"; do
    if docker_image_exists "${candidate}"; then
      echo "[bootstrap] using local image ${candidate}" >&2
      echo "${candidate}"
      return 0
    fi
  done

  image="$(docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E '^amneziawg:' \
    | grep -v '<none>' \
    | sort -V -r \
    | head -n1 || true)"
  if [[ -n "${image}" ]] && docker_image_exists "${image}"; then
    echo "[bootstrap] using local image ${image}" >&2
    echo "${image}"
    return 0
  fi

  build_awg_keygen_image "${tools_tag}" "${tools_sha}"
}

ensure_xray_image() {
  if docker_image_exists "${XRAY_IMAGE}"; then
    return 0
  fi
  echo "[bootstrap] pulling ${XRAY_IMAGE} for REALITY key generation..."
  docker pull "${XRAY_IMAGE}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0")

  Creates ${DATA_DIR}/ layout and ${ENV_FILE} from config/examples/.env.example.
  Generates IN-server secrets; optionally copies OUT exit settings from COPY_FROM.

  Environment:
    COPY_FROM   Path to an existing .data/.env (copies OUT_* and network topology)
    FORCE=1     Overwrite existing ${ENV_FILE}
    AWG_IMAGE   Docker image for awg keygen (optional; auto-detect local amneziawg:* or build)
    XRAY_IMAGE  Docker image for xray x25519 (default: teddysun/xray:26.6.27)

  Next: make build   (or make create-data, which runs build --bootstrap)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -f "${ENV_FILE}" && "${FORCE}" != "1" ]]; then
  echo "[bootstrap] ERROR: ${ENV_FILE} already exists (set FORCE=1 to overwrite)." >&2
  echo "[bootstrap] Hint: existing secrets + missing build/ → run 'make build' (not make create-data)." >&2
  exit 1
fi

if [[ -n "${COPY_FROM}" ]]; then
  [[ -f "${COPY_FROM}" ]] || {
    echo "[bootstrap] ERROR: COPY_FROM not found: ${COPY_FROM}" >&2
    echo "[bootstrap] COPY_FROM must be a real path to a working .data/.env (not the hint placeholder)." >&2
    exit 1
  }
fi

mkdir -p "${BUILD_DIR}" "${AWG_CLIENTS_DIR}" "${MTPROXY_CLIENTS_DIR}" "${BUILD_SNAPSHOTS_DIR}"
chmod 700 "${MTPROXY_CLIENTS_DIR}" 2>/dev/null || true
chmod 700 "${DATA_DIR}" 2>/dev/null || true

echo "[bootstrap] resolving amneziawg-tools ref..."
if ! AWG_TOOLS_OUT="$(resolve_ref "${REPO_AWG_TOOLS}" "")"; then
  echo "[bootstrap] ERROR: could not resolve ${REPO_AWG_TOOLS}" >&2
  exit 1
fi
AWG_TOOLS_TAG="${AWG_TOOLS_OUT%%$'\t'*}"
AWG_TOOLS_SHA="${AWG_TOOLS_OUT#*$'\t'}"

if ! AWG_IMAGE="$(resolve_awg_bootstrap_image "${AWG_TOOLS_TAG}" "${AWG_TOOLS_SHA}")"; then
  exit 1
fi

ensure_xray_image

echo "[bootstrap] generating AmneziaWG server keys..."
AWG_SERVER_PRIVATE_KEY="$(docker run --rm --entrypoint awg "${AWG_IMAGE}" genkey)"
AWG_SERVER_PUBLIC_KEY="$(printf '%s' "${AWG_SERVER_PRIVATE_KEY}" | docker run --rm -i --entrypoint awg "${AWG_IMAGE}" pubkey)"

echo "[bootstrap] generating SOCKS password..."
SOCKS_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

echo "[bootstrap] generating Xray REALITY inbound keys..."
XRAY_KEYS="$(docker run --rm --entrypoint xray "${XRAY_IMAGE}" x25519)"
REALITY_PRIVATE_KEY="$(awk '/PrivateKey:/{print $2}' <<< "${XRAY_KEYS}")"
REALITY_PUBLIC_KEY="$(awk '/Password \(PublicKey\):/{print $3}' <<< "${XRAY_KEYS}")"
REALITY_SHORT_ID="$(openssl rand -hex 8)"
VLESS_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"

IN_SERVER_IP="${IN_SERVER_IP:-}"
if [[ -z "${IN_SERVER_IP}" ]]; then
  IN_SERVER_IP="$(curl -4 -sf ifconfig.me 2>/dev/null || true)"
fi
if [[ -z "${IN_SERVER_IP}" ]]; then
  IN_SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -n "${IN_SERVER_IP}" ]] || { echo "[bootstrap] ERROR: set IN_SERVER_IP or ensure public IP detection works." >&2; exit 1; }

ENV_TMP="$(mktemp "${ENV_FILE}.XXXXXX")"
cleanup_env_tmp() {
  [[ -n "${ENV_TMP:-}" && -f "${ENV_TMP}" ]] && rm -f "${ENV_TMP}"
}
trap cleanup_env_tmp EXIT

cp "${REPO_ROOT}/config/examples/.env.example" "${ENV_TMP}"
chmod 600 "${ENV_TMP}"

set_env() {
  env_file_set "${ENV_TMP}" "$1" "$2"
}

env_file_set "${ENV_TMP}" IN_INGRESS "4; ${IN_SERVER_IP}"
env_file_set "${ENV_TMP}" AWG_PORT "${AWG_PORT:-58285}"
env_file_set "${ENV_TMP}" AWG_LISTEN_PORT "51820"
env_file_set "${ENV_TMP}" AWG_TOOLS_REF "${AWG_TOOLS_SHA}"
env_file_set "${ENV_TMP}" AMNEZIAWG_RELEASE "${AWG_TOOLS_TAG}"
env_file_set "${ENV_TMP}" AWG_SERVER_PRIVATE_KEY "${AWG_SERVER_PRIVATE_KEY}"
env_file_set "${ENV_TMP}" AWG_SERVER_PUBLIC_KEY "${AWG_SERVER_PUBLIC_KEY}"
env_file_set "${ENV_TMP}" SOCKS_PASSWORD "${SOCKS_PASSWORD}"
env_file_set "${ENV_TMP}" REALITY_PRIVATE_KEY "${REALITY_PRIVATE_KEY}"
env_file_set "${ENV_TMP}" REALITY_PUBLIC_KEY "${REALITY_PUBLIC_KEY}"
env_file_set "${ENV_TMP}" REALITY_SHORT_ID "${REALITY_SHORT_ID}"
env_file_set "${ENV_TMP}" VLESS_UUID "${VLESS_UUID}"

# IN inbound REALITY mask (direct VLESS clients on :443; AWG path uses SOCKS→exit only)
env_file_set "${ENV_TMP}" REALITY_DEST "${REALITY_DEST:-cloudflare.com:443}"
env_file_set "${ENV_TMP}" REALITY_INBOUND_SERVER_NAME "${REALITY_INBOUND_SERVER_NAME:-apple.com}"

# OUT exit REALITY SNI (config.json outbounds[].streamSettings.realitySettings.serverName)
env_file_set "${ENV_TMP}" OUT_REALITY_SERVER_NAME "${OUT_REALITY_SERVER_NAME:-dl.google.com}"
env_file_set "${ENV_TMP}" ENABLE_XRAY_INBOUND "${ENABLE_XRAY_INBOUND:-1}"
env_file_set "${ENV_TMP}" ENABLE_MTPROXY "${ENABLE_MTPROXY:-0}"
env_file_set "${ENV_TMP}" TELEPROXY_VERSION "${TELEPROXY_VERSION:-4.12.0}"
env_file_set "${ENV_TMP}" XRAY_INBOUND_PORT "${XRAY_INBOUND_PORT:-443}"
env_file_set "${ENV_TMP}" OUT_REALITY_PORT "${OUT_REALITY_PORT:-443}"

if [[ -n "${COPY_FROM}" ]]; then
  echo "[bootstrap] copying OUT exit + topology from ${COPY_FROM}..."
  for key in IN_INGRESS IN_INGRESS_6 IN_BRIDGE_SOURCE OUT_EXIT OUT_EXPECTED_EGRESS \
             OUT_VLESS_UUID OUT_REALITY_PUBLIC_KEY \
             OUT_REALITY_SHORT_ID OUT_REALITY_SERVER_NAME REALITY_DEST \
             REALITY_INBOUND_SERVER_NAME COREDNS_IPV6 COREDNS_IP \
             AMNEZIAWG_IP AMNEZIAWG_IPV6 XRAY_IP XRAY_IPV6 \
             DOCKER_NETWORK_SUBNET_IPV4 DOCKER_NETWORK_SUBNET_IPV6 DOCKER_NETWORK_GATEWAY_IPV6 \
             AWG_TUNNEL_IPV4 AWG_TUNNEL_IPV6 AWG_TUNNEL_SUBNET_IPV4 AWG_TUNNEL_SUBNET_IPV6 \
             AWG_TUNNEL_GATEWAY_IPV4 AWG_TUNNEL_GATEWAY_IPV6 \
             AWG_IPT2SOCKS_PORT AWG_IPT2SOCKS_PORT_IPV6 COREDNS_IPT2SOCKS_PORT \
             AWG_UDP_RELAY_PORT AWG_UDP_RELAY_PORT_IPV6 AWG_NFQUEUE_NUM AWG_UDP_RELAY_LOG_LEVEL \
             IPT2SOCKS_THREADS IPT2SOCKS_NOFILE_LIMIT IPT2SOCKS_UDP_TIMEOUT \
             AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 AWG_S3 AWG_S4 \
             AWG_H1 AWG_H2 AWG_H3 AWG_H4 ENABLE_XRAY_INBOUND XRAY_INBOUND_PORT OUT_REALITY_PORT \
             ENABLE_MTPROXY TELEPROXY_VERSION MTPROXY_MODE MTPROXY_HOST_PORT MTPROXY_EE_DOMAIN \
             MTPROXY_SNI MTPROXY_PUBLISH MTPROXY_SECRET MTPROXY_STATS_PORT; do
    line="$(grep -E "^${key}=" "${COPY_FROM}" | tail -1 || true)"
    [[ -n "${line}" ]] || continue
    val="$(env_file_parse_value "${line#*=}")"
    set_env "${key}" "${val}"
  done
fi

mv -f "${ENV_TMP}" "${ENV_FILE}"
ENV_TMP=""
trap - EXIT

# shellcheck source=../lib/endpoint.sh
source "${SCRIPT_DIR}/../lib/endpoint.sh"
endpoint_normalize_env_file "${ENV_FILE}" || {
  echo "[bootstrap] ERROR: endpoint normalize failed" >&2
  exit 1
}

echo "[bootstrap] OK — wrote ${ENV_FILE}"
echo "[bootstrap] IN_INGRESS=$(grep '^IN_INGRESS=' "${ENV_FILE}" | cut -d= -f2-) AWG_PORT=$(grep '^AWG_PORT=' "${ENV_FILE}" | cut -d= -f2)"
echo "[bootstrap] next: make build   (or make create-data to build --bootstrap)"
