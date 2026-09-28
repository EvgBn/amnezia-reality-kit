#!/usr/bin/env bash
# Unit tests: interactive remove IP confirmation (temp fixtures only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
CONFIRM_SH="${REPO_ROOT}/scripts/clients/awg/remove-confirm.sh"
REMOVE_SH="${REPO_ROOT}/scripts/clients/awg/remove.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../../scripts/clients/awg/remove-confirm.sh
source "${CONFIRM_SH}"

base="$(normalize_client_ip_base '10.8.0.4/32')" || fail "normalize /32"
[[ "${base}" == "10.8.0.4" ]] || fail "normalize base got ${base}"

base="$(normalize_client_ip_base '10.8.0.4')" || fail "normalize bare"
[[ "${base}" == "10.8.0.4" ]] || fail "normalize bare got ${base}"

normalize_client_ip_base 'not-an-ip' 2>/dev/null && fail "invalid ip should fail"

client_ip_matches '10.8.0.4/32' '10.8.0.4' || fail "match bare vs /32"
client_ip_matches '10.8.0.4/32' '10.8.0.4/32' || fail "match both /32"
client_ip_matches '10.8.0.4' '10.8.0.4/32' || fail "match swapped"
client_ip_matches '10.8.0.4/32' '10.8.0.5' && fail "wrong ip must not match"

TEST_ROOT="${TMP}/data"
mkdir -p "${TEST_ROOT}/clients_awg"

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT
export DOCKER_MOCK_AWG_PUBKEY_MAP='DROP_PRIV=PUB_DROP'
export DOCKER_MOCK_AWG_DEFAULT_PUB='PUB'
fixture_use_awg_docker_mock

cat > "${TEST_ROOT}/.env" <<'EOF'
AWG_PORT=58285
IN_SERVER_IP=203.0.113.50
EOF

cat > "${TEST_ROOT}/awg0.conf" <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24

[Peer]
PublicKey = PUB_DROP
AllowedIPs = 10.8.0.2/32
EOF

cat > "${TEST_ROOT}/clients_awg/dropme.conf" <<'EOF'
[Interface]
PrivateKey = DROP_PRIV
Address = 10.8.0.2/32
EOF

export AWG_TEST_ROOT="${TEST_ROOT}"
export REMOVE_USE_STDIN=1

# Wrong IP → error, peer kept; correct IP → removed.
set +e
out="$(
  printf '1\n10.8.0.99\n1\n10.8.0.2\n' | "${REMOVE_SH}" --interactive 2>&1
)"
rc=$?
set -e
[[ "${rc}" -eq 0 ]] || fail "interactive remove failed: ${out}"
echo "${out}" | grep -q 'Wrong IP' || fail "expected wrong IP error in output"
echo "${out}" | grep -q 'Expected: 10.8.0.2' || fail "expected IP hint in error"
echo "${out}" | grep -q '=== Removed ===' || fail "expected Removed block after confirm"
[[ "$(grep -c '^\[Peer\]' "${TEST_ROOT}/awg0.conf")" -eq 0 ]] || fail "peer should be removed"
[[ ! -f "${TEST_ROOT}/clients_awg/dropme.conf" ]] || fail "dropme.conf should be deleted"

fixture_teardown
echo "OK: test_awg_remove_confirm"
