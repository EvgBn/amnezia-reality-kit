#!/usr/bin/env bash
# Unit tests for scripts/lib/endpoint.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/lib/endpoint.sh
source "${REPO_ROOT}/scripts/lib/endpoint.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- parse ---
endpoint_parse "4; 198.51.100.10" || fail "parse v4 semicolon"
[[ "${ENDPOINT_FAMILY}" == "4" && "${ENDPOINT_ADDR}" == "198.51.100.10" ]] \
  || fail "v4 semicolon fields"

endpoint_parse "6; 2606:4700::1" || fail "parse v6"
[[ "${ENDPOINT_FAMILY}" == "6" && "${ENDPOINT_ADDR}" == "2606:4700::1" ]] \
  || fail "v6 fields"

endpoint_parse "4,198.51.100.10" || fail "legacy comma"
[[ "${ENDPOINT_FAMILY}" == "4" ]] || fail "legacy comma family"

endpoint_parse "bad" 2>/dev/null && fail "bad should fail"
endpoint_parse "4; not-an-ip" && endpoint_validate_tuple 4 "not-an-ip" 2>/dev/null \
  && fail "invalid v4 should not validate"

endpoint_validate_tuple 6 "2606::1" || fail "v6 validate"
endpoint_validate_tuple 4 "198.51.100.10" || fail "v4 validate"
endpoint_validate_tuple 4 "2606::1" && fail "v4 addr with colon"

# --- resolve: new tuples ---
export IN_INGRESS="4; 203.0.113.10"
export OUT_EXIT="6; 2606:4700::1"
export OUT_EXPECTED_EGRESS="4; 203.0.113.99"
export IN_BRIDGE_SOURCE=auto
unset IN_SERVER_IP OUT_SERVER_IPV6 OUT_SERVER_IP IN_INGRESS_6

ENDPOINT_RESOLVE_QUIET=1
endpoint_resolve_env || fail "resolve new tuples"
[[ "${IN_SERVER_IP}" == "203.0.113.10" ]] || fail "IN_SERVER_IP derived"
[[ "${OUT_EXIT_ADDRESS}" == "2606:4700::1" ]] || fail "OUT_EXIT_ADDRESS"
[[ "${OUT_EXIT_DOMAIN_STRATEGY}" == "UseIPv6" ]] || fail "domain strategy v6"
[[ "${OUT_EXPECTED_EGRESS_ADDRESS}" == "203.0.113.99" ]] || fail "expected egress"

# --- resolve: legacy migrate ---
unset IN_INGRESS OUT_EXIT OUT_EXPECTED_EGRESS
export IN_SERVER_IP="10.0.0.1"
export OUT_SERVER_IPV6="2a10::1"
export OUT_SERVER_IP="5.6.7.8"
ENDPOINT_RESOLVE_QUIET=1
endpoint_resolve_env || fail "legacy resolve"
[[ "${OUT_EXIT}" == "6; 2a10::1" ]] || fail "OUT_EXIT from legacy v6"
[[ "${OUT_EXPECTED_EGRESS}" == "4; 5.6.7.8" ]] || fail "expected from OUT_SERVER_IP"

# --- conflict ---
export IN_INGRESS="4; 1.2.3.4"
export IN_SERVER_IP="9.9.9.9"
export OUT_EXIT="6; 2606::1"
unset OUT_SERVER_IPV6 OUT_SERVER_IP OUT_EXPECTED_EGRESS
ENDPOINT_RESOLVE_QUIET=1
endpoint_resolve_env 2>/dev/null && fail "IN conflict should fail"

# --- OUT v4 ---
export IN_INGRESS="4; 1.2.3.4"
unset IN_SERVER_IP
export OUT_EXIT="4; 198.51.100.20"
export OUT_EXPECTED_EGRESS="4; 198.51.100.20"
unset OUT_SERVER_IPV6 OUT_SERVER_IP
ENDPOINT_RESOLVE_QUIET=1
endpoint_resolve_env || fail "out v4"
[[ "${OUT_EXIT_DOMAIN_STRATEGY}" == "UseIPv4" ]] || fail "UseIPv4"
[[ "${OUT_EXIT_ADDRESS}" == "198.51.100.20" ]] || fail "out v4 addr"

echo "OK: test_endpoint"
