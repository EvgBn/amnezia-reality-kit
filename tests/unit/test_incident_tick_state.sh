#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/incident-channel-lib.sh
source "${ROOT}/scripts/lib/incident-channel-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
STATE="${TMP}/.tick-state"

# incident_state_get: only first '=' is the delimiter.
_blob="$(printf '%s\n' 'meta=foo=bar')"
[[ "$(incident_state_get "${_blob}" meta)" == "foo=bar" ]] || fail 'state_get equals in value'

incident_tick_state_save "${STATE}" "2026-10-15T10:00:00Z" 100 2000 3000 5
_loaded="$(incident_tick_state_load_blob "${STATE}" "2026-10-15T10:02:00Z")"
[[ -n "${_loaded}" ]] || fail 'load within gap'
[[ "$(incident_state_get "${_loaded}" nfqueue)" == "100" ]] || fail 'nfqueue roundtrip'
[[ "$(incident_state_get "${_loaded}" peer_rx)" == "2000" ]] || fail 'peer_rx roundtrip'

# Gap > INCIDENT_TICK_MAX_GAP_SEC → empty prev (no bogus deltas).
_stale="$(incident_tick_state_load_blob "${STATE}" "2026-10-15T10:20:00Z")"
[[ -z "${_stale}" ]] || fail "load after gap should be empty: ${_stale}"

# Legacy / corrupted single-line KV (pre tick_ts or concatenated keys).
printf '%s' 'nfqueue=1peer_rx=2peer_tx=3' > "${STATE}"
[[ -z "$(incident_tick_state_load_blob "${STATE}" "2026-10-15T11:00:00Z")" ]] || fail 'corrupt single-line rejected'

# Multiline without tick_ts still rejected.
printf 'nfqueue=1\npeer_rx=2\n' > "${STATE}"
[[ -z "$(incident_tick_state_load_blob "${STATE}" "2026-10-15T11:00:00Z")" ]] || fail 'missing tick_ts rejected'

echo "OK test_incident_tick_state"
