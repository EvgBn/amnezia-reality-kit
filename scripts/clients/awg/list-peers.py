#!/usr/bin/env python3
"""AWG client list and peer resolution for remove-by-number.

Env: AWG_CONF, AWG_CLIENTS_DIR, AWG_CONTAINER (optional).

Usage:
  list-peers.py              # human table (default)
  list-peers.py --resolve N  # name, full pubkey, ip (tab-separated) on stdout
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys
from datetime import datetime, timezone


def short_key(key: str, head: int = 8, tail: int = 4) -> str:
    if len(key) <= head + tail + 1:
        return key
    return f"{key[:head]}…{key[-tail:]}"


def normalize_tunnel_ip(value: str) -> str:
    ip = value.split(",")[0].strip()
    if "/" in ip:
        ip = ip.split("/", 1)[0]
    return ip


def ipv4_from_allowed(allowed: str) -> str:
    m = re.search(r"10\.8\.0\.\d+/32", allowed)
    raw = m.group(0) if m else allowed.split(",")[0].strip()
    return normalize_tunnel_ip(raw)


def ipv4_from_address(value: str) -> str:
    m = re.search(r"10\.8\.0\.\d+/32", value)
    raw = m.group(0) if m else value.split(",")[0].strip()
    return normalize_tunnel_ip(raw)


def parse_peers(conf_text: str) -> list[dict]:
    peers: list[dict] = []
    for block in conf_text.split("[Peer]")[1:]:
        comment = None
        pubkey = None
        allowed = None
        for line in block.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith("["):
                break
            if line.startswith("#"):
                comment = line[1:].strip()
            elif line.startswith("PublicKey"):
                pubkey = line.split("=", 1)[1].strip()
            elif line.startswith("AllowedIPs"):
                allowed = line.split("=", 1)[1].strip()
        if pubkey and allowed:
            peers.append({
                "comment": comment,
                "pubkey": pubkey,
                "ip": ipv4_from_allowed(allowed),
            })
    return peers


def load_ip_to_name(clients_dir: str) -> dict[str, str]:
    ip_to_name: dict[str, str] = {}
    for path in sorted(glob.glob(os.path.join(clients_dir, "*.conf"))):
        name = os.path.basename(path)[:-5]
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("Address"):
                    ip = ipv4_from_address(line.split("=", 1)[1].strip())
                    ip_to_name[ip] = name
                    break
    return ip_to_name


def load_runtime(container: str) -> dict[str, dict]:
    try:
        out = subprocess.run(
            ["docker", "exec", container, "awg", "show", "awg0", "dump"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
    except (subprocess.SubprocessError, FileNotFoundError):
        return {}

    runtime: dict[str, dict] = {}
    lines = out.stdout.strip().splitlines()
    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) < 5:
            continue
        hs = int(cols[4]) if cols[4].isdigit() else 0
        runtime[cols[0]] = {"handshake": hs}
    return runtime


def format_runtime(pubkey: str, runtime: dict[str, dict], now: int) -> str:
    info = runtime.get(pubkey)
    if info is None:
        return "—"

    hs = info["handshake"]
    if hs <= 0:
        return "○ idle"

    age = now - hs
    if age <= 180:
        if age < 60:
            return f"● active ({age}s ago)"
        return f"● active ({age // 60}m ago)"

    if age < 3600:
        return f"○ idle ({age // 60}m ago)"
    if age < 86400:
        return f"○ idle ({age // 3600}h ago)"
    return f"○ idle ({age // 86400}d ago)"


def resolve_name(peer: dict, ip_to_name: dict[str, str]) -> str:
    if peer["ip"] in ip_to_name:
        return ip_to_name[peer["ip"]]
    if peer["comment"]:
        return peer["comment"]
    return "<unnamed>"


def build_rows(awg_conf: str, clients_dir: str, container: str) -> tuple[list[dict], dict]:
    with open(awg_conf, encoding="utf-8") as f:
        peers = parse_peers(f.read())

    ip_to_name = load_ip_to_name(clients_dir)
    runtime = load_runtime(container) if container else {}
    now = int(datetime.now(timezone.utc).timestamp())

    rows: list[dict] = []
    matched_ips: set[str] = set()
    connected = 0

    for peer in peers:
        name = resolve_name(peer, ip_to_name)
        has_export = peer["ip"] in ip_to_name
        if has_export:
            matched_ips.add(peer["ip"])
            export = f"{name}.conf"
        else:
            export = "(no export)"

        rt = format_runtime(peer["pubkey"], runtime, now)
        if rt.startswith("●"):
            connected += 1

        rows.append({
            "name": name,
            "ip": peer["ip"],
            "pubkey_short": short_key(peer["pubkey"]),
            "pubkey": peer["pubkey"],
            "export": export,
            "runtime": rt,
            "has_export": has_export,
            "sort_unnamed": name == "<unnamed>",
            "sort_ip": peer["ip"],
        })

    rows.sort(key=lambda r: (r["sort_unnamed"], r["name"], r["sort_ip"]))
    for i, row in enumerate(rows, start=1):
        row["num"] = i

    meta = {
        "peer_count": len(peers),
        "export_count": len(glob.glob(os.path.join(clients_dir, "*.conf"))),
        "connected": connected,
        "orphan": len(peers) - len(matched_ips),
        "unmatched_exports": sorted(
            ip_to_name[ip] for ip in ip_to_name if ip not in {p["ip"] for p in peers}
        ),
        "clients_dir": os.path.abspath(clients_dir),
    }
    return rows, meta


def color_green(text: str) -> str:
    if sys.stdout.isatty():
        return f"\033[32m{text}\033[0m"
    return text


def format_row(row: dict, width: int = 82) -> str:
    return (
        f"{row['num']:<3} {row['name']:<14} {row['ip']:<16} {row['pubkey_short']:<14} "
        f"{row['export']:<18} {row['runtime']}"
    )


def print_table(rows: list[dict], meta: dict, highlight_name: str = "") -> None:
    print(f"=== AWG clients ({meta['peer_count']} peers, {meta['export_count']} exports) ===")
    clients_path = f"{meta['clients_dir']}/"
    print(f"Client configs: {color_green(clients_path)}")
    print()
    print(f"{'#':<3} {'NAME':<14} {'IP':<16} {'CLIENT KEY':<14} {'EXPORT':<18} RUNTIME")
    print("─" * 82)

    for row in rows:
        line = format_row(row)
        if highlight_name and row["name"] == highlight_name:
            line = color_green(line)
        print(line)

    print()
    summary = (
        f"Summary: {meta['peer_count']} peers, {meta['export_count']} exports, "
        f"{meta['connected']} connected"
    )
    if meta["orphan"]:
        summary += f", {meta['orphan']} orphan peer(s) without .conf"
    print(summary)

    if meta["unmatched_exports"]:
        print(f"Unmatched exports (no peer IP): {', '.join(meta['unmatched_exports'])}")


def cmd_resolve(rows: list[dict], num: int) -> int:
    for row in rows:
        if row["num"] == num:
            print(f"{row['name']}\t{row['pubkey']}\t{row['ip']}")
            return 0
    print(f"Error: no client #{num} (valid: 1–{len(rows)})", file=sys.stderr)
    return 1


def print_row_detail(row: dict) -> None:
    print(
        f"{row['name']}\t{row['pubkey']}\t{row['ip']}\t"
        f"{row['export']}\t{row['runtime']}\t{row['pubkey_short']}"
    )


def cmd_detail(rows: list[dict], num: int | None = None, name: str | None = None) -> int:
    for row in rows:
        if num is not None and row["num"] == num:
            print_row_detail(row)
            return 0
        if name is not None and row["name"] == name:
            print_row_detail(row)
            return 0
    if num is not None:
        print(f"Error: no client #{num} (valid: 1–{len(rows)})", file=sys.stderr)
    else:
        print(f"Error: no client named '{name}'", file=sys.stderr)
    return 1


def cmd_tsv(rows: list[dict]) -> int:
    for row in rows:
        print(
            f"{row['num']}\t{row['name']}\t{row['ip']}\t{row['runtime']}"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="List AWG clients or resolve by number.")
    parser.add_argument("--resolve", type=int, metavar="N", help="Print name, pubkey, IP for row N")
    parser.add_argument("--detail", type=int, metavar="N", help="Print full row detail for row N")
    parser.add_argument("--detail-name", metavar="NAME", help="Print full row detail by client name")
    parser.add_argument(
        "--tsv",
        action="store_true",
        help="Machine-readable rows: NUM\\tNAME\\tIP\\tRUNTIME (for voice smoke scripts)",
    )
    args = parser.parse_args()

    awg_conf = os.environ.get("AWG_CONF")
    clients_dir = os.environ.get("AWG_CLIENTS_DIR")
    if not awg_conf or not clients_dir:
        print(
            "Error: AWG_CONF and AWG_CLIENTS_DIR must be set (source scripts/lib/paths.sh).",
            file=sys.stderr,
        )
        return 2

    if not os.path.isfile(awg_conf):
        print(f"Error: AWG config not found: {awg_conf}", file=sys.stderr)
        return 1

    if not os.path.isdir(clients_dir):
        print(f"Error: AWG clients dir not found: {clients_dir}", file=sys.stderr)
        return 1

    container = os.environ.get("AWG_CONTAINER", "")

    rows, meta = build_rows(awg_conf, clients_dir, container)

    if args.tsv:
        return cmd_tsv(rows)

    if args.resolve is not None:
        return cmd_resolve(rows, args.resolve)

    if args.detail is not None:
        return cmd_detail(rows, num=args.detail)

    if args.detail_name is not None:
        return cmd_detail(rows, name=args.detail_name)

    highlight_name = os.environ.get("AWG_HIGHLIGHT_NAME", "")
    print_table(rows, meta, highlight_name=highlight_name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
