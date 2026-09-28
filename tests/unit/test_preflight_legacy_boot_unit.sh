#!/usr/bin/env bash
# Unit tests: amneziawg-module legacy vs Alias symlink detection.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/lib/host-artifacts.sh
source "${REPO_ROOT}/scripts/lib/host-artifacts.sh"
# shellcheck source=../../scripts/preflight/lib/probes.sh
source "${REPO_ROOT}/scripts/preflight/lib/probes.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export PREFLIGHT_SYSTEMD_UNIT_DIR="${TMP}"

# absent → not unmigrated
preflight_legacy_boot_unit_unmigrated amneziawg-module.service \
  && fail "absent unit should not be unmigrated"

# standalone legacy file → unmigrated
printf '[Unit]\nDescription=old\n' > "${TMP}/amneziawg-module.service"
preflight_legacy_boot_unit_unmigrated amneziawg-module.service \
  || fail "standalone legacy file should be unmigrated"

# Alias symlink from deploy-host → migrated (OK)
printf '[Unit]\nDescription=new\n' > "${TMP}/${HOST_BOOT_UNIT}"
ln -sf "${HOST_BOOT_UNIT}" "${TMP}/amneziawg-module.service"
preflight_legacy_boot_unit_unmigrated amneziawg-module.service \
  && fail "alias symlink to ${HOST_BOOT_UNIT} should not be unmigrated"

# unrelated symlink → unmigrated
touch "${TMP}/other.service"
ln -sf "other.service" "${TMP}/amneziawg-module.service"
preflight_legacy_boot_unit_unmigrated amneziawg-module.service \
  || fail "symlink to other unit should be unmigrated"

echo "OK: test_preflight_legacy_boot_unit"
