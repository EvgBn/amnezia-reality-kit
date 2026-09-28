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

  local swap_kb ram_kb
  swap_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${swap_kb}" -ge 1048576 ]] || [[ "${ram_kb}" -ge 2097152 ]]; then
    emit OK OS memory "swap=$((swap_kb / 1024))MiB ram=$((ram_kb / 1024))MiB"
  else
    emit WARN OS memory "low swap/RAM for image build (swap=$((swap_kb / 1024))MiB)" \
      "add 2G swap before make images"
  fi
}
