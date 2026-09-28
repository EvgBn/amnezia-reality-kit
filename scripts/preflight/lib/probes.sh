#!/usr/bin/env bash
# Shared probe helpers for preflight phases.

_PREFLIGHT_PROBES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/host-awg-kmod.sh
source "${_PREFLIGHT_PROBES_DIR}/../../lib/host-awg-kmod.sh"

preflight_docker_accessible() {
  docker info >/dev/null 2>&1
}

preflight_stack_any_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vpn-'
}

# .data/ initialized (deployed at least once)
preflight_stack_configured() {
  [[ -f "${COMPOSE_FILE:-}" ]] && [[ -f "${ENV_FILE:-}" ]]
}

preflight_port_in_use() {
  local proto="$1" port="$2"
  case "${proto}" in
    tcp) ss -Hltn 2>/dev/null | grep -qE ":${port}([^0-9]|$)" ;;
    udp) ss -Hlun 2>/dev/null | grep -qE ":${port}([^0-9]|$)" ;;
    *) return 1 ;;
  esac
}

preflight_systemd_unit_enabled() {
  local unit="$1"
  systemctl is-enabled "${unit}" >/dev/null 2>&1
}

preflight_boot_unit_enabled() {
  preflight_systemd_unit_enabled "${HOST_BOOT_UNIT}"
}

preflight_boot_unit_failed() {
  preflight_boot_unit_enabled \
    && systemctl is-failed --quiet "${HOST_BOOT_UNIT}" 2>/dev/null
}

preflight_legacy_boot_unit_unmigrated() {
  local unit="$1"
  local dir="${PREFLIGHT_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local path="${dir}/${unit}"

  [[ -e "${path}" || -L "${path}" ]] || return 1

  if [[ "${unit}" == "amneziawg-module.service" ]]; then
    if [[ -L "${path}" ]]; then
      local target base
      target="$(readlink -f "${path}" 2>/dev/null || readlink "${path}")"
      base="$(basename "${target}")"
      [[ "${base}" == "${HOST_BOOT_UNIT}" ]] && return 1
      return 0
    elif [[ -f "${path}" ]]; then
      return 0
    fi
    return 1
  fi

  [[ -f "${path}" ]] || [[ -L "${path}" ]]
}

# L2 STACK_AUTOBOOT expected when deploy-host installed autoboot artifacts.
preflight_l2_autoboot_expected() {
  [[ -f "${HOST_ENV_FILE}" ]] \
    || [[ -x "${HOST_ENSURE_WRAPPER}" ]] \
    || [[ -f "${PREFLIGHT_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${HOST_BOOT_UNIT}" ]]
}

# L1 AWG_KMOD_HOST expected when deploy artifacts exist or rendered compose includes AWG.
preflight_l1_kmod_expected() {
  if host_l1_artifacts_present; then
    return 0
  fi
  [[ -f "${COMPOSE_FILE:-}" ]] \
    && component_enabled "${AWG_SERVICE}" "${COMPOSE_FILE}"
}
