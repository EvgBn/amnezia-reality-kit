#!/usr/bin/env python3
"""Remove a client (matched by email) from an Xray config.json.

Env: XR_CLIENT (client name/email), XR_CONFIG (path to config.json).
Exit codes: 0 removed, 3 client not found.
"""
import json
import os
import sys


def write_json_inplace(config_path: str, config: dict) -> None:
    text = json.dumps(config, indent=2) + "\n"
    with open(config_path, "r+", encoding="utf-8") as f:
        f.seek(0)
        f.write(text)
        f.truncate()
        f.flush()
        os.fsync(f.fileno())


config_path = os.environ["XR_CONFIG"]
name = os.environ["XR_CLIENT"]

with open(config_path, encoding="utf-8") as f:
    config = json.load(f)

idx = next(
    (i for i, ib in enumerate(config.get("inbounds", [])) if ib.get("protocol") == "vless"),
    None,
)
if idx is None:
    print("Error: no VLESS inbound in config.json", file=sys.stderr)
    sys.exit(2)

clients = config["inbounds"][idx].setdefault("settings", {}).setdefault("clients", [])
filtered = [c for c in clients if c.get("email") != name]

if len(filtered) == len(clients):
    sys.exit(3)

config["inbounds"][idx]["settings"]["clients"] = filtered

rules = (config.get("routing") or {}).get("rules")
if rules:
    new_rules = []
    for r in rules:
        users = r.get("user") or []
        if name in users:
            remaining = [u for u in users if u != name]
            if remaining:
                new_rules.append({**r, "user": remaining})
        else:
            new_rules.append(r)
    rules[:] = new_rules

write_json_inplace(config_path, config)
