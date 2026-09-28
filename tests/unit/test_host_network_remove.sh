#!/usr/bin/env bash
# Unit tests for host network teardown helpers (iptables + ip route tables).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"

# shellcheck source=../../scripts/lib/host-network.sh
source "${REPO_ROOT}/scripts/lib/host-network.sh"
# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [[ "$1" == "$2" ]] || fail "$3 (got '$1', want '$2')"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fixture_host_network_sandbox "${TMP}"
IPTABLES_STATE="${IPTABLES_MOCK_STATE}"
IP_ROUTES="${IP_MOCK_ROUTES}"
SYSTEMCTL_LOG="${SYSTEMCTL_MOCK_LOG}"
SYSTEMD_DIR="${HOST_SYSTEMD_DIR}"
IPTABLES_MOCK="${IPTABLES}"
IP_MOCK="${IP}"
SYSTEMCTL_MOCK="${SYSTEMCTL}"

# ── iptables INPUT DROP for docker subnet ────────────────────────────────────
"${IPTABLES_MOCK}" -I INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP
host_input_vpn_drop_rule_present || fail "rule should be present after insert"
eq "$(host_input_vpn_drop_rules_remove)" "1" "first removal count"
! host_input_vpn_drop_rule_present || fail "rule should be gone after remove"
eq "$(host_input_vpn_drop_rules_remove)" "0" "idempotent second remove"

# duplicate rules (mis-restart edge case)
"${IPTABLES_MOCK}" -I INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP
"${IPTABLES_MOCK}" -I INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP
eq "$(host_input_vpn_drop_rules_remove)" "2" "removes duplicate INPUT rules"

# unrelated rule must survive
echo 'INPUT -s 10.0.0.0/8 -j ACCEPT' >> "${IPTABLES_STATE}"
"${IPTABLES_MOCK}" -I INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP
host_input_vpn_drop_rules_remove >/dev/null
grep -q '10.0.0.0/8' "${IPTABLES_STATE}" || fail "unrelated iptables rule was removed"

# ── host AWG route table ─────────────────────────────────────────────────────
echo '10.8.0.0/24 via 172.20.0.3 dev br-deadbeef' >> "${IP_ROUTES}"
lines="$(host_awg_route_lines '10.8.0.0/24' '172.20.0.3')"
grep -q 'br-deadbeef' <<<"${lines}" || fail "route line not found"
eq "$(host_awg_routes_remove '10.8.0.0/24' '172.20.0.3')" "1" "route removal count"
[[ -z "$(host_awg_route_lines '10.8.0.0/24' '172.20.0.3')" ]] || fail "route still present"
eq "$(host_awg_routes_remove '10.8.0.0/24' '172.20.0.3')" "0" "idempotent route remove"

# stale route after docker network recreate (different bridge, same gw)
echo '10.8.0.0/24 via 172.20.0.3 dev br-old' >> "${IP_ROUTES}"
echo '10.8.0.0/24 via 172.20.0.3 dev br-new' >> "${IP_ROUTES}"
eq "$(host_awg_routes_remove '10.8.0.0/24' '172.20.0.3')" "2" "removes all matching stale bridges"

# different gateway must not be touched
echo '10.8.0.0/24 via 172.20.0.4 dev br-other' >> "${IP_ROUTES}"
host_awg_routes_remove '10.8.0.0/24' '172.20.0.3' >/dev/null
grep -q '172.20.0.4' "${IP_ROUTES}" || fail "route with different gateway was removed"

# ── systemd units (deploy vs legacy) ─────────────────────────────────────────
printf '%s\n' "${HOST_DEPLOY_UNITS[@]}" | grep -qxF 'vpn-host-firewall.service' \
  || fail "vpn-host-firewall.service missing from HOST_DEPLOY_UNITS"
printf '%s\n' "${HOST_DEPLOY_UNITS[@]}" | grep -qxF 'vpn-stack-boot.service' \
  || fail "vpn-stack-boot.service missing from HOST_DEPLOY_UNITS"
printf '%s\n' "${HOST_DEPLOY_UNITS[@]}" | grep -qxF 'amneziawg-module.service' \
  && fail "amneziawg-module.service must not be in HOST_DEPLOY_UNITS"
printf '%s\n' "${HOST_LEGACY_UNITS[@]}" | grep -qxF 'vpn-awg-route.service' \
  || fail "vpn-awg-route.service missing from HOST_LEGACY_UNITS"
printf '%s\n' "${HOST_LEGACY_UNITS[@]}" | grep -qxF 'amneziawg-module.service' \
  || fail "amneziawg-module.service missing from HOST_LEGACY_UNITS"
printf '%s\n' "${HOST_REMOVE_SYSTEMD_UNITS[@]}" | grep -qxF 'vpn-awg-route.service' \
  || fail "vpn-awg-route.service missing from HOST_REMOVE_SYSTEMD_UNITS"

touch "${SYSTEMD_DIR}/vpn-awg-route.service"
host_systemd_unit_present vpn-awg-route.service || fail "route unit should exist before remove"
host_systemd_unit_remove vpn-awg-route.service || fail "route unit remove should succeed"
! host_systemd_unit_present vpn-awg-route.service || fail "route unit file should be deleted"
! host_systemd_unit_remove vpn-awg-route.service || fail "second remove should report absent"
grep -qxF 'disable --now vpn-awg-route.service' "${SYSTEMCTL_LOG}" \
  || fail "systemctl disable --now not called for vpn-awg-route.service"
grep -qxF 'daemon-reload' "${SYSTEMCTL_LOG}" || fail "systemctl daemon-reload not called"

: > "${SYSTEMCTL_LOG}"
touch "${SYSTEMD_DIR}/vpn-host-firewall.service"
touch "${SYSTEMD_DIR}/vpn-awg-route.service"
touch "${SYSTEMD_DIR}/amneziawg-module.service"
eq "$(host_systemd_units_remove "${HOST_REMOVE_SYSTEMD_UNITS[@]}")" "3" \
  "host-remove unit batch removes firewall + route + legacy boot"
! host_systemd_unit_present vpn-host-firewall.service || fail "firewall unit should be gone"
! host_systemd_unit_present vpn-awg-route.service || fail "route unit should be gone"
! host_systemd_unit_present amneziawg-module.service || fail "legacy boot unit should be gone"

# ── deploy-host artifact inventory (documentation guard) ─────────────────────
printf '%s\n' "${HOST_L0_DROPINS[@]}" | grep -qxF '/etc/sysctl.d/99-vpn-conntrack.conf' \
  || fail "missing conntrack sysctl drop-in in HOST_L0_DROPINS"
printf '%s\n' "${HOST_L0_UNITS[@]}" | grep -qxF 'vpn-host-firewall.service' \
  || fail "missing firewall unit in HOST_L0_UNITS"
printf '%s\n' "${HOST_L2_UNITS[@]}" | grep -qxF 'vpn-stack-boot.service' \
  || fail "vpn-stack-boot.service missing from HOST_L2_UNITS"
printf '%s\n' "${HOST_ALL_KNOWN_UNITS[@]}" | grep -qxF 'vpn-host-firewall.service' \
  || fail "missing firewall unit in inventory"

echo "OK: test_host_network_remove"
