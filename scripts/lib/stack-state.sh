#!/usr/bin/env bash
# Operator stack state: make down marks stopped; make start clears (boot respects flag).

_stack_state_paths() {
  if [[ -z "${REPO_ROOT:-}" ]]; then
    # shellcheck source=paths.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
  fi
}

stack_state_mark_stopped() {
  _stack_state_paths
  mkdir -p "$(dirname "${STACK_STOPPED_FILE}")"
  : > "${STACK_STOPPED_FILE}"
}

stack_state_clear_stopped() {
  _stack_state_paths
  rm -f "${STACK_STOPPED_FILE}"
}

stack_state_is_stopped() {
  _stack_state_paths
  [[ -f "${STACK_STOPPED_FILE}" ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
    mark-stopped) stack_state_mark_stopped ;;
    clear) stack_state_clear_stopped ;;
    is-stopped)
      if stack_state_is_stopped; then
        exit 0
      fi
      exit 1
      ;;
    *)
      echo "Usage: $(basename "$0") {mark-stopped|clear|is-stopped}" >&2
      exit 1
      ;;
  esac
fi
