#!/usr/bin/env bash
# Unit tests: add.sh prints full client list with AWG_HIGHLIGHT_NAME (temp only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
ADD_SH="${REPO_ROOT}/scripts/clients/awg/add.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT
export DOCKER_MOCK_AWG_PUBKEY_MAP='SERVERKEY=SERVER_PUB'
export DOCKER_MOCK_AWG_DEFAULT_PUB='NEW_PUB'
fixture_use_awg_docker_mock

TEST_ROOT="${TMP}/data"
mkdir -p "${TEST_ROOT}/clients_awg"

cat > "${TEST_ROOT}/.env" <<'EOF'
AWG_PORT=58285
IN_SERVER_IP=203.0.113.50
EOF

cat > "${TEST_ROOT}/awg0.conf" <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24
ListenPort = 51820
Jc = 8
Jmin = 15
Jmax = 47
S1 = 32
S2 = 17
S3 = 22
S4 = 7
H1 = 1-2
H2 = 3-4
H3 = 5-6
H4 = 7-8

[Peer]
PublicKey = PUB_KEEP
AllowedIPs = 10.8.0.2/32
EOF

cat > "${TEST_ROOT}/clients_awg/keep.conf" <<'EOF'
[Interface]
PrivateKey = KEEP_PRIV
Address = 10.8.0.2/32
EOF

export AWG_TEST_ROOT="${TEST_ROOT}"

out="$("${ADD_SH}" newbie 2>&1)" || fail "add.sh failed: ${out}"

echo "${out}" | grep -q '=== AWG clients' || fail "add must print client list"
echo "${out}" | grep -qE '^[0-9]+   keep ' || fail "existing client must appear in list"
echo "${out}" | grep -qE '^[0-9]+   newbie ' || fail "new client must appear in list"
echo "${out}" | grep -q 'Client configs:' || fail "list must show configs directory"
echo "${out}" | grep -q 'Config saved to:' && fail "add must not print legacy Config saved line"
echo "${out}" | grep -q '2 peers' || fail "list header must show 2 peers"

[[ -f "${TEST_ROOT}/clients_awg/newbie.conf" ]] || fail "newbie.conf not created"
[[ "$(grep -c '^\[Peer\]' "${TEST_ROOT}/awg0.conf")" -eq 2 ]] || fail "awg0.conf must have 2 peers"

fixture_teardown
echo "OK: test_awg_add_report"
