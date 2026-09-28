#!/usr/bin/env bash
# Phase 4: AmneziaWG kernel module (awg0 in container).

preflight_phase_04_kernel() {
  phase_header "Phase 4: Kernel (AmneziaWG)"

  local kver module_path boot_label unit_file exec_path host_repo
  kver="$(uname -r)"
  module_path="/lib/modules/${kver}/extra/amneziawg.ko"
  boot_label="${HOST_BOOT_UNIT%.service}"

  if preflight_l1_kmod_expected; then
    if grep -q '^amneziawg ' /proc/modules 2>/dev/null; then
      emit OK KERNEL amneziawg "module loaded"
    elif modprobe amneziawg 2>/dev/null; then
      emit OK KERNEL amneziawg "modprobe succeeded"
    else
      emit FAIL KERNEL amneziawg "module not available" \
        "sudo make deploy-host (or sudo ./scripts/maintenance/rebuild-amneziawg.sh)"
    fi

    if [[ -f "${module_path}" ]]; then
      emit OK KERNEL amneziawg.ko "present for ${kver}"
    else
      emit WARN KERNEL amneziawg.ko "missing for ${kver}" \
        "sudo make deploy-host after kernel upgrade"
    fi
  else
    emit SKIP KERNEL amneziawg "L1 kmod not deployed (no artifacts / AWG not in compose)"
  fi

  if preflight_l2_autoboot_expected; then
    if preflight_boot_unit_enabled; then
    unit_file="/etc/systemd/system/${HOST_BOOT_UNIT}"
    exec_path="$(grep '^ExecStart=' "${unit_file}" 2>/dev/null | sed 's/^ExecStart=//' | tr -d '\r' || true)"
    if [[ -z "${exec_path}" || ! -x "${exec_path}" ]]; then
      emit FAIL KERNEL "${boot_label}" "ExecStart missing or not executable" \
        "sudo make deploy-host"
    elif [[ "${exec_path}" != "${HOST_ENSURE_WRAPPER}" ]]; then
      emit FAIL KERNEL "${boot_label}" "ExecStart not portable wrapper (got ${exec_path})" \
        "sudo make deploy-host"
    elif [[ ! -x "${VPN_STACK_BOOT_SCRIPT}" ]]; then
      emit FAIL KERNEL vpn-stack-boot "missing in clone (${VPN_STACK_BOOT_SCRIPT})" \
        "verify REPO_ROOT; sudo make deploy-host"
    elif preflight_boot_unit_failed; then
      emit FAIL KERNEL "${boot_label}" "unit failed" \
        "sudo journalctl -u ${HOST_BOOT_UNIT} -b --no-pager | tail -20; sudo make deploy-host"
    else
      emit OK KERNEL "${boot_label}" "unit enabled"
    fi

    wrapper_src="${REPO_ROOT}/scripts/deployment/vpn-stack-ensure.sh"
    if [[ -x "${HOST_ENSURE_WRAPPER}" && -f "${wrapper_src}" ]] \
      && ! cmp -s "${HOST_ENSURE_WRAPPER}" "${wrapper_src}" 2>/dev/null; then
      preflight_emit WARN KERNEL vpn-stack-ensure "installed wrapper differs from repo" \
        "sudo make deploy-host"
    fi

    if [[ -f "${HOST_ENV_FILE}" ]]; then
      host_repo="$(grep '^REPO_ROOT=' "${HOST_ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
      if [[ -z "${host_repo}" ]]; then
        emit WARN KERNEL vpn-bridge-env "REPO_ROOT missing" "sudo make deploy-host"
      elif [[ "${host_repo}" == "${REPO_ROOT}" ]]; then
        emit OK KERNEL vpn-bridge-env "REPO_ROOT matches repo"
      else
        emit FAIL KERNEL vpn-bridge-env "REPO_ROOT mismatch (env=${host_repo})" \
          "sudo make deploy-host"
      fi
    else
      emit WARN KERNEL vpn-bridge-env "missing ${HOST_ENV_FILE}" "sudo make deploy-host"
    fi
    else
      emit WARN KERNEL "${boot_label}" "unit not enabled" "sudo ENABLE_STACK_AUTOBOOT=1 make deploy-host"
    fi
  else
    emit SKIP KERNEL "${boot_label}" "autoboot disabled (no L2 artifacts)"
  fi
}
