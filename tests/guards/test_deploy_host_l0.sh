#!/usr/bin/env bash
# Guard: L0 BASE_HOST is unconditional in deploy-host (no ENABLE_HOST_BASE flag).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_HOST="${REPO_ROOT}/scripts/deployment/deploy-host.sh"
HOST_BASE="${REPO_ROOT}/scripts/lib/host-base.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "${DEPLOY_HOST}" ]] || fail "missing deploy-host.sh"
[[ -f "${HOST_BASE}" ]] || fail "missing host-base.sh"

grep -q 'host_l0_install' "${DEPLOY_HOST}" \
  || fail "deploy-host.sh must call host_l0_install"
grep -q 'host_l0_install' "${HOST_BASE}" \
  || fail "host-base.sh must define host_l0_install"

l0_line="$(grep -n 'host_l0_install' "${DEPLOY_HOST}" | head -1 | cut -d: -f1)"
flag_line="$(grep -n 'parse_bool "\${ENABLE_STACK_AUTOBOOT' "${DEPLOY_HOST}" | head -1 | cut -d: -f1)"
[[ -n "${l0_line}" && -n "${flag_line}" ]] || fail "could not locate L0 / L2 flag lines"
[[ "${l0_line}" -lt "${flag_line}" ]] \
  || fail "host_l0_install must run before ENABLE_STACK_AUTOBOOT is parsed"

if grep -R --exclude-dir=.git -q 'ENABLE_HOST_BASE' \
    "${REPO_ROOT}/scripts" "${REPO_ROOT}/.env.example" 2>/dev/null; then
  fail "ENABLE_HOST_BASE must not be introduced — L0 has no operator flag"
fi

# shellcheck source=../../scripts/lib/host-artifacts.sh
source "${REPO_ROOT}/scripts/lib/host-artifacts.sh"
[[ "${#HOST_L0_DROPINS[@]}" -ge 3 ]] || fail "HOST_L0_DROPINS incomplete"
printf '%s\n' "${HOST_L0_UNITS[@]}" | grep -qxF "${HOST_FIREWALL_UNIT}" \
  || fail "HOST_FIREWALL_UNIT missing from HOST_L0_UNITS"

echo "OK: test_deploy_host_l0"
