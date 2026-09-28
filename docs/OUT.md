# OUT server — what to deploy (VLESS REALITY exit)

**Last updated:** 2026-09-02

This kit deploys the **IN server** today (AWG gateway → REALITY → OUT). **OUT** is a separate host for now (documented below; automated deploy planned). OUT runs xray with REALITY inbound and `freedom` exit.

**Quick deploy:** [Meridian](https://getmeridian.org/) (recommended). After deploy, copy credentials into IN `.data/.env` — see [mapping table](#meridian--x-ui--env-on-in) below.

---

## What OUT must have (minimal)

| Component | Required on OUT? | Notes |
|-----------|------------------|-------|
| **VLESS inbound + REALITY** on `OUT_EXIT` address (`OUT_REALITY_PORT`, usually 443) | **Yes** | IN xray outbound `exit` connects here |
| `flow: xtls-rprx-vision` on the bridge client | **Yes** | Must match IN `config.json` outbound |
| **`freedom` outbound** | **Yes** | Actual internet exit |
| **`blackhole` outbound** | Optional | Block unwanted traffic (bittorrent, private IPs) |
| **Listen** on public IP (v4 or v6 per `OUT_EXIT`) | **Yes** | `OUT_EXIT='4; <ipv4>'` or `OUT_EXIT='6; <gua-v6>'` |
| **SOCKS inbound** | **No** | SOCKS `:1080` lives on **IN** (`vpn-xray`) |
| **dokodemo-door** | **No** | DNS capture is on **IN** only (`config.json` `dns-in`) |
| **AmneziaWG / ipt2socks / udp-relay** | **No** | IN bridge only |

There is **one** public listener for the bridge: **TCP VLESS REALITY**. No extra “channels” beyond what x-ui/Meridian creates for REALITY (and optional WSS/xhttp for **human** clients — not used by this bridge).

---

## Shape of a working OUT `config.json` (example)

Generic xray fragment — replace placeholders with your OUT values. **Do not commit real `target` / `serverNames` / keys to git.**

```json
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "tunnel",
      "tag": "api"
    },
    {
      "listen": "<address from OUT_EXIT>",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "<bridge-client-label>",
            "flow": "xtls-rprx-vision",
            "id": "<OUT_VLESS_UUID>"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "<REALITY_DEST_HOST>:443",
          "serverNames": ["<SNI_1>", "<SNI_2>"],
          "privateKey": "<OUT_REALITY_PRIVATE_KEY>",
          "shortIds": ["<OUT_REALITY_SHORT_ID>"],
          "show": false
        }
      },
      "tag": "in-443-tcp"
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
```

**Checks before copying creds to IN:**

1. Client `id` → `OUT_VLESS_UUID` in IN `.env`
2. REALITY `publicKey` (from OUT private key) → `OUT_REALITY_PUBLIC_KEY`
3. `shortIds[0]` → `OUT_REALITY_SHORT_ID`
4. `OUT_REALITY_SERVER_NAME` on IN must be **one of** OUT `serverNames` (same string, case-sensitive)
5. Listen address → `OUT_EXIT` (`'4; <ipv4>'` or `'6; <gua-v6>'`); port → `OUT_REALITY_PORT` (usually `443`)
6. Expected internet egress IP → `OUT_EXPECTED_EGRESS='4; <ip>'` (check only, not in xray; use real curl IP, not `.env.example` placeholder)

On IN after edits: **`make build && make refresh-full`**.

---

## Meridian / x-ui → `.env` on IN

Meridian stores credentials under `~/.meridian/credentials/<server-id>/` on OUT. For the bridge you need the **REALITY** row used by x-ui for the IN tunnel client (not necessarily the default phone client UUID).

| OUT (Meridian / x-ui) | IN `.data/.env` |
|------------------------|-----------------|
| OUT listen address (IPv4 or IPv6) | `OUT_EXIT` (e.g. `'6; 2606:4700::1'`) |
| REALITY port (usually 443) | `OUT_REALITY_PORT` |
| Client UUID for bridge (dedicated x-ui user, not a phone client) | `OUT_VLESS_UUID` |
| REALITY `public_key` | `OUT_REALITY_PUBLIC_KEY` |
| REALITY `short_id` | `OUT_REALITY_SHORT_ID` |
| SNI / `serverName` (must ∈ OUT `serverNames`) | `OUT_REALITY_SERVER_NAME` |
| Expected public egress IP (curl check) | `OUT_EXPECTED_EGRESS` (e.g. `'4; 203.0.113.99'` — your real egress, not RFC5737 docs IP) |

**Do not copy** IN-side keys into OUT: `REALITY_PRIVATE_KEY` / `REALITY_SHORT_ID` in IN `.env` are for **optional VLESS inbound on IN** (`ENABLE_XRAY_INBOUND`), not for OUT.

---

## Verify from IN

```bash
# .env ↔ build outbound
make verify-inbound   # inbound on IN only; OUT keys still required in .env

# Reachability (from IN host)
source .data/.env
# shellcheck source=/dev/null
. scripts/lib/endpoint.sh && endpoint_resolve_env
docker compose -f .data/build/docker-compose.yml --env-file .data/.env \
  exec xray sh -c "if [ '${OUT_EXIT_FAMILY}' = 6 ]; then ping6 -c2 '${OUT_EXIT_ADDRESS}'; else ping -c2 '${OUT_EXIT_ADDRESS}'; fi"

# Exit IP from AWG client
curl -4 https://api.ipify.org   # should show OUT public IPv4
```

Phase 8 `make check` fails if any `OUT_*` key is empty or `OUT_EXIT` is still an RFC3849 documentation placeholder (`2001:db8::…`).

---

## OUT vs IN (do not confuse)

| | **OUT server** | **IN bridge** (this repo) |
|--|----------------|---------------------------|
| Role | Internet exit | AWG + DNS + SOCKS + REALITY **client** to OUT |
| Public listen | VLESS REALITY `:443` (IPv6) | AWG UDP; optional VLESS inbound; website may use `:443` if inbound off |
| dokodemo-door | No | Yes (`dns-in` on IN xray) |
| SOCKS `:1080` | No | Yes (Docker network, IN only) |
| Deploy tool | Meridian / x-ui / manual xray | `make refresh-full` |

→ [All documentation](./README.md)
