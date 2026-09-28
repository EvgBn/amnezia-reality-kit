#!/usr/bin/env bash
# Guard: root .env.example must mirror config/examples/.env.example
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CANON="${REPO_ROOT}/config/examples/.env.example"
ROOT="${REPO_ROOT}/.env.example"

fail() { echo "FAIL: $1" >&2; exit 1; }

[[ -f "${CANON}" ]] || fail "missing ${CANON}"
[[ -f "${ROOT}" ]] || fail "missing ${ROOT}"

if ! cmp -s "${CANON}" "${ROOT}"; then
  diff -u "${ROOT}" "${CANON}" >&2 || true
  fail ".env.example out of sync — copy config/examples/.env.example to repo root"
fi

echo "OK: test_env_example_sync"
