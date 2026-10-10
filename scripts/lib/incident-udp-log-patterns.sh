# shellcheck shell=bash
# Shared grep patterns for udp-relay / associate forensics.
# Consumers:
#   scripts/smoke/voice-fail-snapshot.sh
#   scripts/incident/collect-snapshot.sh  (make incident-snapshot)
#   tests/unit/test_incident_log_patterns.sh
#
# When udprelay adds new log fields for triage, update UDP_RELAY_GREP here only.

readonly LOG_TAIL_IPT2SOCKS="${LOG_TAIL_IPT2SOCKS:-40}"
readonly LOG_TAIL_UDP="${LOG_TAIL_UDP:-80}"
readonly LOG_TAIL_UDP_TIMELINE="${LOG_TAIL_UDP_TIMELINE:-40}"
readonly LOG_TAIL_ASSOC="${LOG_TAIL_ASSOC:-10}"

readonly IPT2SOCKS_GREP='ipt2socks|Operation timed out|EMFILE|accept.*failed'

readonly UDP_RELAY_GREP='one-way|inject reply failed|socks first udp rx|associate closed|reconnect started|session evicted|associate reconnected|action=session_evict|action=associate_reconnect|reconnect coalesced|reconnect skipped|one-way reconnect deferred|one-way reconnect retry|one-way reconnect triggered|path_scenario=SCEN-F'

readonly ASSOC_SNAPSHOT_GREP='associate health|associate closed'
