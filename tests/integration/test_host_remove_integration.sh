#!/usr/bin/env bash
# Integration tests for kmod_remove_run and host_remove_run (no root, no Docker).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"

# shellcheck source=../../scripts/lib/paths.sh
source "${REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/host-network.sh
source "${REPO_ROOT}/scripts/lib/host-network.sh"
# shellcheck source=../../scripts/lib/host-kmod-remove.sh
source "${REPO_ROOT}/scripts/lib/host-kmod-remove.sh"
# shellcheck source=../../scripts/lib/host-remove-lib.sh
source "${REPO_ROOT}/scripts/lib/host-remove-lib.sh"
# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

fail() { echo "FAIL: $1" >&2; exit 1; }

setup_sandbox() {
  TMP="$(mktemp -d)"
  fixture_host_network_sandbox_integration "${TMP}"

  IPTABLES_STATE="${IPTABLES_MOCK_STATE}"
  IP_ROUTES="${IP_MOCK_ROUTES}"
  SYSTEMCTL_LOG="${SYSTEMCTL_MOCK_LOG}"
  MODPROBE_LOG="${MODPROBE_MOCK_LOG}"
  SYSTEMD_DIR="${HOST_SYSTEMD_DIR}"
  ETC_DIR="${FIXTURE_HN_ETC}"
  PROC_MODULES="${PROC_MODULES}"
  MODULE_PATH="${MODULE_PATH}"
  HOST_ENV="${HOST_ENV_FILE}"
  HOST_ENSURE="${HOST_ENSURE_WRAPPER}"
  AMNEZIAWG_CONF="${AMNEZIAWG_MODULES_LOAD_CONF}"
  IPTABLES="${IPTABLES}"
  IP="${IP}"
  SYSTEMCTL="${SYSTEMCTL}"

  HOST_DROPIN_FILES=(
    "${ETC_DIR}/sysctl.d/99-vpn-conntrack.conf"
    "${ETC_DIR}/modprobe.d/vpn-conntrack.conf"
    "${ETC_DIR}/modules-load.d/vpn-conntrack.conf"
    "${AMNEZIAWG_CONF}"
  )
  export HOST_DROPIN_FILES
}

cleanup_sandbox() {
  unset HOST_REMOVE_STACK_REPO HOST_REMOVE_STACK_ENV
  rm -rf "${TMP}"
}

setup_stack_env() {
  local gw="${1:-172.20.0.3}"
  STACK_ROOT="${TMP}/stack"
  mkdir -p "${STACK_ROOT}/.data"
  if [[ "${gw}" == "10.200.97.3" ]]; then
    fixture_copy_data integration/stack-env-gw.env "${STACK_ROOT}/.data/.env"
  else
    cat > "${STACK_ROOT}/.data/.env" <<EOF
AMNEZIAWG_IP=${gw}
AWG_TUNNEL_SUBNET_IPV4=10.8.0.0/24
DOCKER_NETWORK_SUBNET_IPV4=10.200.97.0/24
DOCKER_NETWORK_SUBNET_IPV6=fd87:172:20::/64
EOF
  fi
  export HOST_REMOVE_STACK_REPO="${STACK_ROOT}"
  export HOST_REMOVE_STACK_ENV="${STACK_ROOT}/.data/.env"
}

# ── kmod_remove_run: blocked when AWG container running ───────────────────────
setup_sandbox
trap cleanup_sandbox EXIT
export DOCKER_MOCK_PS='vpn-amneziawg'
if kmod_remove_run >/dev/null 2>&1; then
  fail "kmod_remove_run should fail when AWG container is running"
fi

# ── kmod_remove_run: happy path ───────────────────────────────────────────────
cleanup_sandbox
setup_sandbox
trap cleanup_sandbox EXIT
export DOCKER_MOCK_PS=''
printf 'amneziawg 0 0 - Live 0\n' > "${PROC_MODULES}"
touch "${MODULE_PATH}"
printf 'amneziawg\n' > "${AMNEZIAWG_CONF}"
touch "${SYSTEMD_DIR}/vpn-stack-boot.service"
kmod_remove_run >/dev/null || fail "kmod_remove_run happy path failed"
[[ -f "${MODULE_PATH}" ]] && fail "module file should be removed"
[[ -f "${AMNEZIAWG_CONF}" ]] && fail "modules-load conf should be removed"
[[ -f "${SYSTEMD_DIR}/vpn-stack-boot.service" ]] \
  || fail "vpn-stack-boot unit must remain after kmod-remove (L2 is separate)"
grep -q '^modprobe -r amneziawg$' "${MODPROBE_LOG}" || fail "modprobe -r not recorded"
grep -q '^amneziawg ' "${PROC_MODULES}" && fail "proc modules should no longer list amneziawg"

# ── host_remove_run: blocked when stack container running ─────────────────────
cleanup_sandbox
setup_sandbox
trap cleanup_sandbox EXIT
export DOCKER_MOCK_PS='vpn-xray'
if host_remove_run >/dev/null 2>&1; then
  fail "host_remove_run should fail when vpn-xray is running"
fi

# ── host_remove_run: happy path ───────────────────────────────────────────────
cleanup_sandbox
setup_sandbox
trap cleanup_sandbox EXIT
setup_stack_env "10.200.97.3"
export DOCKER_MOCK_PS=''
echo '10.8.0.0/24 via 10.200.97.3 dev br-test' >> "${IP_ROUTES}"
"${IPTABLES}" -I INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP
touch "${SYSTEMD_DIR}/vpn-host-firewall.service"
touch "${SYSTEMD_DIR}/vpn-awg-route.service"
printf 'x\n' > "${ETC_DIR}/sysctl.d/99-vpn-conntrack.conf"
printf 'x\n' > "${ETC_DIR}/modprobe.d/vpn-conntrack.conf"
printf 'nf_conntrack\n' > "${ETC_DIR}/modules-load.d/vpn-conntrack.conf"
printf 'amneziawg\n' > "${AMNEZIAWG_CONF}"
printf 'REPO_ROOT=%s\n' "${HOST_REMOVE_STACK_REPO}" > "${HOST_ENV}"
printf '# mock wrapper\n' > "${HOST_ENSURE}"
printf 'amneziawg 0 0 - Live 0\n' > "${PROC_MODULES}"
touch "${MODULE_PATH}"
touch "${SYSTEMD_DIR}/vpn-stack-boot.service"

host_remove_run >/dev/null || fail "host_remove_run happy path failed"

[[ -s "${IP_ROUTES}" ]] && fail "routes should be removed"
"${IPTABLES}" -C INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP 2>/dev/null \
  && fail "iptables rule should be removed"
[[ -f "${SYSTEMD_DIR}/vpn-host-firewall.service" ]] && fail "firewall unit should be removed"
[[ -f "${SYSTEMD_DIR}/vpn-awg-route.service" ]] && fail "legacy route unit should be removed"
[[ -f "${ETC_DIR}/sysctl.d/99-vpn-conntrack.conf" ]] && fail "sysctl drop-in should be removed"
[[ -f "${HOST_ENV}" ]] && fail "host env should be removed"
[[ -f "${HOST_ENSURE}" ]] && fail "ensure wrapper should be removed"
[[ -f "${MODULE_PATH}" ]] && fail "module file should be removed"
[[ -f "${SYSTEMD_DIR}/vpn-stack-boot.service" ]] && fail "vpn-stack-boot unit should be removed"

cleanup_sandbox
trap - EXIT

echo "OK: test_host_remove_integration"
