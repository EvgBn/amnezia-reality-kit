#!/usr/bin/env bash
# Unit tests for scripts/clients/awg/list-peers.py — temp fixtures only, no prod paths.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIST_PEERS="${REPO_ROOT}/scripts/clients/awg/list-peers.py"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

AWG_CONF="${TMP}/awg0.conf"
AWG_CLIENTS_DIR="${TMP}/clients_awg"
mkdir -p "${AWG_CLIENTS_DIR}"

fail() { echo "FAIL: $1" >&2; exit 1; }

make_fixture() {
  cat > "${AWG_CONF}" <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24
ListenPort = 51820

[Peer]
PublicKey = PUB_M
AllowedIPs = 10.8.0.8/32

[Peer]
PublicKey = PUB_EVG
AllowedIPs = 10.8.0.9/32

[Peer]
PublicKey = PUB_ORPHAN1
AllowedIPs = 10.8.0.2/32

[Peer]
# legacy-comment
PublicKey = PUB_ORPHAN2
AllowedIPs = 10.8.0.3/32
EOF

  cat > "${AWG_CLIENTS_DIR}/M.conf" <<'EOF'
[Interface]
PrivateKey = CLIENT_M
Address = 10.8.0.8/32
EOF

  cat > "${AWG_CLIENTS_DIR}/evg.conf" <<'EOF'
[Interface]
PrivateKey = CLIENT_EVG
Address = 10.8.0.9/32, fd86:ea04:1115::9/128
EOF
}

run_list() {
  AWG_CONF="${AWG_CONF}" AWG_CLIENTS_DIR="${AWG_CLIENTS_DIR}" python3 "${LIST_PEERS}" "$@"
}

make_fixture

# 1. Table includes row numbers and known clients (no Docker / runtime column).
out="$(run_list)"
echo "${out}" | grep -q '^#   NAME' || fail "missing # header"
echo "${out}" | grep -q '^1   M ' || fail "expected row 1 = M"
echo "${out}" | grep -q '^2   evg ' || fail "expected row 2 = evg"
echo "${out}" | grep -q '^3   legacy-comment.*10.8.0.3' || fail "expected row 3 = legacy-comment"
echo "${out}" | grep -q '^4   <unnamed>.*10.8.0.2' || fail "expected row 4 = unnamed .2"
echo "${out}" | grep -q '2 orphan peer(s)' || fail "expected orphan count in summary"

# 2. --resolve returns tab-separated name, pubkey, ip.
resolved="$(run_list --resolve 1)"
[[ "${resolved}" == $'M\tPUB_M\t10.8.0.8' ]] || fail "--resolve 1: got '${resolved}'"

resolved="$(run_list --resolve 4)"
[[ "${resolved}" == $'<unnamed>\tPUB_ORPHAN1\t10.8.0.2' ]] \
  || fail "--resolve 4 (orphan): got '${resolved}'"

resolved="$(run_list --resolve 3)"
[[ "${resolved}" == $'legacy-comment\tPUB_ORPHAN2\t10.8.0.3' ]] \
  || fail "--resolve 3 (comment name): got '${resolved}'"

detail="$(run_list --detail 1)"
[[ "${detail}" == $'M\tPUB_M\t10.8.0.8\tM.conf\t—\tPUB_M' ]] \
  || fail "--detail 1: got '${detail}'"

# 5. --tsv machine-readable rows for voice smoke scripts.
tsv="$(run_list --tsv)"
echo "${tsv}" | grep -q $'^1\tM\t10.8.0.8\t' || fail "expected --tsv row 1"
echo "${tsv}" | grep -q $'^2\tevg\t10.8.0.9\t' || fail "expected --tsv row 2"

# 6. Invalid row number exits non-zero.
set +e
run_list --resolve 99 >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "expected non-zero exit for --resolve 99"

# 7. Missing env vars → clear error, not KeyError traceback.
set +e
env -u AWG_CONF -u AWG_CLIENTS_DIR python3 "${LIST_PEERS}" 2>"${TMP}/err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "expected failure without AWG_CONF"
grep -q 'AWG_CONF and AWG_CLIENTS_DIR must be set' "${TMP}/err" \
  || fail "missing friendly env error: $(cat "${TMP}/err")"

echo "OK: test_awg_list_peers"
