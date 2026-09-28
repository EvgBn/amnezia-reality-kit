#!/usr/bin/env bash
# Unit tests for remove-by-number / peer_env — temp fixtures only, no prod writes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIST_PEERS="${REPO_ROOT}/scripts/clients/awg/list-peers.py"
REMOVE_SH="${REPO_ROOT}/scripts/clients/awg/remove.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

TEST_ROOT="${TMP}/data"
AWG_CONF="${TEST_ROOT}/awg0.conf"
AWG_CLIENTS_DIR="${TEST_ROOT}/clients_awg"
mkdir -p "${AWG_CLIENTS_DIR}"

fail() { echo "FAIL: $1" >&2; exit 1; }

cat > "${AWG_CONF}" <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24

[Peer]
PublicKey = PUB_A
AllowedIPs = 10.8.0.2/32
EOF

cat > "${AWG_CLIENTS_DIR}/alice.conf" <<'EOF'
[Interface]
PrivateKey = CLIENT_A
Address = 10.8.0.2/32
EOF

export AWG_TEST_ROOT="${TEST_ROOT}"
export AWG_CONF="${TEST_ROOT}/awg0.conf"
export AWG_CLIENTS_DIR="${TEST_ROOT}/clients_awg"

# Regression: list-peers reads AWG_CONF / AWG_CLIENTS_DIR from env (not prod .data/).
out="$(python3 "${LIST_PEERS}" --resolve 1)"
[[ "${out}" == $'alice\tPUB_A\t10.8.0.2' ]] \
  || fail "exported env resolve: got '${out}'"

# Missing env must not raise Python KeyError.
set +e
env -u AWG_CONF -u AWG_CLIENTS_DIR -u AWG_TEST_ROOT \
  python3 "${LIST_PEERS}" 2>"${TMP}/pyerr"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "expected failure without env"
grep -qi 'KeyError' "${TMP}/pyerr" && fail "KeyError traceback leaked"
grep -q 'AWG_CONF and AWG_CLIENTS_DIR must be set' "${TMP}/pyerr" \
  || fail "missing friendly error: $(cat "${TMP}/pyerr")"

# Invalid --num rejected before touching prod .data/ or Docker.
set +e
"${REMOVE_SH}" --num abc 2>"${TMP}/err"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "expected failure for --num abc"
grep -q 'Invalid number' "${TMP}/err" || fail "missing invalid number message"

# Unknown row # must fail without attempting remove (temp fixture, no prod).
set +e
python3 "${REPO_ROOT}/scripts/clients/awg/list-peers.py" --detail 99 2>"${TMP}/badnum"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "expected failure for --detail 99"
grep -q 'no client #99' "${TMP}/badnum" || fail "missing invalid row message"

set +e
"${REMOVE_SH}" --num 99 2>"${TMP}/err3"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "expected failure for --num 99"
grep -q 'no client #99' "${TMP}/err3" || fail "missing --num 99 error: $(cat "${TMP}/err3}")"
grep -qi 'Traceback' "${TMP}/err3" && fail "Python traceback leaked for --num 99"
grep -q 'Removing #' "${TMP}/err3" && fail "must not print Removing for invalid #"

# Missing config must fail cleanly (no .data/ required on clone).
rm -f "${AWG_CONF}"
set +e
"${REMOVE_SH}" --num 1 2>"${TMP}/err4"
rc=$?
set -e
[[ "${rc}" -ne 0 ]] || fail "expected failure when awg0.conf missing"
grep -q 'AWG config not found' "${TMP}/err4" \
  || fail "missing friendly missing-config error: $(cat "${TMP}/err4}")"
grep -qi 'Traceback' "${TMP}/err4" && fail "traceback leaked for missing config"

# Do NOT invoke remove.sh --num 1 against real paths (would mutate prod awg0.conf).
# Full remove flow belongs in staging / manual QA with Docker.

echo "OK: test_awg_remove_resolve"
