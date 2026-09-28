#!/usr/bin/env python3
"""Merge VLESS clients from existing config.json into rendered template output."""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path


def vless_inbound(cfg: dict) -> dict | None:
    for ib in cfg.get("inbounds", []):
        if ib.get("protocol") == "vless":
            return ib
    return None


def main() -> int:
    rendered_path = os.environ["XR_RENDERED"]
    existing_path = os.environ.get("XR_EXISTING", "")
    out_path = os.environ["XR_OUTPUT"]

    with open(rendered_path, encoding="utf-8") as fh:
        rendered = json.load(fh)

    if existing_path and os.path.isfile(existing_path) and os.path.getsize(existing_path) > 0:
        with open(existing_path, encoding="utf-8") as fh:
            existing = json.load(fh)
        src = vless_inbound(existing)
        dst = vless_inbound(rendered)
        if src and dst:
            clients = (src.get("settings") or {}).get("clients") or []
            if clients:
                dst.setdefault("settings", {})["clients"] = clients

    body = json.dumps(rendered, indent=2, ensure_ascii=True)
    if existing_path and os.path.isfile(existing_path):
        raw = Path(existing_path).read_text(encoding="utf-8")
        if not raw.endswith("\n"):
            payload = body
        else:
            payload = body + "\n"
    else:
        payload = body + "\n"

    out = Path(out_path)
    fd, tmp = tempfile.mkstemp(dir=str(out.parent), prefix=".config.", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        os.chmod(tmp, 0o600)
        os.replace(tmp, out_path)
    except Exception:
        os.unlink(tmp)
        raise

    return 0


if __name__ == "__main__":
    sys.exit(main())
