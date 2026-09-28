#!/usr/bin/env bash
# Unit tests for vpn-stack-ensure wrapper (no root, no systemd).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER_SRC="${REPO_ROOT}/scripts/deployment/vpn-stack-ensure.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -x "${WRAPPER_SRC}" ]] || fail "missing wrapper source ${WRAPPER_SRC}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

WRAPPER="${TMP}/vpn-stack-ensure"
cp "${WRAPPER_SRC}" "${WRAPPER}"
chmod +x "${WRAPPER}"

ENV_FILE="${TMP}/env"
REPO_FAKE="${TMP}/fake-repo"
mkdir -p "${REPO_FAKE}/scripts/maintenance"

cat > "${REPO_FAKE}/scripts/maintenance/vpn-stack-boot.sh" <<'EOF'
#!/usr/bin/env bash
echo "ENSURE_RAN"
exit 0
EOF
chmod +x "${REPO_FAKE}/scripts/maintenance/vpn-stack-boot.sh"

printf 'REPO_ROOT=%s\n' "${REPO_FAKE}" > "${ENV_FILE}"

out="$(HOST_ENV_FILE="${ENV_FILE}" "${WRAPPER}")"
[[ "${out}" == "ENSURE_RAN" ]] || fail "wrapper did not exec ensure script (got: ${out})"

if HOST_ENV_FILE="${TMP}/missing-env" "${WRAPPER}" >/dev/null 2>&1; then
  fail "expected failure when env file missing"
fi

printf 'REPO_ROOT=%s\n' "${TMP}/no-such-repo" > "${ENV_FILE}"
if HOST_ENV_FILE="${ENV_FILE}" "${WRAPPER}" >/dev/null 2>&1; then
  fail "expected failure when ensure script missing"
fi

echo "OK: test_ensure_wrapper"
