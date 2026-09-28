#!/usr/bin/env bash
# endpoint.sh — FAMILY; ADDRESS tuples for IN/OUT roles (.env operator UX).

_ENDPOINT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env-file.sh
source "${_ENDPOINT_LIB_DIR}/env-file.sh"
unset _ENDPOINT_LIB_DIR
# Canonical: 4; 198.51.100.10   6; 2606:4700::1
# Legacy alias (WARN): 4,addr  6,addr

# shellcheck disable=SC2034
ENDPOINT_FAMILY=""
ENDPOINT_ADDR=""

endpoint_trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "${v}"
}

# endpoint_parse RAW — sets ENDPOINT_FAMILY (4|6) and ENDPOINT_ADDR; returns 0 on success.
endpoint_parse() {
  local raw fam rest delim
  raw="$(endpoint_trim "$1")"
  ENDPOINT_FAMILY=""
  ENDPOINT_ADDR=""

  if [[ ! "${raw}" =~ ^[46] ]]; then
    return 1
  fi
  fam="${raw:0:1}"
  rest="$(endpoint_trim "${raw:1}")"
  if [[ -z "${rest}" ]]; then
    return 1
  fi
  delim="${rest:0:1}"
  if [[ "${delim}" != ";" && "${delim}" != "," ]]; then
    return 1
  fi
  ENDPOINT_ADDR="$(endpoint_trim "${rest:1}")"
  ENDPOINT_FAMILY="${fam}"
  [[ -n "${ENDPOINT_ADDR}" ]] || return 1
  return 0
}

endpoint_addr_matches_family() {
  local family="$1" addr="$2"
  if [[ "${family}" == "4" ]]; then
    [[ "${addr}" == *:* ]] && return 1
    [[ "${addr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    return 0
  fi
  if [[ "${family}" == "6" ]]; then
    [[ "${addr}" == *:* ]] || return 1
    return 0
  fi
  return 1
}

# endpoint_validate_tuple FAMILY ADDR — return 0 if consistent literal IP.
endpoint_validate_tuple() {
  endpoint_addr_matches_family "$1" "$2"
}

endpoint_domain_strategy_for_family() {
  case "$1" in
    4) printf '%s' "UseIPv4" ;;
    6) printf '%s' "UseIPv6" ;;
    *) return 1 ;;
  esac
}

_endpoint_warn_deprecated() {
  [[ "${ENDPOINT_RESOLVE_QUIET:-0}" == "1" ]] && return 0
  echo "[endpoint] deprecated ${1} — use ${2}" >&2
}

_endpoint_conflict() {
  echo "[endpoint] ERROR: ${1} conflicts with ${2} (${3} vs ${4})" >&2
  return 1
}

