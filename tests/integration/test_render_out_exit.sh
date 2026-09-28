#!/usr/bin/env bash
# Unit tests: OUT_EXIT tuple → render-config → config.json exit outbound.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
RENDER="${REPO_ROOT}/scripts/setup/render-config.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"
export REPO_ROOT

DATA_DIR="${TMP}/data"
BUILD_DIR="${DATA_DIR}/build"
ENV_FILE="${DATA_DIR}/.env"
export DATA_DIR BUILD_DIR ENV_FILE AWG_CONF="${BUILD_DIR}/awg0.conf" XRAY_CONF="${BUILD_DIR}/config.json"

prepare_render_tree() {
  mkdir -p "${BUILD_DIR}"
  fixture_copy_data awg/awg0-with-peer.conf "${AWG_CONF}"
}

assert_exit_outbound() {
  local addr="$1" strategy="$2"
  python3 - "${addr}" "${strategy}" "${XRAY_CONF}" <<'PY'
import json
import sys

addr, strategy, path = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
exit_ob = next(ob for ob in cfg["outbounds"] if ob.get("tag") == "exit")
vnext = exit_ob["settings"]["vnext"][0]
got_addr = vnext.get("address")
got_ds = exit_ob["settings"].get("domainStrategy")
if got_addr != addr:
    raise SystemExit(f"address: {got_addr!r} != {addr!r}")
if got_ds != strategy:
    raise SystemExit(f"domainStrategy: {got_ds!r} != {strategy!r}")
PY
}

run_render() {
  bash "${RENDER}" --no-backup >/dev/null
}

prepare_render_tree
fixture_copy_data env/render-out-exit-v6.env "${ENV_FILE}"
run_render
assert_exit_outbound "2606:4700::1" "UseIPv6"

rm -rf "${DATA_DIR}"
prepare_render_tree
fixture_copy_data env/render-out-exit-v4.env "${ENV_FILE}"
run_render
assert_exit_outbound "198.51.100.20" "UseIPv4"

rm -rf "${DATA_DIR}"
prepare_render_tree
fixture_copy_data env/render-legacy-ipv6.env "${ENV_FILE}"
run_render
assert_exit_outbound "2a10::beef" "UseIPv6"

echo "OK: test_render_out_exit"
