#!/usr/bin/env bash
# Unit tests for preflight phase 10 OUT probes (mocked docker/curl).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"

# shellcheck source=../lib/preflight.sh
source "${_LIB}/preflight.sh"
# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
fixture_use_out_mocks

PREFLIGHT_STRICT=0
# shellcheck source=../../scripts/preflight/lib/emit.sh
source "${REPO_ROOT}/scripts/preflight/lib/emit.sh"
preflight_init_colors
preflight_test_bootstrap
# shellcheck source=../../scripts/preflight/lib/probes.sh
source "${REPO_ROOT}/scripts/preflight/lib/probes.sh"
# shellcheck source=../../scripts/preflight/lib/stack.sh
source "${REPO_ROOT}/scripts/preflight/lib/stack.sh"
# shellcheck source=../../scripts/preflight/lib/out.sh
source "${REPO_ROOT}/scripts/preflight/lib/out.sh"
# shellcheck source=../../scripts/preflight/phases/10-out.sh
source "${REPO_ROOT}/scripts/preflight/phases/10-out.sh"

export REPO_ROOT
export SOCKS_USER=testuser SOCKS_PASSWORD=testpass SOCKS_PORT=1080
export OUT_EXIT_FAMILY=6 OUT_EXIT_ADDRESS=2606:4700::1
export OUT_EXPECTED_EGRESS_ADDRESS=198.51.100.20

run_phase() {
  preflight_phase_10_out
}

# --- helpers: ping + curl mocks (no emit) ---
export OUT_MOCK_PING_RC=0
preflight_out_ping 6 2606:4700::1 || fail "ping mock should succeed when OUT_MOCK_PING_RC=0"

export OUT_MOCK_PING_RC=1
preflight_out_ping 6 2606:4700::1 && fail "ping mock should fail when OUT_MOCK_PING_RC=1"

export OUT_MOCK_CURL_IP=198.51.100.20
got="$(preflight_out_curl_egress testuser testpass 1080)" || fail "curl mock should return IP"
eq "${got}" "198.51.100.20" "curl mock IP"

export OUT_MOCK_CURL_IP=203.0.113.55
got="$(preflight_out_curl_egress testuser 'rtS1wruVGvD3qG8Uo6JopQ/vOVjUr9pS' 1080)" || fail "curl mock with slash in password"
eq "${got}" "203.0.113.55" "curl egress SOCKS password with /"

unset OUT_MOCK_CURL_IP
preflight_out_curl_egress testuser testpass 1080 2>/dev/null && fail "curl mock should fail when unset"

# --- phase: stack not running → SKIP ---
preflight_docker_accessible() { return 0; }
preflight_stack_configured() { return 0; }
preflight_stack_any_running() { return 1; }

preflight_expect_capture "SKIP when stack down" run_phase
preflight_capture_has SKIP "stack" || fail "expected SKIP when stack down"

# --- phase: ping WARN + egress OK ---
preflight_stack_any_running() { return 0; }
preflight_out_stack_ready() { return 0; }
export OUT_MOCK_PING_RC=1 OUT_MOCK_CURL_IP=198.51.100.20

preflight_expect_capture "WARN on ping fail + OK egress" run_phase
preflight_capture_has WARN "OUT_EXIT-reach" || fail "expected WARN on ping fail"
preflight_capture_has OK "egress-match" || fail "expected OK egress match"

# --- phase: ping OK + egress mismatch → WARN ---
export OUT_MOCK_PING_RC=0 OUT_MOCK_CURL_IP=203.0.113.99
preflight_expect_capture "WARN egress mismatch" run_phase
preflight_capture_has OK "OUT_EXIT-reach" || fail "expected OK ping"
preflight_capture_has WARN "egress-match" || fail "expected WARN egress mismatch"
contains "${PREFLIGHT_TEST_CAPTURE[*]}" "203.0.113.99" "egress mismatch IP in capture"

# --- phase: no OUT_EXPECTED_EGRESS → SKIP egress ---
unset OUT_EXPECTED_EGRESS_ADDRESS
export OUT_MOCK_PING_RC=0
preflight_expect_capture "SKIP egress when unset" run_phase
preflight_capture_has SKIP "egress-match" || fail "expected SKIP egress"
contains "${PREFLIGHT_TEST_CAPTURE[*]}" "OUT_EXPECTED_EGRESS not set" "SKIP reason"

# --- strict: egress mismatch → FAIL ---
export OUT_EXPECTED_EGRESS_ADDRESS=198.51.100.20
export OUT_MOCK_CURL_IP=203.0.113.99
PREFLIGHT_STRICT=1
preflight_expect_fails 1 "FAIL egress under strict" run_phase
preflight_capture_has FAIL "egress-match" || fail "expected FAIL egress under strict"

echo "OK: test_preflight_out"
