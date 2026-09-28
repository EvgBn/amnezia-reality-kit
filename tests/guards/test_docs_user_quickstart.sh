#!/usr/bin/env bash
# Guard: operator QUICKSTART exists and stays short.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QS="${REPO_ROOT}/docs/QUICKSTART.md"
MAX_LINES=120

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "${QS}" ]] || fail "missing ${QS}"

lines="$(wc -l < "${QS}" | tr -d ' ')"
[[ "${lines}" -le "${MAX_LINES}" ]] || fail "QUICKSTART too long (${lines} > ${MAX_LINES}) — keep operator funnel thin"

grep -q 'make first-start' "${QS}" || fail "QUICKSTART must mention make first-start"
grep -q 'TROUBLESHOOTING' "${QS}" || fail "QUICKSTART must link TROUBLESHOOTING"

echo "OK: test_docs_user_quickstart"
