#!/usr/bin/env bash
# Unit tests: AWG_HIGHLIGHT_NAME marks the added client row (temp fixtures only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIST_PEERS="${REPO_ROOT}/scripts/clients/awg/list-peers.py"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

AWG_CONF="${TMP}/awg0.conf"
AWG_CLIENTS_DIR="${TMP}/clients_awg"
mkdir -p "${AWG_CLIENTS_DIR}"

cat > "${AWG_CONF}" <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24

[Peer]
PublicKey = PUB_A
AllowedIPs = 10.8.0.2/32

[Peer]
PublicKey = PUB_B
AllowedIPs = 10.8.0.3/32
EOF

cat > "${AWG_CLIENTS_DIR}/alpha.conf" <<'EOF'
[Interface]
Address = 10.8.0.2/32
EOF

cat > "${AWG_CLIENTS_DIR}/beta.conf" <<'EOF'
[Interface]
Address = 10.8.0.3/32
EOF

run_list() {
  AWG_CONF="${AWG_CONF}" AWG_CLIENTS_DIR="${AWG_CLIENTS_DIR}" AWG_HIGHLIGHT_NAME="${1:-}" \
    python3 "${LIST_PEERS}"
}

plain="$(run_list)"
echo "${plain}" | grep -q '^1   alpha ' || fail "expected alpha row"
echo "${plain}" | grep -q '^2   beta ' || fail "expected beta row"
echo "${plain}" | grep -q 'Client configs:' || fail "missing configs path"
echo "${plain}" | grep -q $'\033\[32m' && fail "plain list must not emit ANSI when stdout is not a TTY"

highlight="$(run_list beta)"
echo "${highlight}" | grep -q '^1   alpha ' || fail "highlight mode must still list alpha"
echo "${highlight}" | grep -q '^2   beta ' || fail "highlight mode must still list beta"
echo "${highlight}" | grep -q '2 peers' || fail "expected peer count in header"

# Unknown highlight name: table unchanged, no crash.
run_list no-such-client >/dev/null || fail "unknown highlight should not fail"

echo "OK: test_awg_list_highlight"
