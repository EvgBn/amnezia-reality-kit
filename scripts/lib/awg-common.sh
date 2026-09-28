#!/usr/bin/env bash
# lib/awg-common.sh — shared AmneziaWG client management helpers.
# Source after paths.sh and common.sh.

# shellcheck disable=SC2034

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    log_error "Missing ${ENV_FILE} — run 'make extract-env' or create .data/.env first."
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

awg_require_container() {
  if ! docker ps --format '{{.Names}}' | grep -qx "${AWG_CONTAINER}"; then
    log_error "Container '${AWG_CONTAINER}' is not running — run 'make up' first."
    return 1
  fi
}

awg_peer_count() {
  local n
  n="$(grep -c '^\[Peer\]' "${AWG_CONF}" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

awg_server_public_key() {
  local priv
  priv=$(awk '/^PrivateKey/{print $3; exit}' "${AWG_CONF}")
  if [[ -z "${priv}" ]]; then
    log_error "No PrivateKey found in ${AWG_CONF}"
    return 1
  fi
  printf '%s' "${priv}" | docker exec -i "${AWG_CONTAINER}" awg pubkey
}

awg_client_public_key() {
  local priv="$1"
  printf '%s' "${priv}" | docker exec -i "${AWG_CONTAINER}" awg pubkey
}

awg_allocate_ipv4() {
  local last_octet max_octet=1 octet
  while IFS= read -r octet; do
    if (( octet > max_octet )); then
      max_octet="${octet}"
    fi
  done < <(grep '^AllowedIPs' "${AWG_CONF}" \
    | grep -Eo '10\.8\.0\.[0-9]{1,3}' \
    | awk -F. '{print $4}')

  last_octet=$(( max_octet + 1 ))
  if (( last_octet > 254 )); then
    log_error "IPv4 address space exhausted (10.8.0.2–10.8.0.254 are all in use)."
    return 1
  fi
  printf '10.8.0.%s' "${last_octet}"
}

awg_ipv6_allowed() {
  local octet="$1"
  local addr_line base prefix
  addr_line=$(awk '/^Address = fd/ {print $3; exit}' "${AWG_CONF}")
  if [[ -z "${addr_line}" ]]; then
    return 1
  fi
  base="${addr_line%%/*}"
  prefix="${base%1}"
  printf '%s%d/128' "${prefix}" "${octet}"
}

awg_read_obfuscation() {
  JC=$(awk '/^Jc  *=/{print $3; exit}' "${AWG_CONF}")
  JMIN=$(awk '/^Jmin/{print $3; exit}' "${AWG_CONF}")
  JMAX=$(awk '/^Jmax/{print $3; exit}' "${AWG_CONF}")
  S1=$(awk '/^S1  *=/{print $3; exit}' "${AWG_CONF}")
  S2=$(awk '/^S2  *=/{print $3; exit}' "${AWG_CONF}")
  S3=$(awk '/^S3  *=/{print $3; exit}' "${AWG_CONF}")
  S4=$(awk '/^S4  *=/{print $3; exit}' "${AWG_CONF}")
  H1=$(awk '/^H1  *=/{print $3; exit}' "${AWG_CONF}")
  H2=$(awk '/^H2  *=/{print $3; exit}' "${AWG_CONF}")
  H3=$(awk '/^H3  *=/{print $3; exit}' "${AWG_CONF}")
  H4=$(awk '/^H4  *=/{print $3; exit}' "${AWG_CONF}")

  if [[ -z "${JC}" || -z "${JMIN}" || -z "${JMAX}" || -z "${S1}" || -z "${S2}" \
     || -z "${S3}" || -z "${S4}" || -z "${H1}" || -z "${H2}" || -z "${H3}" || -z "${H4}" ]]; then
    log_error "Could not read obfuscation parameters from ${AWG_CONF}"
    return 1
  fi
}

awg_endpoint() {
  local host port="${AWG_PORT:-58285}"

  if [[ -n "${IN_SERVER_IP:-}" ]]; then
    host="${IN_SERVER_IP}"
  elif compgen -G "${AWG_CLIENTS_DIR}/*.conf" > /dev/null; then
    host=$(awk -F'[: ]+' '/^Endpoint/{print $3; exit}' "${AWG_CLIENTS_DIR}"/*.conf 2>/dev/null || true)
  fi

  if [[ -z "${host:-}" ]]; then
    host=$(get_public_ip) || return 1
  fi

  printf '%s:%s' "${host}" "${port}"
}

awg_syncconf() {
  docker exec "${AWG_CONTAINER}" sh -c '
    grep -v -E "^(Address|PostUp|PostDown|SaveConfig|MTU|DNS|Table|PreUp|PreDown)\s*=" \
      /etc/awg/awg0.conf > /tmp/awg0_stripped.conf
    awg syncconf awg0 /tmp/awg0_stripped.conf
    rm -f /tmp/awg0_stripped.conf
  '
}

client_conf_path() {
  printf '%s/%s.conf' "${AWG_CLIENTS_DIR}" "$1"
}
