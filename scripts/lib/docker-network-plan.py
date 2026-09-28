#!/usr/bin/env python3
"""Docker bridge network plan — derive container IPs from DOCKER_NETWORK_SUBNET_* (SSOT)."""
from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any

# Stable host IDs on the vpn docker bridge (gateway .1, services .2–.4).
HOST_ROLES: tuple[tuple[str, int], ...] = (
    ("DOCKER_NETWORK_GATEWAY_IPV4", 1),
    ("COREDNS_IP", 2),
    ("AMNEZIAWG_IP", 3),
    ("XRAY_IP", 4),
    ("TELEPROXY_IP", 5),
)
HOST_ROLES_V6: tuple[tuple[str, int], ...] = (
    ("DOCKER_NETWORK_GATEWAY_IPV6", 1),
    ("COREDNS_IPV6", 2),
    ("AMNEZIAWG_IPV6", 3),
    ("XRAY_IPV6", 4),
    ("TELEPROXY_IPV6", 5),
)

DEFAULT_SUBNET_V4 = "10.200.97.0/24"
DEFAULT_SUBNET_V6 = "fd87:172:20::/64"

ENV_LINE = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def load_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        m = ENV_LINE.match(line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            val = val[1:-1]
        out[key] = val
    return out


def host_ip(network: ipaddress.IPv4Network | ipaddress.IPv6Network, host_id: int) -> str:
    if host_id < 1 or host_id >= network.num_addresses:
        raise ValueError(f"host_id {host_id} out of range for {network}")
    return str(network.network_address + host_id)


def parse_network_v4(cidr: str) -> ipaddress.IPv4Network:
    net = ipaddress.ip_network(cidr, strict=False)
    if not isinstance(net, ipaddress.IPv4Network):
        raise ValueError(f"not an IPv4 network: {cidr}")
    if net.prefixlen < 24 or net.prefixlen > 29:
        raise ValueError(f"DOCKER_NETWORK_SUBNET_IPV4 prefix must be /24–/29 (got /{net.prefixlen})")
    return net


def parse_network_v6(cidr: str) -> ipaddress.IPv6Network:
    net = ipaddress.ip_network(cidr, strict=False)
    if not isinstance(net, ipaddress.IPv6Network):
        raise ValueError(f"not an IPv6 network: {cidr}")
    if preflight_ipv6_is_doc_prefix(str(net.network_address)):
        raise ValueError(f"RFC3849 docs prefix not allowed: {cidr}")
    return net


def preflight_ipv6_is_doc_prefix(addr: str) -> bool:
    low = addr.lower()
    return low.startswith("2001:db8:") or low.startswith("2001:0db8:")


def ensure_ip_in_network(ip: str, network: ipaddress._BaseNetwork, label: str) -> None:
    addr = ipaddress.ip_address(ip)
    if addr not in network:
        raise ValueError(f"{label}={ip} is outside {network}")


def resolve_plan(env: dict[str, str]) -> dict[str, str]:
    """Merge .env with derived docker bridge addresses."""
    explicit = set(env.keys())
    out = dict(env)

    subnet_v4 = out.get("DOCKER_NETWORK_SUBNET_IPV4") or DEFAULT_SUBNET_V4
    net4 = parse_network_v4(subnet_v4)
    out["DOCKER_NETWORK_SUBNET_IPV4"] = str(net4)
    out["VPN_DOCKER_SUBNET_CIDR"] = str(net4)

    for key, host_id in HOST_ROLES:
        derived = host_ip(net4, host_id)
        if key not in explicit or not out.get(key):
            out[key] = derived
        else:
            ensure_ip_in_network(out[key], net4, key)

    subnet_v6 = out.get("DOCKER_NETWORK_SUBNET_IPV6") or DEFAULT_SUBNET_V6
    net6 = parse_network_v6(subnet_v6)
    out["DOCKER_NETWORK_SUBNET_IPV6"] = str(net6)

    for key, host_id in HOST_ROLES_V6:
        derived = host_ip(net6, host_id)
        if key not in explicit or not out.get(key):
            out[key] = derived
        else:
            ensure_ip_in_network(out[key], net6, key)

    return out


def subnets_overlap(a: str, b: str) -> bool:
    try:
        na = ipaddress.ip_network(a, strict=False)
        nb = ipaddress.ip_network(b, strict=False)
    except ValueError:
        return False
    if na.version != nb.version:
        return False
    return na.overlaps(nb)


def load_docker_networks_json(raw: str) -> list[dict[str, Any]]:
    data = json.loads(raw)
    if not isinstance(data, list):
        raise ValueError("docker networks json must be an array")
    return data


def check_docker_overlap(plan_subnet_v4: str, docker_networks: list[dict[str, Any]], skip_names: set[str]) -> list[str]:
    """Return list of conflicting network descriptions."""
    conflicts: list[str] = []
    for item in docker_networks:
        name = item.get("Name") or "?"
        if name in skip_names:
            continue
        for cfg in item.get("IPAM", {}).get("Config") or []:
            sub = cfg.get("Subnet")
            if not sub:
                continue
            if subnets_overlap(plan_subnet_v4, sub):
                conflicts.append(f"{name} ({sub})")
    return conflicts


def cmd_resolve(args: argparse.Namespace) -> int:
    env = load_env_file(Path(args.env_file))
    if args.json_env:
        env.update(json.loads(args.json_env))
    try:
        plan = resolve_plan(env)
    except ValueError as exc:
        print(f"docker-network-plan: {exc}", file=sys.stderr)
        return 1
    if args.format == "shell":
        for key in sorted(plan.keys()):
            val = plan[key].replace("'", "'\\''")
            print(f"{key}='{val}'")
    else:
        print(json.dumps(plan, indent=2, sort_keys=True))
    return 0


def cmd_check_overlap(args: argparse.Namespace) -> int:
    env = load_env_file(Path(args.env_file))
    subnet = env.get("DOCKER_NETWORK_SUBNET_IPV4") or DEFAULT_SUBNET_V4
    try:
        parse_network_v4(subnet)
    except ValueError as exc:
        print(json.dumps({"ok": False, "subnet": subnet, "conflicts": [], "error": str(exc)}))
        return 0

    try:
        if getattr(args, "networks_file", None):
            raw = Path(args.networks_file).read_text(encoding="utf-8")
        else:
            raw = args.networks_json
        networks = load_docker_networks_json(raw)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "subnet": subnet, "conflicts": [], "error": str(exc)}))
        return 0

    skip = set(args.skip_name or [])
    conflicts = check_docker_overlap(subnet, networks, skip)
    print(json.dumps({"ok": len(conflicts) == 0, "subnet": subnet, "conflicts": conflicts}))
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Docker bridge network SSOT")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("resolve", help="derive gateway and container IPs from subnet")
    r.add_argument("--env-file", required=True)
    r.add_argument("--format", choices=("shell", "json"), default="shell")
    r.add_argument("--json-env", default="", help="extra JSON object of env overrides")
    r.set_defaults(func=cmd_resolve)

    c = sub.add_parser("check-overlap", help="detect Docker subnet collisions")
    c.add_argument("--env-file", required=True)
    c.add_argument("--networks-json", default="", help="docker network inspect JSON array")
    c.add_argument("--networks-file", default="", help="file with docker network inspect JSON")
    c.add_argument("--skip-name", action="append", default=["vpn"])
    c.set_defaults(func=cmd_check_overlap)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
