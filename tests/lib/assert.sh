#!/usr/bin/env bash
# Shared assertions for shell tests. Source from tests; do not execute directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "assert.sh: source this file, do not execute" >&2
  exit 1
fi

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

eq() {
  [[ "$1" == "$2" ]] || fail "$3 (got '$1', want '$2')"
}

contains() {
  [[ "$1" == *"$2"* ]] || fail "$3 (got: $1)"
}

assert_exit() {
  local expect="${1:?expected exit code}"
  shift
  local rc=0 out
  out="$("$@" 2>&1)" || rc=$?
  if [[ "${rc}" -ne "${expect}" ]]; then
    fail "exit ${rc}, want ${expect}: ${out}"
  fi
  printf '%s' "${out}"
}
