#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/reality-common.sh
source "${SCRIPT_DIR}/../../lib/reality-common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <client_name>" >&2
  exit 1
fi

readonly CLIENT_NAME="$1"
validate_client_name "${CLIENT_NAME}"

readonly VLESS_FILE
VLESS_FILE="$(reality_vless_path "${CLIENT_NAME}")"

load_env
xray_require_container

if [[ ! -f "${XRAY_CONF}" ]]; then
  log_error "Missing ${XRAY_CONF} — run 'make up' or restore build config first."
  exit 1
fi

if [[ -f "${VLESS_FILE}" ]]; then
  log_error "Client '${CLIENT_NAME}' already exists (${VLESS_FILE})."
  exit 1
fi

mkdir -p "${XRAY_CLIENTS_DIR}"

UUID=$(docker exec "${XRAY_CONTAINER}" xray uuid)
[[ -n "${UUID}" ]] || { log_error "Failed to generate UUID."; exit 1; }

SERVER_IP=$(reality_endpoint_host)
PUBLIC_KEY=$(reality_public_key)
readonly CONN_INFO="${XRAY_CONF}.conn_info_${CLIENT_NAME}"

(
  flock -x 200 || { log_error "Could not acquire lock on ${XRAY_CONF}"; exit 1; }

  UUID="${UUID}" XR_CLIENT="${CLIENT_NAME}" XR_CONFIG="${XRAY_CONF}" \
    XR_CONN_INFO="${CONN_INFO}" \
  python3 - <<'PYEOF'
import json
import os
import sys

config_path = os.environ["XR_CONFIG"]
name = os.environ["XR_CLIENT"]

with open(config_path, encoding="utf-8") as f:
    config = json.load(f)

idx = next(
    (i for i, ib in enumerate(config.get("inbounds", [])) if ib.get("protocol") == "vless"),
    None,
)
if idx is None:
    print("Error: no VLESS inbound in config.json", file=sys.stderr)
    sys.exit(1)

ib = config["inbounds"][idx]
rs = (ib.get("streamSettings") or {}).get("realitySettings") or {}
port = ib.get("port")
sni = (rs.get("serverNames") or [""])[0]
sid = (rs.get("shortIds") or [""])[0]

clients = ib.setdefault("settings", {}).setdefault("clients", [])
if any(c.get("email") == name for c in clients):
    print(f"Error: client '{name}' already exists in config.json", file=sys.stderr)
    sys.exit(1)

clients.append({
    "id": os.environ["UUID"],
    "flow": "xtls-rprx-vision",
    "email": name,
})

text = json.dumps(config, indent=2) + "\n"
with open(config_path, "r+", encoding="utf-8") as f:
    f.seek(0)
    f.write(text)
    f.truncate()
    f.flush()
    os.fsync(f.fileno())

with open(os.environ["XR_CONN_INFO"], "w", encoding="utf-8") as ci:
    ci.write(f"{port} {sid} {sni}\n")
PYEOF
) 200>"${XRAY_LOCK}"

read -r SERVER_PORT SHORT_ID SNI < "${CONN_INFO}"
rm -f "${CONN_INFO}"

xray_restart

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${SERVER_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${CLIENT_NAME}"

echo "${VLESS_LINK}" > "${VLESS_FILE}"
chmod 600 "${VLESS_FILE}"

log_info "Client '${CLIENT_NAME}' added."
echo ""
echo "VLESS link:"
echo "${VLESS_LINK}"
echo ""
echo "Saved to: ${VLESS_FILE}"
