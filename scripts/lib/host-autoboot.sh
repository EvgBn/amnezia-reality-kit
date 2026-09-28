#!/usr/bin/env bash
# L2 STACK_AUTOBOOT — /etc/vpn-bridge/env, vpn-stack-ensure wrapper, vpn-stack-boot.service.
# Controlled by ENABLE_STACK_AUTOBOOT at deploy-host time (default on).
# Teardown symmetry: deploy-host (=0), host-remove (host_l2_teardown).

_host_autoboot_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-artifacts.sh
source "${_host_autoboot_lib_dir}/host-artifacts.sh"
# shellcheck source=host-network.sh
source "${_host_autoboot_lib_dir}/host-network.sh"

host_l2_artifacts_present() {
  [[ -f "${HOST_ENV_FILE}" ]] \
    || [[ -x "${HOST_ENSURE_WRAPPER}" ]] \
    || host_systemd_unit_present "${HOST_BOOT_UNIT}"
}

host_l2_teardown() {
  local unit f removed=0

  for unit in "${HOST_L2_UNITS[@]}" "${HOST_L2_LEGACY_UNITS[@]}"; do
    if host_systemd_unit_remove "${unit}"; then
      log_info "Removed ${unit}"
      removed=$((removed + 1))
    fi
  done
  if [[ "${removed}" -gt 0 ]]; then
    _host_systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  for f in "${HOST_ENSURE_WRAPPER}" "${HOST_ENV_FILE}"; do
    if [[ -f "${f}" ]]; then
      rm -f "${f}"
      log_info "Removed ${f}"
    fi
  done
}

host_l2_install() {
  local repo_root="${1:?repo_root required}"
  local deploy_dir="${2:?deploy_dir required}"
  local wrapper_src="${deploy_dir}/vpn-stack-ensure.sh"
  local unit_path awg_release_env=""

  mkdir -p "$(dirname "${HOST_ENV_FILE}")"
  cat > "${HOST_ENV_FILE}" <<ENV
# Written by deploy-host.sh — do not commit
REPO_ROOT=${repo_root}
ENV
  chmod 644 "${HOST_ENV_FILE}"
  log_info "Wrote ${HOST_ENV_FILE}"

  for unit in "${HOST_L2_LEGACY_UNITS[@]}"; do
    if host_systemd_unit_present "${unit}"; then
      host_systemd_unit_remove "${unit}" || true
      log_info "Migrated away legacy boot unit ${unit}"
    fi
  done

  if [[ ! -f "${wrapper_src}" ]]; then
    log_error "Missing wrapper source: ${wrapper_src}"
    return 1
  fi
  mkdir -p "$(dirname "${HOST_ENSURE_WRAPPER}")"
  install -m 0755 "${wrapper_src}" "${HOST_ENSURE_WRAPPER}"
  log_info "Installed ${HOST_ENSURE_WRAPPER}"

  if [[ -n "${AMNEZIAWG_RELEASE:-}" ]]; then
    awg_release_env="Environment=AMNEZIAWG_RELEASE=${AMNEZIAWG_RELEASE}"
  fi

  unit_path="$(host_systemd_unit_path "${HOST_BOOT_UNIT}")"
  cat > "${unit_path}" <<UNIT
[Unit]
Description=VPN stack boot orchestration (compose, host route)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-${HOST_ENV_FILE}
${awg_release_env}
ExecStart=${HOST_ENSURE_WRAPPER}

[Install]
WantedBy=multi-user.target
Alias=amneziawg-module.service
UNIT

  _host_systemctl daemon-reload
  _host_systemctl enable --now "${HOST_BOOT_UNIT}" >/dev/null
  log_info "Installed ${HOST_BOOT_UNIT} → ${HOST_ENSURE_WRAPPER} (repo via ${HOST_ENV_FILE})"
}
