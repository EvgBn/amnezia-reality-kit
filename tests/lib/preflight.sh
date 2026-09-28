#!/usr/bin/env bash
# Preflight unit-test harness: capture probe emit() output (pytest-style).
# Source after REPO_ROOT is set; call preflight_test_bootstrap before other preflight libs.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "preflight.sh: source this file, do not execute" >&2
  exit 1
fi

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh
source "${_LIB}/assert.sh"

PREFLIGHT_TEST_MODE=0
PREFLIGHT_TEST_CAPTURE=()

preflight_test_count_status() {
  case "${1}" in
    OK)   C_OK=$((C_OK + 1)) ;;
    WARN) C_WARN=$((C_WARN + 1)) ;;
    FAIL) C_FAIL=$((C_FAIL + 1)) ;;
    SKIP) C_SKIP=$((C_SKIP + 1)) ;;
  esac
}

preflight_test_reset_counters() {
  C_OK=0
  C_WARN=0
  C_FAIL=0
  C_SKIP=0
  JSON_ITEMS=()
}

preflight_test_emit_shim() {
  local status="$1" phase="$2" name="$3" detail="$4" fix="${5:-}"

  if [[ "${PREFLIGHT_TEST_MODE}" == 0 ]]; then
    _preflight_emit_prod "$@"
    return
  fi

  preflight_test_count_status "${status}"
  PREFLIGHT_TEST_CAPTURE+=("${status}|${phase}|${name}|${detail}|${fix}")

  if [[ "${PREFLIGHT_TEST_MODE}" == 2 && ( "${status}" == "FAIL" || "${status}" == "WARN" ) ]]; then
    printf '  ok probe %s %s — %s (expected)\n' "${phase}" "${name}" "${detail}"
  fi
}

preflight_test_dump_capture() {
  local line status phase name detail fix
  for line in "${PREFLIGHT_TEST_CAPTURE[@]}"; do
    IFS='|' read -r status phase name detail fix <<<"${line}"
    printf '  [probe %s] %-8s %-28s %s\n' "${status}" "${phase}" "${name}" "${detail}"
    [[ -n "${fix}" ]] && printf '           → %s\n' "${fix}"
  done
}

preflight_capture_has() {
  local want_status="$1" needle="$2"
  local line status
  for line in "${PREFLIGHT_TEST_CAPTURE[@]}"; do
    status="${line%%|*}"
    [[ "${status}" == "${want_status}" ]] && [[ "${line}" == *"${needle}"* ]] && return 0
  done
  return 1
}

preflight_test_begin_capture() {
  if [[ "${PREFLIGHT_TEST_VERBOSE:-0}" == 1 ]]; then
    PREFLIGHT_TEST_MODE=2
  else
    PREFLIGHT_TEST_MODE=1
  fi
  preflight_test_reset_counters
  PREFLIGHT_TEST_CAPTURE=()
  JSON=0
  VERBOSE=0
}

preflight_test_end_capture() {
  PREFLIGHT_TEST_MODE=0
}

# Run command with emit captured (no [FAIL]/[WARN] on stdout unless PREFLIGHT_TEST_VERBOSE=1).
preflight_test_run_captured() {
  preflight_test_begin_capture
  "$@"
  preflight_test_end_capture
}

preflight_expect_fails() {
  local want="$1" label="$2"
  shift 2
  preflight_test_run_captured "$@"
  if [[ "${C_FAIL}" -ne "${want}" ]]; then
    echo "FAILED: ${label} (expected ${want} probe FAIL, got ${C_FAIL})" >&2
    preflight_test_dump_capture >&2
    fail "${label}"
  fi
  echo "ok ${label}"
}

preflight_expect_no_fails() {
  local label="$1"
  shift
  preflight_test_run_captured "$@"
  if [[ "${C_FAIL}" -gt 0 ]]; then
    echo "FAILED: ${label} (expected no probe FAIL, got ${C_FAIL})" >&2
    preflight_test_dump_capture >&2
    fail "${label}"
  fi
  echo "ok ${label}"
}

preflight_expect_warns() {
  local want="$1" label="$2"
  shift 2
  preflight_test_run_captured "$@"
  if [[ "${C_WARN}" -lt "${want}" ]]; then
    echo "FAILED: ${label} (expected >=${want} probe WARN, got ${C_WARN})" >&2
    preflight_test_dump_capture >&2
    fail "${label}"
  fi
  echo "ok ${label}"
}

preflight_expect_skips() {
  local want="$1" label="$2"
  shift 2
  preflight_test_run_captured "$@"
  if [[ "${C_SKIP}" -lt "${want}" ]]; then
    echo "FAILED: ${label} (expected >=${want} probe SKIP, got ${C_SKIP})" >&2
    preflight_test_dump_capture >&2
    fail "${label}"
  fi
  echo "ok ${label}"
}

preflight_expect_capture() {
  local label="$1"
  shift
  preflight_test_run_captured "$@"
  echo "ok ${label}"
}

# Install emit/phase_header shim — call once after sourcing emit.sh.
preflight_test_bootstrap() {
  if [[ -n "${_PREFLIGHT_TEST_BOOTSTRAPPED:-}" ]]; then
    return 0
  fi
  eval "$(declare -f emit | sed '1s/^emit/_preflight_emit_prod/')"
  eval "$(declare -f phase_header | sed '1s/^phase_header/_preflight_phase_header_prod/')"
  emit() {
    preflight_test_emit_shim "$@"
  }
  phase_header() {
    if [[ "${PREFLIGHT_TEST_MODE}" != 0 ]]; then
      return 0
    fi
    _preflight_phase_header_prod "$@"
  }
  _PREFLIGHT_TEST_BOOTSTRAPPED=1
}
