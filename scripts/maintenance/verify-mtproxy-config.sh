#!/usr/bin/env bash
# Verify .data/.env MTProxy flags match .data/build/docker-compose.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

[[ -f "${ENV_FILE}" ]] || {
  echo "[verify-mtproxy] ERROR: ${ENV_FILE} missing — run make create-data" >&2
  exit 1
}
[[ -f "${COMPOSE_FILE}" ]] || {
  echo "[verify-mtproxy] ERROR: ${COMPOSE_FILE} missing — run make build" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

ENABLE_MTPROXY="$(parse_bool "${ENABLE_MTPROXY:-}" 0)"
MTPROXY_MODE="${MTPROXY_MODE:-standalone}"
MTPROXY_PUBLISH="${MTPROXY_PUBLISH:-0.0.0.0}"
MTPROXY_HOST_PORT="${MTPROXY_HOST_PORT:-8444}"
MTPROXY_CONTAINER_PORT="${MTPROXY_CONTAINER_PORT:-443}"
MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT:-8888}"

if [[ "${ENABLE_MTPROXY}" == "1" && "${MTPROXY_MODE}" == "sni" ]]; then
  MTPROXY_PUBLISH="127.0.0.1"
fi

MTPROXY_EXTERNAL_PORT="${MTPROXY_EXTERNAL_PORT:-}"
if [[ "${ENABLE_MTPROXY}" == "1" && "${MTPROXY_MODE}" == "sni" ]]; then
  MTPROXY_PUBLISH="127.0.0.1"
  MTPROXY_EXTERNAL_PORT="${MTPROXY_EXTERNAL_PORT:-443}"
fi

export ENABLE_MTPROXY MTPROXY_MODE MTPROXY_PUBLISH MTPROXY_HOST_PORT MTPROXY_EXTERNAL_PORT
export MTPROXY_CONTAINER_PORT MTPROXY_STATS_PORT COMPOSE_FILE

python3 <<'PY'
import os, re, sys

compose_path = os.environ["COMPOSE_FILE"]
enable = os.environ.get("ENABLE_MTPROXY", "0") == "1"
mode = os.environ.get("MTPROXY_MODE", "standalone")
publish = os.environ.get("MTPROXY_PUBLISH", "0.0.0.0")
host_port = os.environ.get("MTPROXY_HOST_PORT", "8444")
container_port = os.environ.get("MTPROXY_CONTAINER_PORT", "443")
stats_port = os.environ.get("MTPROXY_STATS_PORT", "8888")
external_port = os.environ.get("MTPROXY_EXTERNAL_PORT", "")

compose = open(compose_path, encoding="utf-8").read()
has_service = "container_name: vpn-teleproxy" in compose or "\n  teleproxy:" in compose
client_line = f'"{publish}:{host_port}:{container_port}/tcp"'
stats_line = f'"127.0.0.1:{stats_port}:{stats_port}/tcp"'
pub_all = re.findall(r'0\.0\.0\.0:(\d+):\d+/tcp', compose)

errors = []
if enable:
    if not has_service:
        errors.append("vpn-teleproxy service missing from compose but ENABLE_MTPROXY=1")
    if client_line not in compose:
        errors.append(
            f"compose missing client publish {publish}:{host_port}:{container_port}/tcp"
        )
    if stats_line not in compose:
        errors.append(f"compose missing stats publish 127.0.0.1:{stats_port}:{stats_port}/tcp")
    if mode == "sni" and publish != "127.0.0.1":
        errors.append("MTPROXY_MODE=sni requires loopback-only client publish")
    if mode == "sni" and external_port != "443":
        errors.append(f"MTPROXY_EXTERNAL_PORT must be 443 in sni mode (got {external_port!r})")
    if f"0.0.0.0:{host_port}:" in compose and mode == "standalone" and host_port == "443":
        errors.append("teleproxy must not publish 0.0.0.0:443 in standalone mode")
else:
    if has_service:
        errors.append("vpn-teleproxy present in compose but ENABLE_MTPROXY=0")
    if str(host_port) in pub_all:
        errors.append(f"compose publishes 0.0.0.0:{host_port} but MTProxy disabled")

if errors:
    for e in errors:
        print(f"[verify-mtproxy] FAIL: {e}", file=sys.stderr)
    sys.exit(1)

if enable:
    print(
        f"[verify-mtproxy] OK — MTProxy enabled ({mode}) "
        f"publish {publish}:{host_port}→{container_port}; stats 127.0.0.1:{stats_port}"
    )
else:
    print("[verify-mtproxy] OK — MTProxy disabled (no teleproxy in compose)")
PY
