#!/usr/bin/env bash
# Host route for AWG client subnet → amneziawg on Docker bridge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/host-network.sh
source "${SCRIPT_DIR}/../lib/host-network.sh"

ACTION="${1:-apply}"

log_and_remove_awg_routes() {
  local subnet="$1" gateway="$2" line removed
  removed=0
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    echo "[route] removing ${line}"
    removed=1
  done < <(host_awg_route_lines "${subnet}" "${gateway}")
  if [[ "${removed}" -eq 0 ]]; then
    echo "[route] no route for ${subnet} via ${gateway}"
    return 0
  fi
  host_awg_routes_remove "${subnet}" "${gateway}" >/dev/null
}

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ "${ACTION}" == "remove" || "${ACTION}" == "del" || "${ACTION}" == "delete" ]]; then
    log_and_remove_awg_routes \
      "${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}" \
      "${AMNEZIAWG_IP:-10.200.97.3}"
    exit 0
  fi
  echo "[route] ERROR: ${ENV_FILE} not found — run make create-data first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

SUBNET="${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}"
GATEWAY="${AMNEZIAWG_IP:-10.200.97.3}"
NETWORK_NAME="${COMPOSE_NETWORK_NAME:-vpn}"

route_bridge_for_network() {
  if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    local net_id
    net_id="$(docker network inspect "${NETWORK_NAME}" -f '{{.Id}}')"
    echo "br-${net_id:0:12}"
    return 0
  fi
  return 1
}

case "${ACTION}" in
  apply)
    if ! BRIDGE="$(route_bridge_for_network)"; then
      echo "[route] ERROR: docker network '${NETWORK_NAME}' not found — run make up first." >&2
      exit 1
    fi
    if ip route show "${SUBNET}" 2>/dev/null | grep -q "via ${GATEWAY}.*${BRIDGE}"; then
      echo "[route] already set: ${SUBNET} via ${GATEWAY} dev ${BRIDGE}"
      exit 0
    fi
    echo "[route] adding ${SUBNET} via ${GATEWAY} dev ${BRIDGE}"
    sudo ip route add "${SUBNET}" via "${GATEWAY}" dev "${BRIDGE}"
    ;;
  remove|del|delete)
    # Works after make down (network gone): drop any stale host route to the AWG subnet.
    log_and_remove_awg_routes "${SUBNET}" "${GATEWAY}"
    ;;
  status)
    ip route show "${SUBNET}" 2>/dev/null || echo "[route] no route for ${SUBNET}"
    ;;
  *)
    echo "Usage: $0 [apply|remove|status]" >&2
    exit 1
    ;;
esac
