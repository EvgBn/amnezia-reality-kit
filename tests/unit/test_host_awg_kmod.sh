#!/usr/bin/env bash
# Unit tests for L1 AWG_KMOD_HOST (host_l1_install / host_l1_teardown).
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

fixture_host_network_sandbox_integration "${TMP}"
export DOCKER_MOCK_PS=''
export MODPROBE_LOG="${MODPROBE_MOCK_LOG}"
export AMNEZIAWG_MODULES_LOAD_CONF="${FIXTURE_HN_AMNEZIAWG_CONF}"
export MODULE_PATH="${FIXTURE_HN_MODULE_PATH}"
export PROC_MODULES="${FIXTURE_HN_PROC_MODULES}"

# shellcheck source=../../scripts/lib/host-awg-kmod.sh
source "${REPO_ROOT}/scripts/lib/host-awg-kmod.sh"

REBUILD_MOCK="${TMP}/rebuild-mock.sh"
cat > "${REBUILD_MOCK}" <<'EOF'
#!/usr/bin/env bash
echo amneziawg > "${AMNEZIAWG_MODULES_LOAD_CONF}"
touch "${MODULE_PATH}"
EOF
chmod +x "${REBUILD_MOCK}"
export REBUILD_SCRIPT="${REBUILD_MOCK}"

# install path when module missing → rebuild mock
: > "${PROC_MODULES}"
host_l1_install || fail "host_l1_install failed"
[[ -f "${AMNEZIAWG_MODULES_LOAD_CONF}" ]] || fail "modules-load conf missing after install"
[[ -f "${MODULE_PATH}" ]] || fail "module file missing after install"

# teardown
printf 'amneziawg 0 0 - Live 0\n' > "${PROC_MODULES}"
host_l1_teardown || fail "host_l1_teardown failed"
[[ -f "${AMNEZIAWG_MODULES_LOAD_CONF}" ]] && fail "modules-load conf should be removed"
[[ -f "${MODULE_PATH}" ]] && fail "module file should be removed"
grep -q '^modprobe -r amneziawg$' "${MODPROBE_LOG}" || fail "modprobe -r not recorded"

host_l1_teardown || fail "idempotent teardown should succeed"

export DOCKER_MOCK_PS='vpn-amneziawg'
if host_l1_teardown >/dev/null 2>&1; then
  fail "teardown should fail when AWG container is running"
fi

echo "OK: test_host_awg_kmod"
