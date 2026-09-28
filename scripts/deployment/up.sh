#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/stack-state.sh
source "${SCRIPT_DIR}/../lib/stack-state.sh"

CMD="${1:-}"

stop_vpn_containers_fallback() {
  local c
  for c in vpn-xray vpn-amneziawg vpn-coredns vpn-teleproxy; do
    docker stop "${c}" 2>/dev/null || true
    docker rm "${c}" 2>/dev/null || true
  done
  docker network rm "${COMPOSE_NETWORK_NAME:-vpn}" 2>/dev/null || true
}

_mark_down_stopped() {
  stack_state_mark_stopped
  echo "[down] Stack will stay down after reboot until: make start"
}

if [[ "${CMD}" == "down" ]]; then
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vpn-'; then
    echo "[down] Nothing to stop — no vpn-* containers running."
    _mark_down_stopped
    echo "[down] Fresh clone? Run: make create-data && make first-start"
    exit 0
  fi
  if [[ ! -f "${COMPOSE_FILE}" || ! -f "${ENV_FILE}" ]]; then
    echo "[down] WARN: ${COMPOSE_FILE} or ${ENV_FILE} missing — stopping vpn-* without compose."
    stop_vpn_containers_fallback
    _mark_down_stopped
    echo "[down] Stopped. Next: make create-data (if new) or make start"
    exit 0
  fi
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "[up] ERROR: ${COMPOSE_FILE} not found — run: make create-data" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[up] ERROR: ${ENV_FILE} not found — run: make create-data" >&2
  exit 1
fi

if [[ "${CMD}" == "up" || "${CMD}" == "start" ]]; then
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
  rc=$?
  if [[ "${rc}" -eq 0 ]] && systemctl is-enabled xray-tproxy.service >/dev/null 2>&1; then
    systemctl disable --now xray-tproxy.service >/dev/null 2>&1 || true
  fi
  exit "${rc}"
fi

if [[ "${CMD}" == "down" ]]; then
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
  _mark_down_stopped
  exit 0
fi

exec docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
