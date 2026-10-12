#!/usr/bin/env bash
# Phase 2: host OS (Ubuntu, memory for builds).

preflight_phase_02_os() {
  phase_header "Phase 2: OS"

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]] && awk -v v="${VERSION_ID:-0}" 'BEGIN { exit !(v >= 24.04) }'; then
      emit OK OS ubuntu "Ubuntu ${VERSION_ID}"
    elif [[ "${ID:-}" == "ubuntu" ]]; then
      emit WARN OS ubuntu "Ubuntu ${VERSION_ID:-?} (24.04+ recommended)" \
        "upgrade or accept unsupported OS"
    else
      emit WARN OS ubuntu "ID=${ID:-unknown} (Ubuntu 24.04+ recommended)" \
        "use Ubuntu 24.04+"
    fi
  else
    emit WARN OS os-release "/etc/os-release missing" "verify OS manually"
  fi

  local swap_kb ram_kb detail awg_image image_present kmod_path kmod_present
  swap_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  detail="$(preflight_os_memory_detail "${ram_kb}" "${swap_kb}")"

  awg_image="$(preflight_awg_image_ref)"
  image_present=false
  if preflight_docker_accessible \
    && docker image inspect "${awg_image}" >/dev/null 2>&1; then
    image_present=true
  fi

  kmod_path="$(host_l1_module_path "$(uname -r)")"
  kmod_present=false
  [[ -f "${kmod_path}" ]] && kmod_present=true

  # SKIP only when both heavy paths are done (compose image + host kmod from deploy-host).
  if [[ "${image_present}" == true && "${kmod_present}" == true ]]; then
    emit SKIP OS memory "${detail}; ${awg_image} and host kmod present"
  elif preflight_os_memory_sufficient "${ram_kb}" "${swap_kb}"; then
    if [[ "${image_present}" == true && "${kmod_present}" != true ]]; then
      emit OK OS memory \
        "${detail}; ${awg_image} local — deploy-host/kmod may still need RAM"
    else
      emit OK OS memory "${detail}"
    fi
  elif [[ "${image_present}" == true && "${kmod_present}" != true ]]; then
    emit WARN OS memory \
      "${detail}; ${awg_image} local but host kmod missing (deploy-host is memory-heavy)" \
      "if build exits Killed (137), add ≥2G swap before sudo make deploy-host"
  else
    emit WARN OS memory "${detail} (low for make images / deploy-host)" \
      "if build exits Killed (137), add ≥2G swap"
  fi
}
