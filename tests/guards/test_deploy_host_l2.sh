#!/usr/bin/env bash
# Guard: L2 STACK_AUTOBOOT uses ENABLE_STACK_AUTOBOOT and host-autoboot.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_HOST="${REPO_ROOT}/scripts/deployment/deploy-host.sh"
HOST_AUTOBOOT="${REPO_ROOT}/scripts/lib/host-autoboot.sh"
HOST_BASE="${REPO_ROOT}/scripts/lib/host-base.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "${DEPLOY_HOST}" ]] || fail "missing deploy-host.sh"
[[ -f "${HOST_AUTOBOOT}" ]] || fail "missing host-autoboot.sh"

grep -q 'host_l2_install' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l2_install"
grep -q 'host_l2_teardown' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l2_teardown"
grep -q 'host_l2_install' "${HOST_AUTOBOOT}" \
  || fail "host-autoboot.sh must define host_l2_install"
grep -q 'ENABLE_STACK_AUTOBOOT' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must parse ENABLE_STACK_AUTOBOOT"

l0_line="$(grep -n 'host_l0_install' "${DEPLOY_HOST}" | head -1 | cut -d: -f1)"
l2_line="$(grep -n 'parse_bool "${ENABLE_STACK_AUTOBOOT' "${DEPLOY_HOST}" | head -1 | cut -d: -f1)"
l1_line="$(grep -n 'parse_bool "${ENABLE_AWG_KMOD_HOST' "${DEPLOY_HOST}" | head -1 | cut -d: -f1)"
[[ -n "${l0_line}" && -n "${l2_line}" && -n "${l1_line}" ]] \
  || fail "could not locate L0/L2/L1 parse lines"
[[ "${l0_line}" -lt "${l2_line}" ]] || fail "L0 must run before ENABLE_STACK_AUTOBOOT"
[[ "${l2_line}" -lt "${l1_line}" ]] || fail "L2 flag must be parsed before ENABLE_AWG_KMOD_HOST"

grep -q 'ENABLE_STACK_AUTOBOOT' "${HOST_BASE}" \
  && fail "ENABLE_STACK_AUTOBOOT must not appear in host-base.sh (L0)"

if sed -n '/^# ── L2 STACK_AUTOBOOT/,/^# ── L1 AWG_KMOD_HOST/p' "${DEPLOY_HOST}" \
    | grep -q 'ENABLE_AMNEZIAWG'; then
  fail "ENABLE_AMNEZIAWG must not appear in L2 block (use ENABLE_STACK_AUTOBOOT only)"
fi

# shellcheck source=../../scripts/lib/host-artifacts.sh
source "${REPO_ROOT}/scripts/lib/host-artifacts.sh"
printf '%s\n' "${HOST_L2_UNITS[@]}" | grep -qxF "${HOST_BOOT_UNIT}" \
  || fail "HOST_BOOT_UNIT missing from HOST_L2_UNITS"
[[ "${#HOST_L2_INSTALL_PATHS[@]}" -ge 2 ]] || fail "HOST_L2_INSTALL_PATHS incomplete"

echo "OK: test_deploy_host_l2"
