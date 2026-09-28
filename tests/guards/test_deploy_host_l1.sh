#!/usr/bin/env bash
# Guard: L1 AWG_KMOD_HOST uses ENABLE_AWG_KMOD_HOST and host-awg-kmod.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_HOST="${REPO_ROOT}/scripts/deployment/deploy-host.sh"
HOST_AWG_KMOD="${REPO_ROOT}/scripts/lib/host-awg-kmod.sh"
HOST_AUTOBOOT="${REPO_ROOT}/scripts/lib/host-autoboot.sh"
KMOD_REMOVE="${REPO_ROOT}/scripts/lib/host-kmod-remove.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "${DEPLOY_HOST}" ]] || fail "missing deploy-host.sh"
[[ -f "${HOST_AWG_KMOD}" ]] || fail "missing host-awg-kmod.sh"

grep -q 'host_l1_install' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l1_install"
grep -q 'host_l1_teardown' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l1_teardown"
grep -q 'host_l1_install' "${HOST_AWG_KMOD}" \
  || fail "host-awg-kmod.sh must define host_l1_install"
grep -q 'ENABLE_AWG_KMOD_HOST' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must parse ENABLE_AWG_KMOD_HOST"
grep -q 'ENABLE_AMNEZIAWG is not a deploy-host flag' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must reject ENABLE_AMNEZIAWG at deploy time"

l2_line="$(grep -n 'parse_bool "${ENABLE_STACK_AUTOBOOT' "${DEPLOY_HOST}" | head -1 | cut -d: -f1)"
l1_line="$(grep -n 'parse_bool "${ENABLE_AWG_KMOD_HOST' "${DEPLOY_HOST}" | head -1 | cut -d: -f1)"
[[ -n "${l2_line}" && -n "${l1_line}" ]] || fail "could not locate L2/L1 parse lines"
[[ "${l2_line}" -lt "${l1_line}" ]] || fail "L2 flag must be parsed before ENABLE_AWG_KMOD_HOST"

if sed -n '/^# ── L1 AWG_KMOD_HOST/,/^log_info "Host bootstrap complete/p' "${DEPLOY_HOST}" \
    | grep -q 'parse_bool "${ENABLE_AMNEZIAWG'; then
  fail "ENABLE_AMNEZIAWG must not gate L1 in deploy-host (use ENABLE_AWG_KMOD_HOST)"
fi

grep -q 'ENABLE_AWG_KMOD_HOST' "${HOST_AUTOBOOT}" \
  && fail "ENABLE_AWG_KMOD_HOST must not appear in host-autoboot.sh (L2)"

grep -q 'host_l1_teardown' "${KMOD_REMOVE}" \
  || fail "host-kmod-remove.sh must call host_l1_teardown"
grep -q 'host_boot_units_remove' "${KMOD_REMOVE}" \
  && fail "kmod-remove must not remove L2 boot units"

# shellcheck source=../../scripts/lib/host-artifacts.sh
source "${REPO_ROOT}/scripts/lib/host-artifacts.sh"
printf '%s\n' "${HOST_L1_DROPINS[@]}" | grep -qxF '/etc/modules-load.d/amneziawg.conf' \
  || fail "HOST_L1_DROPINS incomplete"

echo "OK: test_deploy_host_l1"
