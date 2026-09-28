#!/usr/bin/env bash
# Load .data/.env for probes that need AWG_PORT etc.
# Groups mirror render-config.sh require_var list (phase 8).

PREFLIGHT_ENV_OUT=(
  OUT_VLESS_UUID OUT_REALITY_PUBLIC_KEY
  OUT_REALITY_SHORT_ID OUT_REALITY_SERVER_NAME
)
PREFLIGHT_ENV_REALITY=(
  REALITY_DEST REALITY_INBOUND_SERVER_NAME
  REALITY_PRIVATE_KEY REALITY_SHORT_ID
)
PREFLIGHT_ENV_CORE=(
  AWG_SERVER_PRIVATE_KEY SOCKS_PASSWORD SOCKS_USER
  COREDNS_IPV6 AWG_TOOLS_REF AWG_PORT
)
PREFLIGHT_ENV_MTPROXY=(
  TELEPROXY_VERSION MTPROXY_EE_DOMAIN
)

PREFLIGHT_REQUIRED_ENV_VARS=(
  "${PREFLIGHT_ENV_OUT[@]}"
  "${PREFLIGHT_ENV_REALITY[@]}"
  "${PREFLIGHT_ENV_CORE[@]}"
)

# Placeholder values copied from config/examples/.env.example (bootstrap without COPY_FROM).
preflight_env_value_is_placeholder() {
  local val="${1:-}"
  [[ -z "${val}" ]] && return 1
  case "${val}" in
    YOUR_*|*YOUR_*_HERE|*YOUR_*_HERE*) return 0 ;;
    198.51.100.*) return 0 ;;
  esac
  return 1
}

preflight_env_has_out_placeholders() {
  local k addr
  for k in OUT_VLESS_UUID OUT_REALITY_PUBLIC_KEY OUT_REALITY_SHORT_ID; do
    if preflight_env_value_is_placeholder "${!k:-}"; then
      return 0
    fi
  done
  if [[ -n "${OUT_EXIT:-}" ]]; then
    # shellcheck source=../../lib/endpoint.sh
    source "${REPO_ROOT}/scripts/lib/endpoint.sh"
    if endpoint_parse "${OUT_EXIT}"; then
      if preflight_env_value_is_placeholder "${ENDPOINT_ADDR}"; then
        return 0
      fi
    fi
  elif [[ -n "${OUT_SERVER_IPV6:-}" ]] && preflight_env_value_is_placeholder "${OUT_SERVER_IPV6}"; then
    return 0
  fi
  return 1
}

preflight_check_env_group() {
  local label="$1"
  shift
  local -a keys=("$@")
  local k missing=0 val

  for k in "${keys[@]}"; do
    val="${!k:-}"
    if [[ -z "${val}" ]]; then
      emit FAIL DATA "${k}" "empty in .env" "edit .data/.env or: make create-data COPY_FROM=/path/to/working/.data/.env FORCE=1"
      missing=1
    elif preflight_env_value_is_placeholder "${val}"; then
      emit FAIL DATA "${k}" "placeholder (${val})" "make create-data COPY_FROM=/path/to/working/.data/.env FORCE=1"
      missing=1
    fi
  done

  if [[ "${missing}" -eq 0 ]]; then
    emit OK DATA "${label}" "${#keys[@]}/${#keys[@]} keys set"
  fi
}

preflight_load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=../../lib/docker-network-plan.sh
    source "${REPO_ROOT}/scripts/lib/docker-network-plan.sh"
    docker_network_plan_resolve "${ENV_FILE}" || return 1
    if [[ -z "${OUT_REALITY_SERVER_NAME:-}" && -n "${REALITY_SERVER_NAME:-}" ]]; then
      OUT_REALITY_SERVER_NAME="${REALITY_SERVER_NAME}"
    fi
    # shellcheck source=../../lib/endpoint.sh
    source "${REPO_ROOT}/scripts/lib/endpoint.sh"
    ENDPOINT_RESOLVE_QUIET=1
    endpoint_resolve_env || return 1
    unset ENDPOINT_RESOLVE_QUIET
    # Legacy env keys (AMNEZIAWG_POD_* etc., pre-2026-09 rename)
    AMNEZIAWG_IP="${AMNEZIAWG_IP:-${AMNEZIAWG_POD_IP:-}}"
    COREDNS_IPV6="${COREDNS_IPV6:-${COREDNS_POD_IPV6:-}}"
    return 0
  fi
  AWG_PORT="${AWG_PORT:-58285}"
  AMNEZIAWG_IP="${AMNEZIAWG_IP:-10.200.97.3}"
  AWG_TUNNEL_SUBNET_IPV4="${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}"
  return 1
}

# Image ref for amneziawg (compose: amneziawg:${AMNEZIAWG_RELEASE}; bootstrap may set AWG_IMAGE).
preflight_awg_image_ref() {
  if [[ -n "${AWG_IMAGE:-}" ]]; then
    echo "${AWG_IMAGE}"
  else
    echo "amneziawg:${AMNEZIAWG_RELEASE:-latest}"
  fi
}

# Image ref for teleproxy (upstream pull; tag from TELEPROXY_VERSION).
preflight_teleproxy_image_ref() {
  echo "ghcr.io/teleproxy/teleproxy:${TELEPROXY_VERSION:-4.12.0}"
}
