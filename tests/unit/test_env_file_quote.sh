#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/lib/env-file.sh
source "${REPO_ROOT}/scripts/lib/env-file.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

quoted="$(env_file_quote_value '4; 198.51.100.20')"
[[ "${quoted}" == "'4; 198.51.100.20'" ]] || fail "tuple quote: got ${quoted}"
x=''
eval "x=${quoted}"
[[ "${x}" == "4; 198.51.100.20" ]] || fail "tuple eval: ${x}"

[[ "$(env_file_quote_value auto)" == "auto" ]] || fail "auto unquoted"
[[ "$(env_file_quote_value 58285)" == "58285" ]] || fail "port unquoted"
[[ "$(env_file_quote_value secret)" == "secret" ]] || fail "secret unquoted"

quoted="$(env_file_quote_value "it's/ok")"
[[ "${quoted}" == *"'"* ]] || fail "apostrophe must quote"
eval "x=${quoted}"
[[ "${x}" == "it's/ok" ]] || fail "apostrophe roundtrip"

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
: > "${TMP}"
env_file_set "${TMP}" IN_INGRESS "4; 203.0.113.50"
grep -q "^IN_INGRESS='4; 203.0.113.50'$" "${TMP}" || fail "env_file_set line"
set -a
# shellcheck disable=SC1090
source "${TMP}"
set +a
[[ "${IN_INGRESS}" == "4; 203.0.113.50" ]] || fail "source IN_INGRESS"

parsed="$(env_file_parse_value "'4; 157.22.197.113'")"
[[ "${parsed}" == "4; 157.22.197.113" ]] || fail "parse quoted tuple: ${parsed}"
parsed="$(env_file_parse_value '4; 157.22.197.113   # comment')"
[[ "${parsed}" == "4; 157.22.197.113" ]] || fail "parse with comment: ${parsed}"

echo "OK: test_env_file_quote"
