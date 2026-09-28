#!/usr/bin/env bash
# Guard: no legacy redsocks naming in tracked project files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${ROOT}"

if matches="$(rg -i 'redsocks|REDSOCKS' --glob '!.data/**' --glob '!tests/guards/test_no_redsocks_refs.sh' . 2>/dev/null || true)"; then
  [[ -z "${matches}" ]] || {
    echo "FAIL: legacy redsocks references found:" >&2
    echo "${matches}" >&2
    exit 1
  }
fi

echo "OK: no redsocks references in repo"
