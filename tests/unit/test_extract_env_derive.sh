#!/usr/bin/env bash
# Unit tests for extract-env derive logic — temp fixtures only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXTRACT="${REPO_ROOT}/scripts/setup/extract-env.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "${TMP}/build" "${TMP}/clients_awg"

cat > "${TMP}/build/awg0.conf" <<'EOF'
[Interface]
PrivateKey = SECRETKEY
Address = 10.8.0.1/24
Address = fd86:ea04:1115::1/64
ListenPort = 51820
PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp ! --dport 53 -j REDIRECT --to-port 12345
PostUp = ip6tables -t nat -A PREROUTING -i awg0 -p tcp ! --dport 53 -j REDIRECT --to-port 12346
PostUp = ip6tables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination [fd87:172:20::2]:53
EOF

cat > "${TMP}/build/ipt2socks-amneziawg-v4.sh" <<'EOF'
#!/bin/sh
exec ipt2socks -R -4 -T -b 10.8.0.1 -l 12345 -s 172.20.0.4 -p 1080 -a "vpn-user" -k "secret"
EOF

cat > "${TMP}/build/config.json" <<'EOF'
{
  "inbounds": [
    {"protocol": "socks", "port": 1080, "settings": {"accounts": [{"user": "vpn-user", "pass": "secret"}]}},
    {"protocol": "vless", "port": 443, "streamSettings": {"realitySettings": {"dest": "x:443", "serverNames": ["apple.com"], "privateKey": "k", "shortIds": ["sid"]}}}
  ],
  "outbounds": [{"tag": "exit", "settings": {"vnext": [{"address": "2a10::1", "users": [{"id": "uuid-out"}]}]}, "streamSettings": {"realitySettings": {"publicKey": "pk", "shortId": "s", "serverName": "dl.google.com"}}}]
}
EOF

cat > "${TMP}/build/docker-compose.yml" <<'EOF'
services:
  xray:
    ports:
      - "0.0.0.0:443:443/tcp"
      - "127.0.0.1:1080:1080/tcp"
  amneziawg:
    ports:
      - "0.0.0.0:58285:51820/udp"
EOF

cat > "${TMP}/clients_awg/phone.conf" <<'EOF'
[Peer]
Endpoint = 203.0.113.50:58285
EOF

EXTRACT_TEST_ROOT="${TMP}" bash "${EXTRACT}"

ENV_OUT="${TMP}/.env"
grep -qE '^IN_INGRESS=.?4; 203\.0\.113\.50' "${ENV_OUT}" || fail "IN_INGRESS missing"
grep -qE '^OUT_EXIT=.?6; 2a10::1' "${ENV_OUT}" || fail "OUT_EXIT missing"
grep -q '^AWG_PORT=58285$' "${ENV_OUT}" || fail "AWG_PORT should be host publish port"
grep -q '^AWG_LISTEN_PORT=51820$' "${ENV_OUT}" || fail "AWG_LISTEN_PORT missing"
grep -q '^AWG_TUNNEL_SUBNET_IPV4=10.8.0.0/24$' "${ENV_OUT}" || fail "subnet v4"
grep -q '^AWG_TUNNEL_SUBNET_IPV6=fd86:ea04:1115::/64$' "${ENV_OUT}" || fail "subnet v6"
grep -q '^AWG_TUNNEL_GATEWAY_IPV4=10.8.0.1$' "${ENV_OUT}" || fail "gateway v4"
grep -q '^AWG_TUNNEL_GATEWAY_IPV6=fd86:ea04:1115::1$' "${ENV_OUT}" || fail "gateway v6"
grep -q '^AWG_IPT2SOCKS_PORT=12345$' "${ENV_OUT}" || fail "ipt2socks port"
grep -q '^AWG_IPT2SOCKS_PORT_IPV6=12346$' "${ENV_OUT}" || fail "ipt2socks v6 port"
grep -q '^COREDNS_IPT2SOCKS_PORT=12347$' "${ENV_OUT}" || fail "coredns ipt2socks port"
grep -q '^ENABLE_XRAY_INBOUND=1$' "${ENV_OUT}" || fail "ENABLE_XRAY_INBOUND"
grep -q '^XRAY_INBOUND_PORT=443$' "${ENV_OUT}" || fail "xray inbound"
grep -q '^OUT_REALITY_PORT=443$' "${ENV_OUT}" || fail "OUT_REALITY_PORT"
grep -q '^SOCKS_PORT=1080$' "${ENV_OUT}" || fail "socks port"
grep -q '^AWG_SERVER_PRIVATE_KEY=SECRETKEY$' "${ENV_OUT}" || fail "private key preserved"
grep -q '^OUT_REALITY_SERVER_NAME=dl.google.com$' "${ENV_OUT}" || fail "OUT_REALITY_SERVER_NAME"
grep -q '^REALITY_INBOUND_SERVER_NAME=apple.com$' "${ENV_OUT}" || fail "REALITY_INBOUND_SERVER_NAME"
grep -q '^COREDNS_IPV6=fd87:172:20::2$' "${ENV_OUT}" || fail "COREDNS_IPV6 from awg DNAT"
grep -q '^DOCKER_NETWORK_SUBNET_IPV6=fd87:172:20::/64$' "${ENV_OUT}" || fail "docker v6 subnet"
grep -q '^DOCKER_NETWORK_GATEWAY_IPV6=fd87:172:20::1$' "${ENV_OUT}" || fail "docker v6 gateway"

echo "OK: test_extract_env_derive"
