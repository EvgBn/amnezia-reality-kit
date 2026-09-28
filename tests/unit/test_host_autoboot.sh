#!/usr/bin/env bash
# Unit tests for L2 STACK_AUTOBOOT (host_l2_install / host_l2_teardown).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fixture_host_network_sandbox "${TMP}"
export HOST_ENV_FILE="${TMP}/etc/vpn-bridge/env"
export HOST_ENSURE_WRAPPER="${TMP}/usr/local/sbin/vpn-stack-ensure"
export HOST_SYSTEMD_DIR="${TMP}/systemd"
mkdir -p "$(dirname "${HOST_ENV_FILE}")" "$(dirname "${HOST_ENSURE_WRAPPER}")" "${HOST_SYSTEMD_DIR}"

# shellcheck source=../../scripts/lib/host-autoboot.sh
source "${REPO_ROOT}/scripts/lib/host-autoboot.sh"

REPO_FAKE="${TMP}/repo"
mkdir -p "${REPO_FAKE}/scripts/deployment"
cp "${REPO_ROOT}/scripts/deployment/vpn-stack-ensure.sh" "${REPO_FAKE}/scripts/deployment/"

host_l2_install "${REPO_FAKE}" "${REPO_FAKE}/scripts/deployment" \
  || fail "host_l2_install failed"

[[ -f "${HOST_ENV_FILE}" ]] || fail "env file missing after install"
grep -q "^REPO_ROOT=${REPO_FAKE}$" "${HOST_ENV_FILE}" || fail "REPO_ROOT not written"
[[ -x "${HOST_ENSURE_WRAPPER}" ]] || fail "wrapper not installed"
host_systemd_unit_present "${HOST_BOOT_UNIT}" || fail "boot unit missing after install"

host_l2_teardown || fail "host_l2_teardown failed"
[[ -f "${HOST_ENV_FILE}" ]] && fail "env file should be removed"
[[ -f "${HOST_ENSURE_WRAPPER}" ]] && fail "wrapper should be removed"
host_systemd_unit_present "${HOST_BOOT_UNIT}" && fail "boot unit should be removed"

host_l2_teardown || fail "idempotent teardown should succeed"

LEGACY="${HOST_SYSTEMD_DIR}/amneziawg-module.service"
echo '[Unit]' > "${LEGACY}"
host_l2_install "${REPO_FAKE}" "${REPO_FAKE}/scripts/deployment" \
  || fail "install after legacy unit failed"
[[ -f "${LEGACY}" ]] && fail "legacy unit should be migrated away"

host_l2_artifacts_present || fail "artifacts should be present after install"
host_l2_teardown >/dev/null
host_l2_artifacts_present && fail "artifacts should be absent after teardown"

echo "OK: test_host_autoboot"
