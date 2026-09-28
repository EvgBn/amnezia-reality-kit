#!/usr/bin/env bash
# Regression: help + metrics source order; validate must not treat container name as client IP.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELP="${REPO_ROOT}/scripts/lib/voice-smoke-help.sh"
METRICS="${REPO_ROOT}/scripts/lib/voice-smoke-metrics.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck disable=SC1091
source "${HELP}"
# shellcheck disable=SC1091
source "${METRICS}"

AWG_CONTAINER="vpn-amneziawg"
now="$(date +%s)"

voice_smoke_peer_dump_line() {
  local ip
  ip="$(voice_smoke_normalize_ip "$1")"
  [[ "${ip}" == "10.8.0.9" ]] || return 0
  echo $'PUBKEY\tPRIV\t0\t10.8.0.9/32\t'"${now}"$'\t0\t0'
}

voice_smoke_peer_handshake_age() {
  echo 22
}

voice_smoke_fixture_peer_ip() {
  local ip last
  for last in $(seq 2 254); do
    ip="10.8.0.${last}"
    if voice_smoke_peer_dump_line "${ip}" | grep -q .; then
      echo "${ip}"
      return 0
    fi
  done
  fail "fixture has no AWG peer in 10.8.0.0/24"
}

voice_smoke_fixture_missing_peer_ip() {
  local ip last
  for last in $(seq 2 254); do
    ip="10.8.0.${last}"
    voice_smoke_peer_dump_line "${ip}" | grep -q . && continue
    echo "${ip}"
    return 0
  done
  fail "fixture has no free tunnel IP in 10.8.0.0/24"
}

expect_validate_fail() {
  local ip="$1" label="$2"
  local out rc=0
  out="$(voice_smoke_validate_client_ip "${AWG_CONTAINER}" "${ip}" 180 2>&1)" || rc=$?
  [[ "${rc}" -ne 0 ]] || fail "expected fail: ${label}"
  [[ "${out}" == *"No AWG peer for ${ip}"* ]] \
    || fail "missing error text for ${label}: ${out}"
  echo "  OK expected fail: ${label}"
}

present_ip="$(voice_smoke_fixture_peer_ip)"
missing_ip="$(voice_smoke_fixture_missing_peer_ip)"

if ! voice_smoke_validate_client_ip "${AWG_CONTAINER}" "${present_ip}" 180; then
  fail "validate should pass for active peer ${present_ip} (was broken when metrics shadowed help 2-arg handshake)"
fi

expect_validate_fail "${missing_ip}" "missing peer ${missing_ip}"

echo "OK: test_voice_smoke_validate"
