#!/usr/bin/env bash
# Guard: legacy monolith scripts removed from bridge repo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_ROOT}"

fail() { echo "FAIL: $1" >&2; exit 1; }

for f in scripts/deployment/deploy.sh scripts/maintenance/cleanup.sh scripts/maintenance/check-keys.sh; do
  [[ ! -f "${f}" ]] || fail "legacy file still present: ${f}"
done

if grep -rn 'ENSURE_SCRIPT' scripts lib 2>/dev/null; then
  fail "ENSURE_SCRIPT alias must not remain in scripts/"
fi

echo "OK: test_no_legacy_deploy"
