#!/usr/bin/env bash
# Tests for the component-selection helpers in lib/common.sh
# (parse_bool / render_compose / component_enabled) — no network, no Docker.
set -euo pipefail

_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=../lib/sandbox.sh
source "${_LIB}/sandbox.sh"
# shellcheck source=../lib/assert.sh
source "${_LIB}/assert.sh"

test_repo_root
# shellcheck source=../../scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

# ── parse_bool ───────────────────────────────────────────────────────────────
eq "$(parse_bool ""      1)" "1" "empty falls back to the default"
eq "$(parse_bool ""      0)" "0" "empty falls back to the default"
eq "$(parse_bool "1"     0)" "1" "'1' is true"
eq "$(parse_bool "0"     1)" "0" "'0' is false"
eq "$(parse_bool "true"  0)" "1" "'true' is true"
eq "$(parse_bool "FALSE" 1)" "0" "'FALSE' is false (case-insensitive)"
eq "$(parse_bool "Yes"   0)" "1" "'Yes' is true (case-insensitive)"
eq "$(parse_bool "off"   1)" "0" "'off' is false"

parse_bool "maybe" 1 >/dev/null && fail "unrecognised value accepted"
parse_bool "2"     1 >/dev/null && fail "'2' accepted"

# ── render_compose / component_enabled ───────────────────────────────────────
TMPL="${REPO_ROOT}/tests/fixtures/docker-compose-markers.yml.tmpl"
[[ -f "${TMPL}" ]] || fail "missing fixture: ${TMPL}"

both="$(render_compose "${TMPL}" "")"
grep -q '^  amneziawg:$' <<<"${both}" || fail "amneziawg dropped when enabled"
grep -q '^  xray:$'      <<<"${both}" || fail "xray dropped when enabled"
grep -q '^  dns:$'       <<<"${both}" || fail "dns dropped"
grep -q 'service:'       <<<"${both}" && fail "markers left in the rendered file"

no_awg="$(render_compose "${TMPL}" "amneziawg,dns")"
grep -qi 'amneziawg'  <<<"${no_awg}" && fail "amneziawg block survived"
grep -q '^  dns:$'    <<<"${no_awg}" && fail "dns block survived"
grep -q 'depends_on'  <<<"${no_awg}" && fail "depends_on kept without dns"
grep -q '^  xray:$'   <<<"${no_awg}" || fail "xray dropped with amneziawg"
grep -q 'image: xray' <<<"${no_awg}" || fail "xray body dropped with amneziawg"

no_xray="$(render_compose "${TMPL}" "xray")"
grep -q 'xray'            <<<"${no_xray}" && fail "xray block survived"
grep -q '^  amneziawg:$'  <<<"${no_xray}" || fail "amneziawg dropped with xray"
grep -q '^  dns:$'        <<<"${no_xray}" || fail "dns dropped with xray"
grep -q 'depends_on'      <<<"${no_xray}" || fail "amneziawg lost its dns dependency"

[[ "$(wc -l <<<"${both}")" -lt "$(wc -l < "${TMPL}")" ]] || fail "markers not stripped"

render_compose "${REPO_ROOT}/no-such-template.yml" "" >/dev/null 2>&1 \
  && fail "missing template accepted"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

printf '%s\n' "${no_awg}" > "${TMPDIR_TEST}/docker-compose.yml"
component_enabled xray      "${TMPDIR_TEST}/docker-compose.yml" || fail "xray not detected"
component_enabled amneziawg "${TMPDIR_TEST}/docker-compose.yml" && fail "amneziawg falsely detected"
component_enabled dns       "${TMPDIR_TEST}/docker-compose.yml" && fail "dns falsely detected"

printf '%s\n' "${no_xray}" > "${TMPDIR_TEST}/awg-only.yml"
component_enabled amneziawg "${TMPDIR_TEST}/awg-only.yml" || fail "amneziawg not detected"
component_enabled dns       "${TMPDIR_TEST}/awg-only.yml" || fail "dns not detected"
component_enabled xray      "${TMPDIR_TEST}/awg-only.yml" && fail "xray falsely detected"

component_enabled xray "${TMPDIR_TEST}/missing.yml" && fail "missing compose file accepted"
component_enabled ""   "${TMPDIR_TEST}/docker-compose.yml" && fail "empty service name accepted"

printf 'services:\n  dns:\n    image: dns:1\n    # xray: not a service\n' \
  > "${TMPDIR_TEST}/commented.yml"
component_enabled xray "${TMPDIR_TEST}/commented.yml" && fail "comment counted as a service"

echo "OK: test_component_flags"
