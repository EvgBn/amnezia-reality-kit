#!/usr/bin/env bash
# Insert or omit xray VLESS inbound TCP publish in rendered docker-compose.yml.
set -euo pipefail

COMPOSE="${1:?compose file}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ENABLE="$(parse_bool "${ENABLE_XRAY_INBOUND:-}" 1)"
PORT="${XRAY_INBOUND_PORT:-443}"
MODE="${MTPROXY_MODE:-standalone}"
PUBLISH="0.0.0.0"
if [[ "${MODE}" == "sni" ]]; then
  PUBLISH="127.0.0.1"
fi

python3 - "${COMPOSE}" "${ENABLE}" "${PUBLISH}" "${PORT}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
enable = sys.argv[2] == "1"
publish = sys.argv[3]
port = sys.argv[4]

text = path.read_text(encoding="utf-8")
inbound_re = re.compile(
    rf'^\s+-\s+"(?:0\.0\.0\.0|127\.0\.0\.1):{port}:{port}/tcp"\s*$',
    re.M,
)
text = inbound_re.sub("", text)

if not enable:
    path.write_text(text, encoding="utf-8")
    sys.exit(0)

port_line = f'      - "{publish}:{port}:{port}/tcp"'
block = re.search(r"\n  xray:.*?(?=\n  [a-z][a-z0-9_-]*:|\nvolumes:)", text, re.DOTALL)
if not block:
    print("[apply-compose-xray-ports] ERROR: xray service missing", file=sys.stderr)
    sys.exit(1)
body = block.group(0)
if port_line not in body:
    if re.search(r"\n    ports:\n", body):
        body = re.sub(
            r"(\n    ports:\n(?:      - .*\n)+)",
            lambda m: m.group(1) + port_line + "\n",
            body,
            count=1,
        )
    else:
        body = re.sub(
            r"(\n    networks:\n(?:      .*\n)+)",
            r"\1    ports:\n" + port_line + "\n",
            body,
            count=1,
        )
    text = text[: block.start()] + body + text[block.end() :]

path.write_text(text, encoding="utf-8")
PY
