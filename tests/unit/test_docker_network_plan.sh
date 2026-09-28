#!/usr/bin/env bash
# Unit tests: docker-network-plan SSOT (derive IPs from subnet).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAN_PY="${REPO_ROOT}/scripts/lib/docker-network-plan.py"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Default derive from subnet only
cat > "${TMP}/.env" <<'EOF'
DOCKER_NETWORK_SUBNET_IPV4=10.200.97.0/24
DOCKER_NETWORK_SUBNET_IPV6=fd87:172:20::/64
EOF

out="$(python3 "${PLAN_PY}" resolve --env-file "${TMP}/.env")"
echo "${out}" | grep -q "^DOCKER_NETWORK_GATEWAY_IPV4='10.200.97.1'$" || fail "gateway v4"
echo "${out}" | grep -q "^COREDNS_IP='10.200.97.2'$" || fail "coredns v4"
echo "${out}" | grep -q "^AMNEZIAWG_IP='10.200.97.3'$" || fail "awg v4"
echo "${out}" | grep -q "^XRAY_IP='10.200.97.4'$" || fail "xray v4"
echo "${out}" | grep -q "^TELEPROXY_IP='10.200.97.5'$" || fail "teleproxy v4"
echo "${out}" | grep -q "^VPN_DOCKER_SUBNET_CIDR='10.200.97.0/24'$" || fail "cidr alias"

# Empty env uses rare default (not 172.17–172.31 ladder)
touch "${TMP}/empty.env"
out="$(python3 "${PLAN_PY}" resolve --env-file "${TMP}/empty.env")"
echo "${out}" | grep -q "^DOCKER_NETWORK_SUBNET_IPV4='10.200.97.0/24'$" || fail "default subnet"

# Override preserved when inside subnet
cat > "${TMP}/override.env" <<'EOF'
DOCKER_NETWORK_SUBNET_IPV4=10.200.97.0/24
AMNEZIAWG_IP=10.200.97.6
EOF
out="$(python3 "${PLAN_PY}" resolve --env-file "${TMP}/override.env")"
echo "${out}" | grep -q "^AMNEZIAWG_IP='10.200.97.6'$" || fail "override awg ip"

# Outside subnet fails
cat > "${TMP}/bad.env" <<'EOF'
DOCKER_NETWORK_SUBNET_IPV4=10.200.97.0/24
XRAY_IP=172.20.0.4
EOF
python3 "${PLAN_PY}" resolve --env-file "${TMP}/bad.env" >/dev/null 2>&1 && fail "expected outside-subnet error"

# Overlap detection (172.20.0.0/24 inside another project's 172.20.0.0/16)
cat > "${TMP}/overlap.env" <<'EOF'
DOCKER_NETWORK_SUBNET_IPV4=172.20.0.0/24
EOF
networks='[{"Name":"other","IPAM":{"Config":[{"Subnet":"172.20.0.0/16"}]}},{"Name":"vpn","IPAM":{"Config":[{"Subnet":"172.20.0.0/24"}]}}]'
result="$(python3 "${PLAN_PY}" check-overlap --env-file "${TMP}/overlap.env" --networks-json "${networks}")"
echo "${result}" | grep -q '"ok": false' || fail "expected overlap false"
echo "${result}" | grep -q '172.20.0.0/16' || fail "expected conflict detail"

networks_free='[{"Name":"other","IPAM":{"Config":[{"Subnet":"172.21.0.0/16"}]}}]'
result="$(python3 "${PLAN_PY}" check-overlap --env-file "${TMP}/.env" --networks-json "${networks_free}")"
echo "${result}" | grep -q '"ok": true' || fail "expected no overlap"

# Malformed / IPv6-only docker entries must not crash the probe
networks_mixed='[{"Name":"bad","IPAM":{"Config":[{"Subnet":""},{"Subnet":"fd00::/64"}]}},{"Name":"wide","IPAM":{"Config":[{"Subnet":"10.0.0.0/8"}]}}]'
result="$(python3 "${PLAN_PY}" check-overlap --env-file "${TMP}/.env" --networks-json "${networks_mixed}")"
echo "${result}" | grep -q '"ok": false' || fail "expected overlap with 10.0.0.0/8"
echo "${result}" | grep -q '10.0.0.0/8' || fail "expected wide network in conflicts"

# shell integration
# shellcheck source=../../scripts/lib/docker-network-plan.sh
source "${REPO_ROOT}/scripts/lib/docker-network-plan.sh"
docker_network_plan_resolve "${TMP}/.env" || fail "bash resolve failed"
[[ "${AMNEZIAWG_IP}" == "10.200.97.3" ]] || fail "bash export AMNEZIAWG_IP"

echo "OK: test_docker_network_plan"
