#!/usr/bin/env bash
# Guard: host-artifacts inventory matches deploy-host.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_HOST="${REPO_ROOT}/scripts/deployment/deploy-host.sh"
HOST_BASE="${REPO_ROOT}/scripts/lib/host-base.sh"
HOST_AUTOBOOT="${REPO_ROOT}/scripts/lib/host-autoboot.sh"
HOST_AWG_KMOD="${REPO_ROOT}/scripts/lib/host-awg-kmod.sh"

# shellcheck source=../../scripts/lib/host-artifacts.sh
source "${REPO_ROOT}/scripts/lib/host-artifacts.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "${DEPLOY_HOST}" ]] || fail "missing deploy-host.sh"
[[ -f "${HOST_BASE}" ]] || fail "missing host-base.sh"
[[ -f "${HOST_AUTOBOOT}" ]] || fail "missing host-autoboot.sh"
[[ -f "${HOST_AWG_KMOD}" ]] || fail "missing host-awg-kmod.sh"

grep -q 'host_l0_install' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l0_install (L0 BASE_HOST)"
grep -q 'HOST_FIREWALL_UNIT' "${HOST_BASE}" \
  || fail "host-base.sh must install ${HOST_FIREWALL_UNIT}"
grep -q 'host_l2_install' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l2_install (L2)"
grep -q 'HOST_BOOT_UNIT' "${HOST_AUTOBOOT}" \
  || fail "host-autoboot.sh must install unit via HOST_BOOT_UNIT (${HOST_BOOT_UNIT})"
grep -q 'ExecStart=${HOST_ENSURE_WRAPPER}' "${HOST_AUTOBOOT}" \
  || fail "host-autoboot.sh must use HOST_ENSURE_WRAPPER in unit ExecStart"
grep -q 'HOST_ENSURE_WRAPPER' "${HOST_AUTOBOOT}" \
  || fail "host-autoboot.sh must install ${HOST_ENSURE_WRAPPER}"
grep -q 'host_l1_install' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l1_install (L1)"
grep -q 'host_l1_install' "${HOST_AWG_KMOD}" \
  || fail "host-awg-kmod.sh must define host_l1_install"

for p in "${HOST_INSTALL_PATHS[@]}"; do
  case "${p}" in
    "${HOST_ENSURE_WRAPPER}")
      grep -q 'HOST_ENSURE_WRAPPER' "${HOST_AUTOBOOT}" \
        || fail "host-autoboot.sh must install ${HOST_ENSURE_WRAPPER}"
      ;;
    "${HOST_ENV_FILE}")
      grep -q 'HOST_ENV_FILE' "${HOST_AUTOBOOT}" \
        || fail "host-autoboot.sh must write ${HOST_ENV_FILE}"
      ;;
    *)
      grep -qF "${p}" "${DEPLOY_HOST}" \
        || fail "deploy-host.sh must reference path ${p}"
      ;;
  esac
done

HOST_REMOVE_LIB="${REPO_ROOT}/scripts/lib/host-remove-lib.sh"
grep -q 'host_l2_teardown' "${HOST_REMOVE_LIB}" \
  || fail "host-remove-lib.sh must call host_l2_teardown"
grep -q '${HOST_ENSURE_WRAPPER}' "${HOST_REMOVE_LIB}" \
  && fail "host-remove-lib.sh must not inline-remove HOST_ENSURE_WRAPPER (use host_l2_teardown)"

printf '%s\n' "${HOST_DEPLOY_UNITS[@]}" | grep -qxF "${HOST_BOOT_UNIT}" \
  || fail "HOST_BOOT_UNIT missing from HOST_DEPLOY_UNITS"
printf '%s\n' "${HOST_DEPLOY_UNITS[@]}" | grep -qxF "${HOST_BOOT_UNIT}" \
  && printf '%s\n' "${HOST_LEGACY_UNITS[@]}" | grep -qxF "${HOST_BOOT_UNIT}" \
  && fail "HOST_BOOT_UNIT must not be in HOST_LEGACY_UNITS"

printf '%s\n' "${HOST_LEGACY_UNITS[@]}" | grep -qxF 'vpn-awg-route.service' \
  || fail "vpn-awg-route missing from HOST_LEGACY_UNITS"
printf '%s\n' "${HOST_LEGACY_UNITS[@]}" | grep -qxF 'amneziawg-module.service' \
  || fail "amneziawg-module missing from HOST_LEGACY_UNITS (migration)"

echo "OK: test_host_artifacts_inventory"
