#!/usr/bin/env python3
"""Apply ENABLE_XRAY_INBOUND / XRAY_INBOUND_PORT to rendered config.json."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def parse_bool(raw: str | None, default: bool) -> bool:
    if raw is None or raw.strip() == "":
        return default
    val = raw.strip().lower()
    if val in ("1", "true", "yes", "on"):
        return True
    if val in ("0", "false", "no", "off"):
        return False
    raise SystemExit(f"[apply-xray-inbound] invalid boolean: {raw!r}")


def vless_inbound(cfg: dict) -> dict | None:
    for ib in cfg.get("inbounds", []):
        if ib.get("protocol") == "vless":
            return ib
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: apply-xray-inbound.py <config.json>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    enabled = parse_bool(os.environ.get("ENABLE_XRAY_INBOUND"), True)
    port = int(os.environ.get("XRAY_INBOUND_PORT", "443"))

    with path.open(encoding="utf-8") as fh:
        cfg = json.load(fh)

    ib = vless_inbound(cfg)
    if not enabled:
        if ib is not None:
            cfg["inbounds"] = [x for x in cfg["inbounds"] if x is not ib]
    elif ib is not None:
        ib["port"] = port

    out_port = os.environ.get("OUT_REALITY_PORT", "443")
    for ob in cfg.get("outbounds", []):
        if ob.get("tag") != "exit":
            continue
        for vn in (ob.get("settings") or {}).get("vnext") or []:
            vn["port"] = int(out_port)

    path.write_text(json.dumps(cfg, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    return 0


if __name__ == "__main__":
    sys.exit(main())
