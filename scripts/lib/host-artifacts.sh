#!/usr/bin/env bash
# Single source of truth for host-level units and drop-ins (deploy-host / host-remove / preflight).
#
# Host bootstrap layers (deploy-host):
#   L0 BASE_HOST      — HOST_L0_* ; always on, no operator flag
#   L1 AWG_KMOD_HOST  — HOST_L1_DROPINS
#   L2 STACK_AUTOBOOT — HOST_BOOT_UNIT, HOST_ENSURE_WRAPPER, HOST_ENV_FILE
# shellcheck disable=SC2034

HOST_FIREWALL_UNIT="${HOST_FIREWALL_UNIT:-vpn-host-firewall.service}"
HOST_BOOT_UNIT="${HOST_BOOT_UNIT:-vpn-stack-boot.service}"

# L0 BASE_HOST — ip_forward sysctl.conf line is intentional (not tracked here).
HOST_L0_UNITS=(
  "${HOST_FIREWALL_UNIT}"
)
HOST_L0_DROPINS=(
  /etc/sysctl.d/99-vpn-conntrack.conf
  /etc/modprobe.d/vpn-conntrack.conf
  /etc/modules-load.d/vpn-conntrack.conf
)

# L1 AWG_KMOD_HOST
HOST_L1_DROPINS=(
  /etc/modules-load.d/amneziawg.conf
)

# L2 STACK_AUTOBOOT — deploy-time flag ENABLE_STACK_AUTOBOOT (default on).
HOST_ENSURE_WRAPPER="${HOST_ENSURE_WRAPPER:-/usr/local/sbin/vpn-stack-ensure}"
HOST_ENV_FILE="${HOST_ENV_FILE:-/etc/vpn-bridge/env}"
HOST_L2_UNITS=(
  "${HOST_BOOT_UNIT}"
)
HOST_L2_LEGACY_UNITS=(
  amneziawg-module.service
)
HOST_L2_INSTALL_PATHS=(
  "${HOST_ENSURE_WRAPPER}"
  "${HOST_ENV_FILE}"
)

# Previous boot unit names — alias of HOST_L2_LEGACY_UNITS (registry / guards).
HOST_BOOT_UNIT_LEGACY=(
  "${HOST_L2_LEGACY_UNITS[@]}"
)

HOST_DEPLOY_UNITS=(
  "${HOST_FIREWALL_UNIT}"
  "${HOST_BOOT_UNIT}"
)

HOST_LEGACY_UNITS=(
  vpn-awg-route.service
  "${HOST_BOOT_UNIT_LEGACY[@]}"
)

# host-remove: firewall + legacy units; L2 boot unit via host_l2_teardown; L1 kmod via kmod_remove_run.
HOST_REMOVE_SYSTEMD_UNITS=(
  "${HOST_FIREWALL_UNIT}"
  vpn-awg-route.service
  "${HOST_BOOT_UNIT_LEGACY[@]}"
)

HOST_ALL_KNOWN_UNITS=(
  "${HOST_DEPLOY_UNITS[@]}"
  "${HOST_LEGACY_UNITS[@]}"
)

HOST_DROPIN_FILES=(
  "${HOST_L0_DROPINS[@]}"
  "${HOST_L1_DROPINS[@]}"
)

# L2 install paths (alias for guards).
HOST_INSTALL_PATHS=(
  "${HOST_L2_INSTALL_PATHS[@]}"
)

# Preflight phase 6 legacy rows: unit|fix_hint (registry.sh builds deploy rows from HOST_DEPLOY_UNITS).
HOST_LEGACY_UNIT_HINTS=(
  "vpn-awg-route.service|legacy unit — sudo make host-remove"
  "amneziawg-module.service|renamed to ${HOST_BOOT_UNIT} — sudo make deploy-host"
)
