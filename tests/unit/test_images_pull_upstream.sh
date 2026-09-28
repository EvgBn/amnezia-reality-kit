#!/usr/bin/env bash
# Unit test: images-pull-upstream.sh skips pull when ENABLE_MTPROXY=0.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
PULL_SH="${REPO_ROOT}/scripts/setup/images-pull-upstream.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

chmod +x "${PULL_SH}"
PULL_LOG="${TMP}/pull.log"
: > "${PULL_LOG}"

fixture_use_docker_trace_mock "${PULL_LOG}"
trap 'fixture_teardown; rm -rf "${TMP}"' EXIT

run_pull() {
  ENV_FILE="${TMP}/.env" bash "${PULL_SH}"
}

cat > "${TMP}/.env" <<'EOF'
ENABLE_MTPROXY=0
TELEPROXY_VERSION=4.12.0
EOF
out="$(run_pull)"
[[ "${out}" == *"skip teleproxy pull"* ]] || fail "expected skip message"
[[ ! -s "${PULL_LOG}" ]] || fail "docker pull should not run when disabled"

: > "${PULL_LOG}"
cat > "${TMP}/.env" <<'EOF'
ENABLE_MTPROXY=1
TELEPROXY_VERSION=4.12.0
EOF
out="$(run_pull)"
[[ "${out}" == *"pulling ghcr.io/teleproxy/teleproxy:4.12.0"* ]] || fail "expected pull message"
grep -q 'docker pull ghcr.io/teleproxy/teleproxy:4.12.0' "${PULL_LOG}" || fail "docker pull not invoked"

fixture_teardown
echo "OK: test_images_pull_upstream"
