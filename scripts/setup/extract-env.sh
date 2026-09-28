#!/usr/bin/env bash
# Extract secrets and tuning from .data/build/* → .data/.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"

if [[ -n "${EXTRACT_TEST_ROOT:-}" ]]; then
  BUILD_DIR="${EXTRACT_TEST_ROOT}/build"
  AWG_CLIENTS_DIR="${EXTRACT_TEST_ROOT}/clients_awg"
  AWG_CONF="${BUILD_DIR}/awg0.conf"
  XRAY_CONF="${BUILD_DIR}/config.json"
  COMPOSE_FILE="${BUILD_DIR}/docker-compose.yml"
  ENV_FILE="${EXTRACT_TEST_ROOT}/.env"
fi

AWG="${AWG_CONF}"
XRAY="${XRAY_CONF}"
RS_A="${BUILD_DIR}/ipt2socks-amneziawg-v4.sh"
COMPOSE="${COMPOSE_FILE}"
CLIENTS="${AWG_CLIENTS_DIR}"
ENV_OUT="${ENV_FILE}"

for f in "$AWG" "$XRAY" "$RS_A" "$COMPOSE"; do
  [[ -f "$f" ]] || { echo "[extract-env] missing: $f" >&2; exit 1; }
done

python3 - "$AWG" "$XRAY" "$RS_A" "$COMPOSE" "$CLIENTS" "$ENV_OUT" <<'PY'
import ipaddress
import json
import re
import sys
from pathlib import Path

awg_path, xray_path, rs_path, compose_path, clients_dir, env_path = sys.argv[1:7]
awg = Path(awg_path).read_text(encoding="utf-8")
xray = json.loads(Path(xray_path).read_text(encoding="utf-8"))
rs = Path(rs_path).read_text(encoding="utf-8")
compose = Path(compose_path).read_text(encoding="utf-8")

def awg_val(key):
    m = re.search(rf"^{re.escape(key)} = (.+)$", awg, re.M)
    return m.group(1).strip() if m else ""

def awg_ipv6():
    m = re.search(r"DNAT --to-destination \[([0-9a-f:]+)\]:53", awg)
    return m.group(1) if m else ""

def redirect_port(family: str) -> str:
    table = "ip6tables" if family == "v6" else "iptables"
    m = re.search(
        rf"{table} -t nat -A PREROUTING -i awg0 -p tcp ! --dport 53 -j REDIRECT --to-port (\d+)",
        awg,
    )
    return m.group(1) if m else ""

def ports_env(key: str, default: str) -> str:
    ports = Path(rs_path).parent / "ipt2socks-ports.env"
    if not ports.is_file():
        return default
    for line in ports.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    return default

def nfqueue_num() -> str:
    m = re.search(
        r"iptables -t mangle -A PREROUTING -i awg0 -p udp .* -j NFQUEUE --queue-num (\d+)",
        awg,
    )
    if m:
        return m.group(1)
    m = re.search(
        r"NFQUEUE --queue-num (\d+)",
        awg,
    )
    return m.group(1) if m else "100"

def derive_subnet(addr: str) -> tuple[str, str]:
    """Return (gateway_host, subnet_cidr) from an Address line value."""
    iface = ipaddress.ip_interface(addr.strip())
    return str(iface.ip), str(iface.network)

addrs = re.findall(r"^Address = (.+)$", awg, re.M)
awg_v4 = addrs[0] if addrs else "10.8.0.1/24"
awg_v6 = addrs[1] if len(addrs) > 1 else "fd86:ea04:1115::1/64"
gw_v4, subnet_v4 = derive_subnet(awg_v4)
_, subnet_v6 = derive_subnet(awg_v6)

coredns_v6 = awg_ipv6()
docker_v4_subnet = "10.200.97.0/24"
m_xray = re.search(r'-s "?([\d.]+)"?', rs)
if m_xray:
    try:
        xray_ip = ipaddress.IPv4Address(m_xray.group(1))
        docker_v4_subnet = str(ipaddress.IPv4Network(f"{xray_ip}/24", strict=False))
    except ValueError:
        pass
docker_v6_subnet = "fd87:172:20::/64"
docker_v6_gw = "fd87:172:20::1"
if coredns_v6:
    try:
        net6 = ipaddress.IPv6Network(f"{ipaddress.IPv6Address(coredns_v6)}/64", strict=False)
        docker_v6_subnet = str(net6)
        docker_v6_gw = str(net6.network_address + 1)
    except ValueError:
        pass

awg_listen = awg_val("ListenPort") or "51820"

compose_awg = re.search(r"0\.0\.0\.0:(\d+):(\d+)/udp", compose)
awg_host_port = compose_awg.group(1) if compose_awg else ""
if compose_awg and compose_awg.group(2):
    awg_listen = compose_awg.group(2)

