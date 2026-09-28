#!/usr/bin/env bash
# Sandbox helpers for shell tests. Source after assert.sh or standalone.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "sandbox.sh: source this file, do not execute" >&2
  exit 1
fi

test_repo_root() {
  if [[ -z "${REPO_ROOT:-}" ]]; then
    local _lib
    _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${_lib}/../.." && pwd)"
    export REPO_ROOT
  fi
}

test_mktemp_sandbox() {
  local var="${1:-TMP}"
  # shellcheck disable=SC2154
  if [[ -z "${!var:-}" ]]; then
    printf -v "${var}" '%s' "$(mktemp -d)"
    # shellcheck disable=SC2163
    export "${var?}"
    trap 'rm -rf "${'"${var}"'}"' EXIT
  fi
}
