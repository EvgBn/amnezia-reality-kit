#!/usr/bin/env bash
# Unit tests for .stack-stopped operator state.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="${REPO_ROOT}/.data"
STACK_STATE="${REPO_ROOT}/scripts/lib/stack-state.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export DATA_DIR="${TMP}"
export STACK_STOPPED_FILE="${DATA_DIR}/.stack-stopped"
rm -f "${STACK_STOPPED_FILE}"

# shellcheck source=../../scripts/lib/stack-state.sh
source "${STACK_STATE}"

stack_state_is_stopped && fail "should not be stopped initially"

stack_state_mark_stopped
stack_state_is_stopped || fail "expected stopped after mark"

"${STACK_STATE}" clear
stack_state_is_stopped && fail "expected cleared after clear"

stack_state_mark_stopped
"${STACK_STATE}" is-stopped || fail "CLI is-stopped should exit 0"

echo "OK: test_stack_state"
