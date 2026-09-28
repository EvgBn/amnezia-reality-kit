#!/usr/bin/env bash
# Phase 6: HOST SVC — vpn-host-firewall, vpn-stack-boot (+ legacy units).

preflight_systemd_unit_file_present() {
  local unit="$1"
  [[ -f "/etc/systemd/system/${unit}" ]]
}

preflight_phase_06_host_svc() {
  phase_header "Phase 6: Host services"

  local entry unit fix boot_label
  boot_label="${HOST_BOOT_UNIT%.service}"

  if preflight_boot_unit_enabled && preflight_boot_unit_failed; then
    emit FAIL HOSTSVC "${boot_label}" "unit failed" \
      "sudo journalctl -u ${HOST_BOOT_UNIT} -b --no-pager | tail -20; sudo make deploy-host"
  fi

  for entry in "${PREFLIGHT_HOST_UNITS[@]}"; do
    unit="${entry%%|*}"
    fix="${entry#*|}"
    if [[ "${unit}" == "${HOST_BOOT_UNIT}" ]] && ! preflight_l2_autoboot_expected; then
      emit SKIP HOSTSVC "${unit%.service}" "autoboot disabled (no L2 artifacts)"
      continue
    fi
    if preflight_systemd_unit_enabled "${unit}"; then
      if [[ "${unit}" == "${HOST_BOOT_UNIT}" ]] && preflight_boot_unit_failed; then
        continue
      fi
      emit OK HOSTSVC "${unit%.service}" "enabled"
    else
      emit WARN HOSTSVC "${unit%.service}" "not enabled" "${fix}"
    fi
  done

  for entry in "${PREFLIGHT_HOST_LEGACY_UNITS[@]}"; do
    unit="${entry%%|*}"
    fix="${entry#*|}"
    if [[ "${unit}" == "amneziawg-module.service" ]]; then
      if preflight_legacy_boot_unit_unmigrated "${unit}"; then
        emit FAIL HOSTSVC "${unit%.service}" "legacy unit file (not migrated)" "${fix}"
      elif [[ -e "${PREFLIGHT_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${unit}" \
        || -L "${PREFLIGHT_SYSTEMD_UNIT_DIR:-/etc/systemd/system}/${unit}" ]]; then
        emit OK HOSTSVC "${unit%.service}" "alias → ${HOST_BOOT_UNIT%.service}"
      elif [[ "${VERBOSE}" -eq 1 ]]; then
        emit OK HOSTSVC "${unit%.service}" "not installed"
      fi
      continue
    fi
    if preflight_systemd_unit_file_present "${unit}" || preflight_systemd_unit_enabled "${unit}"; then
      preflight_emit WARN HOSTSVC "${unit%.service}" "legacy unit present" "${fix}"
    elif [[ "${VERBOSE}" -eq 1 ]]; then
      emit OK HOSTSVC "${unit%.service}" "not installed"
    fi
  done
}
