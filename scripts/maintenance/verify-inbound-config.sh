#!/usr/bin/env bash
# Verify .data/.env inbound flags match .data/build/ (config.json + compose).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

[[ -f "${ENV_FILE}" ]] || {
  echo "[verify-inbound] ERROR: ${ENV_FILE} missing — run make create-data" >&2
  exit 1
}
[[ -f "${COMPOSE_FILE}" && -f "${XRAY_CONF}" ]] || {
  echo "[verify-inbound] ERROR: build files missing — run make build" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

ENABLE_XRAY_INBOUND="$(parse_bool "${ENABLE_XRAY_INBOUND:-}" 1)"
XRAY_INBOUND_PORT="${XRAY_INBOUND_PORT:-443}"
OUT_REALITY_PORT="${OUT_REALITY_PORT:-443}"
MTPROXY_MODE="${MTPROXY_MODE:-standalone}"
XRAY_PUBLISH="0.0.0.0"
if [[ "${MTPROXY_MODE}" == "sni" ]]; then
  XRAY_PUBLISH="127.0.0.1"
fi

export ENABLE_XRAY_INBOUND XRAY_INBOUND_PORT OUT_REALITY_PORT MTPROXY_MODE XRAY_PUBLISH
export COMPOSE_FILE XRAY_CONF

python3 <<'PY'
import json, os, re, sys

compose_path = os.environ["COMPOSE_FILE"]
xray_path = os.environ["XRAY_CONF"]
enable = os.environ.get("ENABLE_XRAY_INBOUND", "1") == "1"
in_port = int(os.environ.get("XRAY_INBOUND_PORT", "443"))
out_port = int(os.environ.get("OUT_REALITY_PORT", "443"))
proxy_mode = os.environ.get("MTPROXY_MODE", "standalone")
publish = os.environ.get("XRAY_PUBLISH", "0.0.0.0")

compose = open(compose_path, encoding="utf-8").read()
cfg = json.load(open(xray_path, encoding="utf-8"))
vless = [ib for ib in cfg.get("inbounds", []) if ib.get("protocol") == "vless"]

def service_block(name: str) -> str:
    m = re.search(
        rf"\n  {name}:.*?(?=\n  [a-z][a-z0-9_-]*:|\nvolumes:|\Z)",
        compose,
        re.DOTALL,
    )
    return m.group(0) if m else ""

xray_block = service_block("xray")
pub_tcp = re.findall(r"0\.0\.0\.0:(\d+):\d+/tcp", xray_block)
loop_tcp = re.findall(r"127\.0\.0\.1:(\d+):\d+/tcp", xray_block)
expected = f'"{publish}:{in_port}:{in_port}/tcp"'

errors = []
if enable:
    if len(vless) != 1:
        errors.append(f"expected 1 vless inbound, got {len(vless)}")
    elif vless[0].get("port") != in_port:
        errors.append(f"vless port {vless[0].get('port')} != XRAY_INBOUND_PORT={in_port}")
    if expected not in xray_block:
        errors.append(f"xray service missing {publish}:{in_port}:{in_port}/tcp publish")
    if proxy_mode == "sni" and str(in_port) in pub_tcp:
        errors.append(f"xray publishes 0.0.0.0:{in_port} but MTPROXY_MODE=sni requires loopback")
    if proxy_mode != "sni" and publish == "0.0.0.0" and str(in_port) not in pub_tcp:
        errors.append(f"xray service missing public 0.0.0.0:{in_port} publish")
else:
    if vless:
        errors.append("vless inbound present but ENABLE_XRAY_INBOUND=0")
    if pub_tcp:
        errors.append(
            f"xray service publishes public TCP {pub_tcp} but inbound disabled"
        )

exit_ob = next((ob for ob in cfg.get("outbounds", []) if ob.get("tag") == "exit"), None)
if exit_ob:
    vn = ((exit_ob.get("settings") or {}).get("vnext") or [{}])[0]
    if vn.get("port") != out_port:
        errors.append(f"exit vnext port {vn.get('port')} != OUT_REALITY_PORT={out_port}")

if errors:
    for e in errors:
        print(f"[verify-inbound] FAIL: {e}", file=sys.stderr)
    sys.exit(1)

inbound_state = "enabled" if enable else "disabled"
extra = ""
if not enable and re.search(r"\n  teleproxy:", compose):
    extra = " (xray only; MTProxy ports ignored by inbound-sync)"
print(f"[verify-inbound] OK — inbound {inbound_state}"
      + (f" {publish} TCP {in_port}" if enable else " (host :443 free for other services)")
      + (f" (sni profile)" if enable and proxy_mode == "sni" else "")
      + extra
      + f"; OUT exit port {out_port}")
PY
