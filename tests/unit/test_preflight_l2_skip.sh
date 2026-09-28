#!/usr/bin/env bash
# Unit tests for preflight_l2_autoboot_expected probe.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=../../scripts/lib/host-artifacts.sh
source "${REPO_ROOT}/scripts/lib/host-artifacts.sh"
# shellcheck source=../../scripts/preflight/lib/probes.sh
source "${REPO_ROOT}/scripts/preflight/lib/probes.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export PREFLIGHT_SYSTEMD_UNIT_DIR="${TMP}/systemd"
mkdir -p "${PREFLIGHT_SYSTEMD_UNIT_DIR}"
export HOST_ENV_FILE="${TMP}/missing-env"
export HOST_ENSURE_WRAPPER="${TMP}/missing-wrapper"

preflight_l2_autoboot_expected && fail "expected false with no artifacts"

echo 'REPO_ROOT=/tmp' > "${TMP}/env"
export HOST_ENV_FILE="${TMP}/env"
preflight_l2_autoboot_expected || fail "expected true when env file present"
export HOST_ENV_FILE="${TMP}/missing-env"

printf '#!/bin/sh\n' > "${TMP}/wrapper"
chmod +x "${TMP}/wrapper"
export HOST_ENSURE_WRAPPER="${TMP}/wrapper"
preflight_l2_autoboot_expected || fail "expected true when wrapper present"
export HOST_ENSURE_WRAPPER="${TMP}/missing-wrapper"

printf '[Unit]\n' > "${PREFLIGHT_SYSTEMD_UNIT_DIR}/${HOST_BOOT_UNIT}"
preflight_l2_autoboot_expected || fail "expected true when boot unit file present"

echo "OK: test_preflight_l2_skip"
