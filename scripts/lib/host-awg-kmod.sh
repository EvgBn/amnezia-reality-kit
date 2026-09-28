#!/usr/bin/env bash
# L1 AWG_KMOD_HOST — amneziawg.ko and modules-load.d/amneziawg.conf.
# Controlled by ENABLE_AWG_KMOD_HOST at deploy-host time (default on).
# Teardown symmetry: deploy-host (=0), kmod-remove, host-remove (via kmod_remove_run).

_host_awg_kmod_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-artifacts.sh
source "${_host_awg_kmod_lib_dir}/host-artifacts.sh"
# shellcheck source=paths.sh
source "${_host_awg_kmod_lib_dir}/paths.sh"
# shellcheck source=host-network.sh
source "${_host_awg_kmod_lib_dir}/host-network.sh"

_host_l1_modprobe() {
  "${MODPROBE:-modprobe}" "$@"
}

_host_l1_depmod() {
  "${DEPMOD:-depmod}" "$@"
}

host_l1_modules_load_conf() {
  printf '%s' "${AMNEZIAWG_MODULES_LOAD_CONF:-/etc/modules-load.d/amneziawg.conf}"
}

host_l1_module_path() {
  local kver="${1:-$(uname -r)}"
  printf '%s' "${MODULE_PATH:-/lib/modules/${kver}/extra/amneziawg.ko}"
}

host_l1_proc_modules() {
  printf '%s' "${PROC_MODULES:-/proc/modules}"
}

host_l1_artifacts_present() {
  [[ -f "$(host_l1_modules_load_conf)" ]] \
    || [[ -f "$(host_l1_module_path)" ]]
}

_host_l1_awg_container_running() {
  _host_docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${AWG_CONTAINER}"
}

_host_l1_container_block_message() {
  local stack_repo="${HOST_REMOVE_STACK_REPO:-${REPO_ROOT}}"
  local stack_env="${HOST_REMOVE_STACK_ENV:-${stack_repo}/.data/.env}"
  local stack_compose="${stack_repo}/.data/build/docker-compose.yml"

  log_error "Container '${AWG_CONTAINER}' is running. Stop the stack first:"
  if [[ -f "${stack_compose}" ]]; then
    log_error "  cd ${stack_repo} && make down"
    log_error "  # or: docker compose -f ${stack_compose} --env-file ${stack_env} stop ${AWG_SERVICE}"
  else
    log_error "  docker stop ${AWG_CONTAINER}"
  fi
}

host_l1_install() {
  local modules_load_conf
  modules_load_conf="$(host_l1_modules_load_conf)"

  if grep -q '^amneziawg ' "$(host_l1_proc_modules)" 2>/dev/null; then
    log_info "AmneziaWG kernel module already loaded."
  elif _host_l1_modprobe amneziawg 2>/dev/null; then
    log_info "AmneziaWG kernel module loaded from existing install."
  else
    log_info "Building AmneziaWG kernel module via rebuild-amneziawg.sh…"
    "${REBUILD_SCRIPT}"
  fi

  if [[ ! -f "${modules_load_conf}" ]]; then
    echo amneziawg > "${modules_load_conf}"
    log_info "Persisted module autoload: ${modules_load_conf}"
  fi
}

host_l1_teardown() {
  local kernel_version modules_load_conf module_path proc_modules

  kernel_version="$(uname -r)"
  modules_load_conf="$(host_l1_modules_load_conf)"
  module_path="$(host_l1_module_path "${kernel_version}")"
  proc_modules="$(host_l1_proc_modules)"

  if _host_l1_awg_container_running; then
    _host_l1_container_block_message
    return 1
  fi

  log_info "Removing AmneziaWG kernel module (kernel ${kernel_version})…"

  if grep -q '^amneziawg ' "${proc_modules}" 2>/dev/null; then
    log_info "Unloading amneziawg module…"
    if ! _host_l1_modprobe -r amneziawg; then
      log_error "modprobe -r amneziawg failed."
      log_error "Ensure no awg0 / WireGuard interfaces are up, then retry."
      return 1
    fi
    log_info "Module unloaded."
  else
    log_info "Module not loaded."
  fi

  if [[ -f "${modules_load_conf}" ]]; then
    rm -f "${modules_load_conf}"
    log_info "Removed ${modules_load_conf}"
  fi

  if [[ -f "${module_path}" ]]; then
    rm -f "${module_path}"
    _host_l1_depmod -a "${kernel_version}" 2>/dev/null || _host_l1_depmod -a
    log_info "Removed ${module_path}"
  else
    log_info "No module file at ${module_path}"
  fi

  return 0
}
