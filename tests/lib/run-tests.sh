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

C_RED=''
C_RESET=''
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[1;31m'
  C_RESET=$'\033[0m'
fi

_run_one_test() {
  local t="$1" rc out
  out="$(mktemp)"
  set +e
  bash "${t}" >"${out}" 2>&1
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    if [[ -n "${C_RED}" ]]; then
      printf '%s' "${C_RED}" >&2
    fi
    cat "${out}" >&2
    if [[ -n "${C_RED}" ]]; then
      printf '%s' "${C_RESET}" >&2
    fi
    printf '%sFAILED: %s%s\n' "${C_RED}" "${t}" "${C_RESET}" >&2
    rm -f "${out}"
    return 1
  fi
  cat "${out}"
  rm -f "${out}"
  return 0
}

shopt -s nullglob
for dir in "$@"; do
  [[ -d "${dir}" ]] || continue
  # shellcheck disable=SC2206
  files=( "${dir}"/${TEST_MATCH} )
  for t in "${files[@]}"; do
    ran=$((ran + 1))
    echo "==> ${t}"
    if ! _run_one_test "${t}"; then
      failed=$((failed + 1))
    fi
  done
done
shopt -u nullglob

if [[ "${ran}" -eq 0 ]]; then
  printf '%sNo tests matched TEST_MATCH=%s in: %s%s\n' "${C_RED}" "${TEST_MATCH}" "$*" "${C_RESET}" >&2
  exit 1
fi

if [[ "${failed}" -gt 0 ]]; then
  printf '%s%d test file(s) failed.%s\n' "${C_RED}" "${failed}" "${C_RESET}" >&2
  exit 1
fi

echo "All ${ran} test file(s) passed."