# endpoint_resolve_env — after sourcing .env; exports derived + compat vars.
endpoint_resolve_env() {
  local fam addr

  # --- (1) IN ingress ---
  if [[ -n "${IN_INGRESS:-}" ]]; then
    endpoint_parse "${IN_INGRESS}" || {
      echo "[endpoint] ERROR: invalid IN_INGRESS (want FAMILY; ADDRESS)" >&2
      return 1
    }
    endpoint_validate_tuple "${ENDPOINT_FAMILY}" "${ENDPOINT_ADDR}" || {
      echo "[endpoint] ERROR: IN_INGRESS family ${ENDPOINT_FAMILY} does not match address ${ENDPOINT_ADDR}" >&2
      return 1
    }
    if [[ "${ENDPOINT_FAMILY}" == "4" ]]; then
      if [[ -n "${IN_SERVER_IP:-}" && "${IN_SERVER_IP}" != "${ENDPOINT_ADDR}" ]]; then
        _endpoint_conflict "IN_INGRESS" "IN_SERVER_IP" "${ENDPOINT_ADDR}" "${IN_SERVER_IP}" || return 1
      fi
      IN_SERVER_IP="${ENDPOINT_ADDR}"
    else
      if [[ -n "${IN_SERVER_IPV6:-}" && "${IN_SERVER_IPV6}" != "${ENDPOINT_ADDR}" ]]; then
        _endpoint_conflict "IN_INGRESS" "IN_SERVER_IPV6" "${ENDPOINT_ADDR}" "${IN_SERVER_IPV6}" || return 1
      fi
      IN_SERVER_IPV6="${ENDPOINT_ADDR}"
    fi
  elif [[ -n "${IN_SERVER_IP:-}" ]]; then
    _endpoint_warn_deprecated "IN_SERVER_IP" "IN_INGRESS=4; ${IN_SERVER_IP}"
    IN_INGRESS="4; ${IN_SERVER_IP}"
  else
    echo "[endpoint] ERROR: IN_INGRESS (or legacy IN_SERVER_IP) is required" >&2
    return 1
  fi

  if [[ -n "${IN_INGRESS_6:-}" ]]; then
    endpoint_parse "${IN_INGRESS_6}" || {
      echo "[endpoint] ERROR: invalid IN_INGRESS_6" >&2
      return 1
    }
    [[ "${ENDPOINT_FAMILY}" == "6" ]] || {
      echo "[endpoint] ERROR: IN_INGRESS_6 must use family 6" >&2
      return 1
    }
    endpoint_validate_tuple "${ENDPOINT_FAMILY}" "${ENDPOINT_ADDR}" || return 1
    if [[ -n "${IN_SERVER_IPV6:-}" && "${IN_SERVER_IPV6}" != "${ENDPOINT_ADDR}" ]]; then
      _endpoint_conflict "IN_INGRESS_6" "IN_SERVER_IPV6" "${ENDPOINT_ADDR}" "${IN_SERVER_IPV6}" || return 1
    fi
    IN_SERVER_IPV6="${ENDPOINT_ADDR}"
  fi

  # --- (2) IN bridge source (v1: auto only validated) ---
  IN_BRIDGE_SOURCE="${IN_BRIDGE_SOURCE:-auto}"
  if [[ "${IN_BRIDGE_SOURCE}" == "auto" ]]; then
    :
  elif endpoint_parse "${IN_BRIDGE_SOURCE}"; then
    endpoint_validate_tuple "${ENDPOINT_FAMILY}" "${ENDPOINT_ADDR}" || {
      echo "[endpoint] ERROR: IN_BRIDGE_SOURCE tuple invalid" >&2
      return 1
    }
    IN_BRIDGE_SOURCE_FAMILY="${ENDPOINT_FAMILY}"
    IN_BRIDGE_SOURCE_ADDRESS="${ENDPOINT_ADDR}"
  else
    echo "[endpoint] ERROR: IN_BRIDGE_SOURCE must be 'auto' or FAMILY; ADDRESS" >&2
    return 1
  fi

  # --- (3) OUT exit ---
  if [[ -n "${OUT_EXIT:-}" ]]; then
    endpoint_parse "${OUT_EXIT}" || {
      echo "[endpoint] ERROR: invalid OUT_EXIT (want FAMILY; ADDRESS)" >&2
      return 1
    }
    endpoint_validate_tuple "${ENDPOINT_FAMILY}" "${ENDPOINT_ADDR}" || {
      echo "[endpoint] ERROR: OUT_EXIT family ${ENDPOINT_FAMILY} does not match address ${ENDPOINT_ADDR}" >&2
      return 1
    }
    if [[ -n "${OUT_SERVER_IPV6:-}" && "${ENDPOINT_FAMILY}" == "6" && "${OUT_SERVER_IPV6}" != "${ENDPOINT_ADDR}" ]]; then
      _endpoint_conflict "OUT_EXIT" "OUT_SERVER_IPV6" "${ENDPOINT_ADDR}" "${OUT_SERVER_IPV6}" || return 1
    fi
    if [[ -n "${OUT_SERVER_IP:-}" && "${ENDPOINT_FAMILY}" == "4" && "${OUT_SERVER_IP}" != "${ENDPOINT_ADDR}" ]]; then
      _endpoint_conflict "OUT_EXIT" "OUT_SERVER_IP" "${ENDPOINT_ADDR}" "${OUT_SERVER_IP}" || return 1
    fi
    OUT_EXIT_FAMILY="${ENDPOINT_FAMILY}"
    OUT_EXIT_ADDRESS="${ENDPOINT_ADDR}"
  elif [[ -n "${OUT_SERVER_IPV6:-}" ]]; then
    _endpoint_warn_deprecated "OUT_SERVER_IPV6" "OUT_EXIT=6; ${OUT_SERVER_IPV6}"
    OUT_EXIT="6; ${OUT_SERVER_IPV6}"
    OUT_EXIT_FAMILY="6"
    OUT_EXIT_ADDRESS="${OUT_SERVER_IPV6}"
  else
    echo "[endpoint] ERROR: OUT_EXIT (or legacy OUT_SERVER_IPV6) is required" >&2
    return 1
  fi

  OUT_EXIT_DOMAIN_STRATEGY="$(endpoint_domain_strategy_for_family "${OUT_EXIT_FAMILY}")"

  # Compat for scripts still reading legacy names.
  if [[ "${OUT_EXIT_FAMILY}" == "6" ]]; then
    OUT_SERVER_IPV6="${OUT_EXIT_ADDRESS}"
  fi
  if [[ "${OUT_EXIT_FAMILY}" == "4" ]]; then
    OUT_SERVER_IP="${OUT_EXIT_ADDRESS}"
  fi

  # --- (4) Expected egress (check only) ---
  OUT_EXPECTED_EGRESS_FAMILY=""
  OUT_EXPECTED_EGRESS_ADDRESS=""
  if [[ -n "${OUT_EXPECTED_EGRESS:-}" ]]; then
    endpoint_parse "${OUT_EXPECTED_EGRESS}" || {
      echo "[endpoint] ERROR: invalid OUT_EXPECTED_EGRESS" >&2
      return 1
    }
    endpoint_validate_tuple "${ENDPOINT_FAMILY}" "${ENDPOINT_ADDR}" || return 1
    OUT_EXPECTED_EGRESS_FAMILY="${ENDPOINT_FAMILY}"
    OUT_EXPECTED_EGRESS_ADDRESS="${ENDPOINT_ADDR}"
    if [[ -n "${OUT_SERVER_IP:-}" && "${OUT_SERVER_IP}" != "${ENDPOINT_ADDR}" && "${OUT_EXIT_FAMILY}" != "4" ]]; then
      : # OUT_SERVER_IP may differ when OUT_EXIT is v6 and EXPECTED is v4 egress — OK
    fi
  elif [[ -n "${OUT_SERVER_IP:-}" && "${OUT_EXIT_FAMILY}" != "4" ]]; then
    _endpoint_warn_deprecated "OUT_SERVER_IP (egress hint)" "OUT_EXPECTED_EGRESS=4; ${OUT_SERVER_IP}"
    OUT_EXPECTED_EGRESS="4; ${OUT_SERVER_IP}"
    OUT_EXPECTED_EGRESS_FAMILY="4"
    OUT_EXPECTED_EGRESS_ADDRESS="${OUT_SERVER_IP}"
  fi

  export IN_INGRESS IN_INGRESS_6 IN_SERVER_IP IN_SERVER_IPV6
  export IN_BRIDGE_SOURCE IN_BRIDGE_SOURCE_FAMILY IN_BRIDGE_SOURCE_ADDRESS
  export OUT_EXIT OUT_EXIT_FAMILY OUT_EXIT_ADDRESS OUT_EXIT_DOMAIN_STRATEGY
  export OUT_EXPECTED_EGRESS OUT_EXPECTED_EGRESS_FAMILY OUT_EXPECTED_EGRESS_ADDRESS
  export OUT_SERVER_IPV6 OUT_SERVER_IP
  return 0
}

