#!/usr/bin/env bash
# Host memory heuristics for make images / deploy-host (AWG kmod) builds.
# Units: KiB, same as /proc/meminfo.

# A) RAM ≥ 1.75 GiB
readonly PREFLIGHT_MEM_RAM_OK_KB=$((1792 * 1024))
# B) swap ≥ 1 GiB (explicit operator setup)
readonly PREFLIGHT_MEM_SWAP_OK_KB=$((1024 * 1024))
# C) RAM + swap ≥ 2.5 GiB virtual capacity
readonly PREFLIGHT_MEM_COMBINED_OK_KB=$((2560 * 1024))

preflight_os_memory_sufficient() {
  local ram_kb="$1" swap_kb="$2"
  [[ "${ram_kb}" -ge "${PREFLIGHT_MEM_RAM_OK_KB}" ]] && return 0
  [[ "${swap_kb}" -ge "${PREFLIGHT_MEM_SWAP_OK_KB}" ]] && return 0
  [[ $((ram_kb + swap_kb)) -ge "${PREFLIGHT_MEM_COMBINED_OK_KB}" ]] && return 0
  return 1
}

preflight_os_memory_detail() {
  local ram_kb="$1" swap_kb="$2"
  local total_kb=$((ram_kb + swap_kb))
  printf 'ram=%sMiB swap=%sMiB total=%sMiB' \
    "$((ram_kb / 1024))" "$((swap_kb / 1024))" "$((total_kb / 1024))"
}
