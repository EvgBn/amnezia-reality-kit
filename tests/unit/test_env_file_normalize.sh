#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=../../scripts/lib/env-file.sh
source "${REPO_ROOT}/scripts/lib/env-file.sh"
# shellcheck source=../../scripts/lib/endpoint.sh
source "${REPO_ROOT}/scripts/lib/endpoint.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

TMP="$(mktemp -d)"
ENV_COPY="${TMP}/.env"
trap 'rm -rf "${TMP}"' EXIT

fixture_copy_data env/pre-normalize.env "${ENV_COPY}"
endpoint_normalize_env_file "${ENV_COPY}" || fail "normalize failed"

set -a
# shellcheck disable=SC1090
source "${ENV_COPY}"
set +a
[[ "${IN_INGRESS}" == "4; 203.0.113.50" ]] || fail "IN_INGRESS after normalize"
grep -q "^IN_INGRESS='4; 203.0.113.50'$" "${ENV_COPY}" || fail "IN_INGRESS quoted on disk"
grep -q "^OUT_EXIT='6; 2606:4700::1'$" "${ENV_COPY}" || fail "OUT_EXIT quoted on disk"
grep -q "^OUT_EXPECTED_EGRESS='4; 198.51.100.20'$" "${ENV_COPY}" || fail "OUT_EXPECTED_EGRESS quoted"
grep -q '^IN_SERVER_IP=' "${ENV_COPY}" && fail "legacy IN_SERVER_IP must be removed"
grep -q '^OUT_SERVER_IPV6=' "${ENV_COPY}" && fail "legacy OUT_SERVER_IPV6 must be removed"
grep -q '^OUT_SERVER_IP=' "${ENV_COPY}" && fail "legacy OUT_SERVER_IP must be removed"

echo "OK: test_env_file_normalize"
