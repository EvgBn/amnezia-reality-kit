#!/usr/bin/env bash
# Unit tests for MTProxy profile WARN (standalone vs sni).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=../lib/preflight.sh
source "${_LIB}/preflight.sh"
# shellcheck source=../../scripts/preflight/lib/emit.sh
source "${REPO_ROOT}/scripts/preflight/lib/emit.sh"
preflight_test_bootstrap
# shellcheck source=../../scripts/preflight/lib/mtproxy.sh
source "${REPO_ROOT}/scripts/preflight/lib/mtproxy.sh"

run_profile() {
  preflight_check_mtproxy_profile
}

MTPROXY_MODE=standalone
preflight_expect_warns 1 "standalone warns" run_profile
preflight_capture_has WARN profile "without SNI" || fail "expected profile WARN"

MTPROXY_MODE=sni
preflight_expect_capture "sni ok" run_profile
preflight_capture_has OK profile "MTPROXY_MODE=sni" || fail "expected profile OK"

echo "OK: test_preflight_mtproxy_profile"
