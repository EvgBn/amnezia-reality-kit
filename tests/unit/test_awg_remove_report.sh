#!/usr/bin/env bash
# Unit tests: post-remove report shows Removed block + refreshed list (temp only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
LIST_PEERS="${REPO_ROOT}/scripts/clients/awg/list-peers.py"
REMOVE_SH="${REPO_ROOT}/scripts/clients/awg/remove.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

TEST_ROOT="${TMP}/data"
mkdir -p "${TEST_ROOT}/clients_awg"

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT
export DOCKER_MOCK_AWG_DEFAULT_PUB='PUB_DROP'
fixture_use_awg_docker_mock

cat > "${TEST_ROOT}/awg0.conf" <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24

[Peer]
PublicKey = PUB_KEEP
AllowedIPs = 10.8.0.9/32

[Peer]
PublicKey = PUB_DROP
AllowedIPs = 10.8.0.2/32
EOF

cat > "${TEST_ROOT}/clients_awg/dropme.conf" <<'EOF'
[Interface]
PrivateKey = CLIENT_DROP
Address = 10.8.0.2/32
EOF

export AWG_TEST_ROOT="${TEST_ROOT}"

# --detail includes export + runtime columns.
detail="$(
  AWG_CONF="${TEST_ROOT}/awg0.conf" AWG_CLIENTS_DIR="${TEST_ROOT}/clients_awg" \
    python3 "${LIST_PEERS}" --detail 1
)"
[[ "${detail}" == $'dropme\tPUB_DROP\t10.8.0.2\tdropme.conf\t—\tPUB_DROP' ]] \
  || fail "--detail row: '${detail}'"

# Full remove (temp tree only): must print Removed + updated list with one fewer peer.
out="$("${REMOVE_SH}" --num 1 2>&1)" || fail "remove --num failed: ${out}"

echo "${out}" | grep -q '=== Removed ===' || fail "missing Removed section"
echo "${out}" | grep -q 'Name:       dropme' || fail "missing removed name"
echo "${out}" | grep -q 'IP:         10.8.0.2' || fail "missing removed IP"
echo "${out}" | grep -q 'Client key: PUB_DROP' || fail "missing removed key"
echo "${out}" | grep -q 'Export:     dropme.conf' || fail "missing removed export"
echo "${out}" | grep -q '=== AWG clients (updated) ===' || fail "missing updated list header"
updated="${out#*=== AWG clients (updated) ===}"
echo "${updated}" | grep -q 'dropme' && fail "removed client still in updated list"
echo "${updated}" | grep -q '1 peers' || fail "updated list should show 1 peer"

[[ "$(grep -c '^\[Peer\]' "${TEST_ROOT}/awg0.conf")" -eq 1 ]] \
  || fail "awg0.conf should have 1 peer after remove"
[[ ! -f "${TEST_ROOT}/clients_awg/dropme.conf" ]] || fail "dropme.conf should be deleted"

fixture_teardown
echo "OK: test_awg_remove_report"
