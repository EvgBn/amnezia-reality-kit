#!/usr/bin/env bash
# COPY_FROM with quoted tuple .env (I1/I2) must survive bootstrap merge + normalize.
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
ENV_TMP="${TMP}/.env"
COPY_FROM="$(fixture_data_path env/copy-from-tuple.env)"
trap 'rm -rf "${TMP}"' EXIT

cp "${REPO_ROOT}/config/examples/.env.example" "${ENV_TMP}"
chmod 600 "${ENV_TMP}"

for key in IN_INGRESS IN_BRIDGE_SOURCE OUT_EXIT OUT_EXPECTED_EGRESS DOCKER_NETWORK_SUBNET_IPV4; do
  line="$(grep -E "^${key}=" "${COPY_FROM}" | tail -1 || true)"
  [[ -n "${line}" ]] || continue
  val="$(env_file_parse_value "${line#*=}")"
  env_file_set "${ENV_TMP}" "${key}" "${val}"
done

endpoint_normalize_env_file "${ENV_TMP}" || fail "normalize after COPY merge"

set -a
# shellcheck disable=SC1090
source "${ENV_TMP}"
set +a

[[ "${IN_INGRESS}" == "4; 157.22.197.113" ]] || fail "IN_INGRESS after copy"
[[ "${OUT_EXIT}" == "6; 2a10:1fc0:c::5375:710f" ]] || fail "OUT_EXIT after copy"
grep -q "^IN_INGRESS='4; 157.22.197.113'$" "${ENV_TMP}" || fail "quoted on disk"

echo "OK: test_bootstrap_copy_from_tuple"