m = re.search(r'-l "?(\d+)"?', rs)
ipt2socks_port = m.group(1) if m else redirect_port("v4") or "12345"
ipt2socks_port_v6 = redirect_port("v6") or "12346"
udp_relay_port = ports_env("AWG_UDP_RELAY_PORT", "12348")
udp_relay_port_v6 = ports_env("AWG_UDP_RELAY_PORT_IPV6", "12349")
awg_nfqueue_num = nfqueue_num()

socks_ib = next((ib for ib in xray["inbounds"] if ib.get("protocol") == "socks"), {})
vless_ib = next((ib for ib in xray["inbounds"] if ib.get("protocol") == "vless"), {})

socks_port = str(socks_ib.get("port") or "")
if not socks_port:
    m = re.search(r"127\.0\.0\.1:(\d+):(\d+)/tcp", compose)
    socks_port = m.group(1) if m else "1080"

if vless_ib:
    enable_inbound = "1"
    xray_inbound_port = str(vless_ib.get("port") or "")
else:
    enable_inbound = "0"
    xray_inbound_port = "443"
m = re.search(r"0\.0\.0\.0:(\d+):\d+/tcp", compose)
if m:
    xray_inbound_port = m.group(1)
    if not vless_ib:
        enable_inbound = "0"


exit_ob = next((ob for ob in xray["outbounds"] if ob.get("tag") == "exit"), {})
vnext = ((exit_ob.get("settings") or {}).get("vnext") or [{}])[0]
out_reality_port = str(vnext.get("port") or "443")

def endpoint_tuple(addr: str) -> str:
    if not addr:
        return ""
    if ":" in addr:
        return f"6; {addr}"
    return f"4; {addr}"

out_addr = vnext.get("address", "") or ""

in_server_ip = ""
clients_path = Path(clients_dir)
if clients_path.is_dir():
    for conf in sorted(clients_path.glob("*.conf")):
        text = conf.read_text(encoding="utf-8")
        m = re.search(r"^Endpoint = ([0-9.]+):", text, re.M)
        if m:
            in_server_ip = m.group(1)
            break

socks_user = ""
socks_pass = ""
m = re.search(r'-a "([^"]+)"', rs)
if m:
    socks_user = m.group(1)
m = re.search(r'-k "([^"]+)"', rs)
if m:
    socks_pass = m.group(1)

rs_in = (vless_ib.get("streamSettings") or {}).get("realitySettings") or {}
exit_ob = next((ob for ob in xray["outbounds"] if ob.get("tag") == "exit"), {})
exit_rs = (exit_ob.get("streamSettings") or {}).get("realitySettings") or {}
vnext = ((exit_ob.get("settings") or {}).get("vnext") or [{}])[0]
user = ((vnext.get("users") or [{}])[0])

def q(s: str) -> str:
    if re.search(r'[\s#"\'\\]', s):
        return "'" + s.replace("'", "'\\''") + "'"
    return s

