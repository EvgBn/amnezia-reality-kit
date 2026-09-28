#!/usr/bin/env bash
# AmneziaWG kernel module removal — testable via MODULE_PATH, PROC_MODULES, DOCKER, MODPROBE overrides.

# shellcheck source=host-awg-kmod.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host-awg-kmod.sh"

kmod_remove_run() {
  local HOST_REPO STACK_REPO

  HOST_REPO="$(read_host_repo_root)"
  STACK_REPO="${HOST_REMOVE_STACK_REPO:-${HOST_REPO:-${REPO_ROOT}}}"

  if [[ -n "${HOST_REPO}" && "${HOST_REPO}" != "${REPO_ROOT}" ]]; then
    log_warn "Host stack registered at ${HOST_REPO} (${HOST_ENV_FILE})."
    log_warn "This clone is ${REPO_ROOT} — kernel removal is host-wide; stack ops use the registered path."
  fi

  if ! host_l1_teardown; then
    return 1
  fi

  log_info "Done. Reinstall: cd ${STACK_REPO} && sudo make deploy-host"
  return 0
}
