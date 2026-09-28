#!/usr/bin/env bash
# Run test_*.sh scripts in given directories. Used by Makefile targets.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: run-tests.sh <dir> [<dir> ...]" >&2
  exit 1
fi

TEST_MATCH="${TEST_MATCH:-test_*.sh}"
failed=0
ran=0

shopt -s nullglob
for dir in "$@"; do
  [[ -d "${dir}" ]] || continue
  # shellcheck disable=SC2206
  files=( "${dir}"/${TEST_MATCH} )
  for t in "${files[@]}"; do
    ran=$((ran + 1))
    echo "==> ${t}"
    if ! bash "${t}"; then
      echo "FAILED: ${t}" >&2
      failed=$((failed + 1))
    fi
  done
done
shopt -u nullglob

if [[ "${ran}" -eq 0 ]]; then
  echo "No tests matched TEST_MATCH=${TEST_MATCH} in: $*" >&2
  exit 1
fi

if [[ "${failed}" -gt 0 ]]; then
  echo "${failed} test file(s) failed." >&2
  exit 1
fi

echo "All ${ran} test file(s) passed."
