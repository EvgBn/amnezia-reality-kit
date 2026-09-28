#!/usr/bin/env bash
# Insert host port publishes for vpn-teleproxy in rendered docker-compose.yml.
# Caller must strip the teleproxy service when ENABLE_MTPROXY=0 (render_compose markers).
set -euo pipefail

COMPOSE="${1:?compose file}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ENABLE="$(parse_bool "${ENABLE_MTPROXY:-}" 0)"
MODE="${MTPROXY_MODE:-standalone}"
PUBLISH="${MTPROXY_PUBLISH:-0.0.0.0}"
HOST_PORT="${MTPROXY_HOST_PORT:-8444}"
CONTAINER_PORT="${MTPROXY_CONTAINER_PORT:-443}"
STATS_PORT="${MTPROXY_STATS_PORT:-8888}"

if [[ "${ENABLE}" != "1" ]]; then
  echo "[apply-compose-mtproxy] ERROR: called with ENABLE_MTPROXY=0 — strip teleproxy via render_compose first" >&2
  exit 1
fi

python3 - "${COMPOSE}" "${MODE}" "${PUBLISH}" "${HOST_PORT}" "${CONTAINER_PORT}" "${STATS_PORT}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
mode = sys.argv[2]
publish = sys.argv[3]
host_port = sys.argv[4]
container_port = sys.argv[5]
stats_port = sys.argv[6]

text = path.read_text(encoding="utf-8")

if mode == "sni" and publish != "127.0.0.1":
    print(
        "[apply-compose-mtproxy] ERROR: MTPROXY_MODE=sni requires MTPROXY_PUBLISH=127.0.0.1",
        file=sys.stderr,
    )
    sys.exit(1)

if "  teleproxy:" not in text:
    print("[apply-compose-mtproxy] ERROR: teleproxy service missing from compose template", file=sys.stderr)
    sys.exit(1)

if "volumes:\n  teleproxy-data:" not in text:
    text = text.rstrip() + "\n\nvolumes:\n  teleproxy-data:\n"

port_client = f'      - "{publish}:{host_port}:{container_port}/tcp"'
port_stats = f'      - "127.0.0.1:{stats_port}:{stats_port}/tcp"'

if re.search(r'^\s+teleproxy:\s*$', text, re.MULTILINE):
    block = re.search(r"\n  teleproxy:.*?(?=\n(?:  [a-z][a-z0-9_-]*:|# >>>|volumes:))", text, re.DOTALL)
    if not block:
        print("[apply-compose-mtproxy] ERROR: cannot parse teleproxy block", file=sys.stderr)
        sys.exit(1)
    body = block.group(0)
    if port_client not in body:
        body = re.sub(
            r"(\n    networks:\n(?:      .*\n)+)",
            r"\1    ports:\n" + port_client + "\n" + port_stats + "\n",
            body,
            count=1,
        )
    text = text[: block.start()] + body + text[block.end() :]

path.write_text(text, encoding="utf-8")
PY