lines = [
    "# Auto-extracted from .data/build/ — do not commit",
    "#",
    "# PORT LEGEND:",
    "#   HOST PUBLISH  → may conflict on this machine (make check 7)",
    "#   OUT EXIT      → IN connects out; not listen on IN",
    "#   INTERNAL      → Docker / container / tunnel only",
    "",
    "################################################################################",
    "#  HOST PUBLISH (IN) — AmneziaWG + optional VLESS clients",
    "################################################################################",
    "",
    f"IN_INGRESS={q(endpoint_tuple(in_server_ip))}",
    "IN_BRIDGE_SOURCE=auto",
    f"AWG_PORT={q(awg_host_port or '58285')}",
    f"ENABLE_XRAY_INBOUND={enable_inbound}",
    f"XRAY_INBOUND_PORT={xray_inbound_port}",
    "",
    f"REALITY_DEST={q(rs_in.get('dest', ''))}",
    f"REALITY_INBOUND_SERVER_NAME={q((rs_in.get('serverNames') or [''])[0])}",
    f"REALITY_PRIVATE_KEY={q(rs_in.get('privateKey', ''))}",
    f"REALITY_SHORT_ID={q((rs_in.get('shortIds') or [''])[0])}",
    "",
    "################################################################################",
    "#  OUT EXIT (remote) — IN xray outbound target",
    "################################################################################",
    "",
    f"OUT_EXIT={q(endpoint_tuple(out_addr))}",
    f"OUT_REALITY_PORT={out_reality_port}",
    f"OUT_VLESS_UUID={q(user.get('id', ''))}",
    f"OUT_REALITY_PUBLIC_KEY={q(exit_rs.get('publicKey', ''))}",
    f"OUT_REALITY_SHORT_ID={q(exit_rs.get('shortId', ''))}",
    f"OUT_REALITY_SERVER_NAME={q(exit_rs.get('serverName', ''))}",
    "",
    "################################################################################",
    "#  INTERNAL — not host publish",
    "################################################################################",
    "",
    f"AWG_LISTEN_PORT={awg_listen}",
    f"SOCKS_PORT={socks_port}",
    f"SOCKS_USER={q(socks_user)}",
    f"SOCKS_PASSWORD={q(socks_pass)}",
    "",
    f"AWG_SERVER_PRIVATE_KEY={q(awg_val('PrivateKey'))}",
    f"AWG_TUNNEL_IPV4={awg_v4}",
    f"AWG_TUNNEL_IPV6={awg_v6}",
    f"AWG_TUNNEL_SUBNET_IPV4={subnet_v4}",
    f"AWG_TUNNEL_SUBNET_IPV6={subnet_v6}",
    f"AWG_TUNNEL_GATEWAY_IPV4={gw_v4}",
    f"AWG_TUNNEL_GATEWAY_IPV6={q(awg_v6.split('/')[0] if awg_v6 else 'fd86:ea04:1115::1')}",
    f"AWG_JC={awg_val('Jc')}",
    f"AWG_JMIN={awg_val('Jmin')}",
    f"AWG_JMAX={awg_val('Jmax')}",
    f"AWG_S1={awg_val('S1')}",
    f"AWG_S2={awg_val('S2')}",
    f"AWG_S3={awg_val('S3')}",
    f"AWG_S4={awg_val('S4')}",
    f"AWG_H1={q(awg_val('H1'))}",
    f"AWG_H2={q(awg_val('H2'))}",
    f"AWG_H3={q(awg_val('H3'))}",
    f"AWG_H4={q(awg_val('H4'))}",
    "",
    f"AWG_IPT2SOCKS_PORT={ipt2socks_port}",
    f"AWG_IPT2SOCKS_PORT_IPV6={ipt2socks_port_v6}",
    f"AWG_UDP_RELAY_PORT={udp_relay_port}",
    f"AWG_UDP_RELAY_PORT_IPV6={udp_relay_port_v6}",
    f"AWG_NFQUEUE_NUM={awg_nfqueue_num}",
    f"AWG_UDP_RELAY_LOG_LEVEL={ports_env('AWG_UDP_RELAY_LOG_LEVEL', 'info')}",
    f"COREDNS_IPT2SOCKS_PORT=12347",
    "AWG_TOOLS_REF=ee0f0a9aa34ff0a0da4b3433b9512781cfe02843",
    "AMNEZIAWG_RELEASE=latest",
    "",
    f"DOCKER_NETWORK_SUBNET_IPV4={docker_v4_subnet}",
    f"DOCKER_NETWORK_SUBNET_IPV6={docker_v6_subnet}",
] + ([f"COREDNS_IPV6={q(coredns_v6)}"] if coredns_v6 else []) + [
    f"DOCKER_NETWORK_GATEWAY_IPV6={q(docker_v6_gw)}",
    "# COREDNS_IP / AMNEZIAWG_IP / XRAY_IP derived on make build",
    "",
    "IPT2SOCKS_THREADS=2",
    "IPT2SOCKS_NOFILE_LIMIT=8192",
    "IPT2SOCKS_UDP_TIMEOUT=60",
    "AMNEZIAWG_MEM_LIMIT=512m",
    "COREDNS_MEM_LIMIT=256m",
    "LOG_MAX_SIZE=5m",
    "LOG_MAX_FILE=2",
]

preserve_keys = (
    "AWG_PORT",
    "AWG_LISTEN_PORT",
    "AWG_TOOLS_REF",
    "AMNEZIAWG_RELEASE",
    "IN_INGRESS",
    "ENABLE_XRAY_INBOUND",
    "XRAY_INBOUND_PORT",
    "OUT_REALITY_PORT",
    "ENABLE_MTPROXY",
    "TELEPROXY_VERSION",
    "MTPROXY_MODE",
    "MTPROXY_HOST_PORT",
    "MTPROXY_EE_DOMAIN",
    "MTPROXY_SNI",
    "MTPROXY_PUBLISH",
    "MTPROXY_STATS_PORT",
)
env_file = Path(env_path)
if env_file.is_file():
    old = env_file.read_text(encoding="utf-8")
    for key in preserve_keys:
        m = re.search(rf"^{key}=(.+)$", old, re.M)
        if not m:
            continue
        val = m.group(1).strip()
        if key == "IN_INGRESS" and not val:
            continue
        for i, line in enumerate(lines):
            if line.startswith(f"{key}="):
                lines[i] = f"{key}={val}"
                break

Path(env_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
Path(env_path).chmod(0o600)
print(f"[extract-env] wrote {env_path}")
if not in_server_ip:
    print("[extract-env] WARN: IN_INGRESS not found in client exports — set manually", file=sys.stderr)
PY

echo "[extract-env] peers in awg0: $(grep -c '^\[Peer\]' "$AWG" || true)"
