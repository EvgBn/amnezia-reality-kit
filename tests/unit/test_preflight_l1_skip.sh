#!/usr/bin/env bash
# Unit tests for preflight_l1_kmod_expected probe.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=../../scripts/lib/paths.sh
source "${REPO_ROOT}/scripts/lib/paths.sh"
# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/host-artifacts.sh
source "${REPO_ROOT}/scripts/lib/host-artifacts.sh"
# shellcheck source=../../scripts/preflight/lib/probes.sh
source "${REPO_ROOT}/scripts/preflight/lib/probes.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export AMNEZIAWG_MODULES_LOAD_CONF="${TMP}/amneziawg.conf"
export MODULE_PATH="${TMP}/amneziawg.ko"
export COMPOSE_FILE="${TMP}/docker-compose.yml"

preflight_l1_kmod_expected && fail "expected false with no artifacts and no compose"

printf 'services:\n  xray:\n    image: xray:1\n' > "${COMPOSE_FILE}"
preflight_l1_kmod_expected && fail "expected false for xray-only compose without artifacts"

printf 'services:\n  amneziawg:\n    image: amneziawg:1\n' > "${COMPOSE_FILE}"
preflight_l1_kmod_expected || fail "expected true when compose includes amneziawg"

printf 'services:\n  xray:\n    image: xray:1\n' > "${COMPOSE_FILE}"
echo amneziawg > "${AMNEZIAWG_MODULES_LOAD_CONF}"
preflight_l1_kmod_expected || fail "expected true when modules-load conf present"

rm -f "${AMNEZIAWG_MODULES_LOAD_CONF}"
touch "${MODULE_PATH}"
preflight_l1_kmod_expected || fail "expected true when module file present"

echo "OK: test_preflight_l1_skip"