# endpoint_normalize_env_file PATH — rewrite legacy keys to tuple form (bootstrap post-process).
endpoint_normalize_env_file() {
  local env_file="$1"
  local tmp line key val
  [[ -f "${env_file}" ]] || return 1

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
  ENDPOINT_RESOLVE_QUIET=1
  endpoint_resolve_env || return 1
  unset ENDPOINT_RESOLVE_QUIET

  tmp="$(mktemp "${env_file}.norm.XXXXXX")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      IN_SERVER_IP=*|OUT_SERVER_IP=*|OUT_SERVER_IPV6=*|\
      IN_INGRESS=*|IN_INGRESS_6=*|OUT_EXIT=*|OUT_EXPECTED_EGRESS=*|IN_BRIDGE_SOURCE=*)
        continue
        ;;
      *)
        printf '%s\n' "${line}" >> "${tmp}"
        ;;
    esac
  done < "${env_file}"

  {
    printf 'IN_INGRESS=%s\n' "$(env_file_quote_value "${IN_INGRESS}")"
    [[ -n "${IN_INGRESS_6:-}" ]] && printf 'IN_INGRESS_6=%s\n' "$(env_file_quote_value "${IN_INGRESS_6}")"
    printf 'IN_BRIDGE_SOURCE=%s\n' "$(env_file_quote_value "${IN_BRIDGE_SOURCE}")"
    printf 'OUT_EXIT=%s\n' "$(env_file_quote_value "${OUT_EXIT}")"
    [[ -n "${OUT_EXPECTED_EGRESS:-}" ]] && \
      printf 'OUT_EXPECTED_EGRESS=%s\n' "$(env_file_quote_value "${OUT_EXPECTED_EGRESS}")"
  } >> "${tmp}"

  mv -f "${tmp}" "${env_file}"
  chmod 600 "${env_file}" 2>/dev/null || true
  return 0
}
