#!/usr/bin/env bash
# Unit tests for ensure_boot_run exit codes (no root, no Docker).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="${REPO_ROOT}/tests/fixtures/ensure-boot"
DATA_DIR="${REPO_ROOT}/.data"

# shellcheck source=../../scripts/lib/paths.sh
source "${REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/ensure-boot.sh
source "${REPO_ROOT}/scripts/lib/ensure-boot.sh"
# shellcheck source=../../scripts/lib/stack-state.sh
source "${REPO_ROOT}/scripts/lib/stack-state.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PROC_MODULES="${TMP}/proc-modules"
COMPOSE_FILE="${TMP}/docker-compose.yml"
ENV_FILE="${TMP}/.env"
ROUTE_MOCK="${FIXTURES}/route-mock.sh"

printf 'amneziawg 0 0 - Live 0\n' > "${PROC_MODULES}"
printf 'services:\n  amneziawg:\n    image: x\n' > "${COMPOSE_FILE}"
printf 'ENABLE_AMNEZIAWG=1\n' > "${ENV_FILE}"

export ENSURE_PROC_MODULES="${PROC_MODULES}"
export ENSURE_MODPROBE="${FIXTURES}/modprobe-mock.sh"
export ENSURE_COMPOSE_CMD="${FIXTURES}/ensure-compose-mock.sh"
export ENSURE_COMPOSE_FAIL=0
export ENSURE_DOCKER="${FIXTURES}/ensure-docker-mock.sh"
export REBUILD_SCRIPT="${FIXTURES}/rebuild-mock.sh"
export ROUTE_SCRIPT="${ROUTE_MOCK}"
export COMPOSE_FILE ENV_FILE

export STACK_STOPPED_FILE="${TMP}/.stack-stopped"
export DATA_DIR="${TMP}"

# module loaded + compose ok → success
ensure_boot_run || fail "expected success when compose ok"

# compose failure → boot run fails
export ENSURE_COMPOSE_FAIL=1
if ensure_boot_run >/dev/null 2>&1; then
  fail "expected failure when compose up fails"
fi

# no compose file → success (kmod-only path)
export ENSURE_COMPOSE_FAIL=0
COMPOSE_FILE="${TMP}/missing-compose.yml"
export COMPOSE_FILE
ensure_boot_run || fail "expected success without compose file"

# route failure must not fail boot (warn only)
export ENSURE_COMPOSE_FAIL=0
COMPOSE_FILE="${TMP}/docker-compose.yml"
export COMPOSE_FILE
export ROUTE_SCRIPT="${FIXTURES}/route-mock-fail.sh"
ensure_boot_run || fail "route apply failure should not fail ensure_boot_run"

# stack stopped flag → skip compose, still success
stack_state_mark_stopped
export ENSURE_COMPOSE_FAIL=0
if ! ensure_boot_run >/dev/null 2>&1; then
  fail "expected success when stack marked stopped"
fi

echo "OK: test_ensure_boot_exit"
