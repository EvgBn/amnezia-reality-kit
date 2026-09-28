#!/usr/bin/env bash
# lib/reality-common.sh — shared REALITY/VLESS inbound client helpers.
# Source after paths.sh and common.sh.

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

xray_require_container() {
  if ! docker ps --format '{{.Names}}' | grep -qx "${XRAY_CONTAINER}"; then
    log_error "Container '${XRAY_CONTAINER}' is not running — run 'make up' first."
    return 1
  fi
}

xray_restart() {
  docker compose -f "${COMPOSE_FILE}" restart "${XRAY_SERVICE}" >/dev/null
}

reality_vless_path() {
  printf '%s/%s.vless' "${XRAY_CLIENTS_DIR}" "$1"
}

reality_endpoint_host() {
  local host
  if [[ -n "${IN_SERVER_IP:-}" ]]; then
    host="${IN_SERVER_IP}"
  elif compgen -G "${AWG_CLIENTS_DIR}/*.conf" > /dev/null; then
    host=$(awk -F'[: ]+' '/^Endpoint/{print $3; exit}' "${AWG_CLIENTS_DIR}"/*.conf 2>/dev/null || true)
  fi
  if [[ -z "${host:-}" ]]; then
    host=$(get_public_ip) || return 1
  fi
  printf '%s' "${host}"
}

reality_public_key() {
  local priv="${REALITY_PRIVATE_KEY:-}"
  if [[ -z "${priv}" ]]; then
    priv=$(python3 - "${XRAY_CONF}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
for ib in cfg.get("inbounds", []):
    if ib.get("protocol") != "vless":
        continue
    rs = (ib.get("streamSettings") or {}).get("realitySettings") or {}
    print(rs.get("privateKey", ""))
    break
PY
)
  fi
  if [[ -z "${priv}" ]]; then
    log_error "Could not determine REALITY private key (.env or config.json)."
    return 1
  fi
  docker exec "${XRAY_CONTAINER}" xray x25519 -i "${priv}" \
    | awk '/Public key:/ {print $3; exit}'
}
