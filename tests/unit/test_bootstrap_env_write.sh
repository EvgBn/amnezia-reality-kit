#!/usr/bin/env bash
# Bootstrap .env write path: example + env_file_set + endpoint_normalize (no docker).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/lib/env-file.sh
source "${REPO_ROOT}/scripts/lib/env-file.sh"
# shellcheck source=../../scripts/lib/endpoint.sh
source "${REPO_ROOT}/scripts/lib/endpoint.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
ENV_FILE="${TMP}/.env"
trap 'rm -rf "${TMP}"' EXIT

cp "${REPO_ROOT}/config/examples/.env.example" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

env_file_set "${ENV_FILE}" IN_INGRESS "4; 203.0.113.99"
env_file_set "${ENV_FILE}" OUT_EXIT "6; 2606:4700::beef"
env_file_set "${ENV_FILE}" OUT_EXPECTED_EGRESS "4; 203.0.113.1"

endpoint_normalize_env_file "${ENV_FILE}" || fail "normalize failed"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

[[ "${IN_INGRESS}" == "4; 203.0.113.99" ]] || fail "IN_INGRESS"
grep -q "^IN_INGRESS='4; 203.0.113.99'$" "${ENV_FILE}" || fail "quoted IN_INGRESS on disk"
grep -q "^OUT_EXIT='6; 2606:4700::beef'$" "${ENV_FILE}" || fail "quoted OUT_EXIT on disk"

echo "OK: test_bootstrap_env_write"
