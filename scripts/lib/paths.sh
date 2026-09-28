#!/usr/bin/env bash
# Shared repository paths — source from any script under scripts/
# shellcheck disable=SC2034

if [[ -z "${REPO_ROOT:-}" ]]; then
  _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${_lib_dir}/../.." && pwd)"
  unset _lib_dir
fi

DATA_DIR="${DATA_DIR:-${REPO_ROOT}/.data}"
BUILD_DIR="${BUILD_DIR:-${DATA_DIR}/build}"
# Legacy rename: .data/generated/ → .data/build/
_legacy_build="${DATA_DIR}/generated"
if [[ -d "${_legacy_build}" && ! -e "${BUILD_DIR}" ]]; then
  mv "${_legacy_build}" "${BUILD_DIR}"
fi
unset _legacy_build

AWG_CLIENTS_DIR="${AWG_CLIENTS_DIR:-${DATA_DIR}/clients_awg}"
# Legacy rename: .data/clients/ → .data/clients_awg/
_legacy_clients="${DATA_DIR}/clients"
if [[ -d "${_legacy_clients}" && ! -e "${AWG_CLIENTS_DIR}" ]]; then
  mv "${_legacy_clients}" "${AWG_CLIENTS_DIR}"
fi
unset _legacy_clients

XRAY_CLIENTS_DIR="${XRAY_CLIENTS_DIR:-${DATA_DIR}/clients_xray}"
MTPROXY_CLIENTS_DIR="${MTPROXY_CLIENTS_DIR:-${DATA_DIR}/clients_mtproxy}"
BUILD_SNAPSHOTS_DIR="${BUILD_SNAPSHOTS_DIR:-${DATA_DIR}/build-snapshots}"
# Legacy rename: .data/build-snapshots/ → .data/build-snapshots/
_legacy_snapshots="${DATA_DIR}/backups"
if [[ -d "${_legacy_snapshots}" && ! -e "${BUILD_SNAPSHOTS_DIR}" ]]; then
  mv "${_legacy_snapshots}" "${BUILD_SNAPSHOTS_DIR}"
fi
unset _legacy_snapshots
COMPOSE_FILE="${COMPOSE_FILE:-${BUILD_DIR}/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-${DATA_DIR}/.env}"
CONFIG_STATIC="${REPO_ROOT}/config/static"
CONFIG_TEMPLATES="${REPO_ROOT}/config/templates"
CONTAINERS_DIR="${REPO_ROOT}/containers"

AWG_CONF="${AWG_CONF:-${BUILD_DIR}/awg0.conf}"
AWG_LOCK="${AWG_LOCK:-${AWG_CONF}.lock}"
AWG_CONTAINER="${AWG_CONTAINER:-vpn-amneziawg}"
AWG_SERVICE="${AWG_SERVICE:-amneziawg}"
XRAY_CONF="${XRAY_CONF:-${BUILD_DIR}/config.json}"
XRAY_LOCK="${XRAY_LOCK:-${XRAY_CONF}.lock}"
XRAY_CONTAINER="${XRAY_CONTAINER:-vpn-xray}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"

SCRIPTS_DIR="${SCRIPTS_DIR:-${REPO_ROOT}/scripts}"
MAINTENANCE_DIR="${MAINTENANCE_DIR:-${SCRIPTS_DIR}/maintenance}"
DEPLOYMENT_DIR="${DEPLOYMENT_DIR:-${SCRIPTS_DIR}/deployment}"
REBUILD_SCRIPT="${REBUILD_SCRIPT:-${MAINTENANCE_DIR}/rebuild-amneziawg.sh}"
VPN_STACK_BOOT_SCRIPT="${VPN_STACK_BOOT_SCRIPT:-${MAINTENANCE_DIR}/vpn-stack-boot.sh}"
ROUTE_SCRIPT="${ROUTE_SCRIPT:-${MAINTENANCE_DIR}/vpn-awg-route.sh}"
HOST_ENV_FILE="${HOST_ENV_FILE:-/etc/vpn-bridge/env}"
STACK_STOPPED_FILE="${STACK_STOPPED_FILE:-${DATA_DIR}/.stack-stopped}"

# read_host_repo_root — print REPO_ROOT from deploy-host (empty if unset).
read_host_repo_root() {
  if [[ -f "${HOST_ENV_FILE}" ]]; then
    grep '^REPO_ROOT=' "${HOST_ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true
  fi
}
