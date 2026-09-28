# MTProxy (Teleproxy) on IN

**Last updated:** 2026-09-04  
**Stage:** 0–6 — optional 4th container; default off. Stages 5–6 add client helpers and SNI profile (9+ target).

Optional Telegram MTProto ingress via upstream [Teleproxy](https://github.com/teleproxy/teleproxy). The kit provides compose wiring, `.env` flags, and egress through the existing AWG exit path (SOCKS → REALITY OUT).

See also: [ARCHITECTURE.md](./ARCHITECTURE.md), [PORT-443.md](./PORT-443.md).  
**Telegram calls:** [docs index](./README.md#telegram-calls).

---

## Telegram calls — not supported

| | **AWG (VPN)** | **MTProxy** |
|---|:---:|:---:|
| **Calls** | ✅ | ❌ |

MTProxy is **TCP only** (MTProto to DC). Telegram call media uses **UDP** and does not traverse `tg://proxy` — expected behavior, not a kit/nginx/SNI bug. For calls, users need **AWG** ([VOICE.md](./VOICE.md)). Reference: [MTProxy issue #217](https://github.com/TelegramMessenger/MTProxy/issues/217) (TCP-based protocol).

---

## Architecture decisions

| Decision | Choice |
|----------|--------|
| Implementation | Upstream image `ghcr.io/teleproxy/teleproxy:${TELEPROXY_VERSION}` (pin tag, not `:latest` in prod) |
| Container | `vpn-teleproxy` — 4th service on Docker network `vpn`, IP `.5` (`TELEPROXY_IP`) |
| Build | Pull only — no `containers/teleproxy/` fork |
| Egress | `DIRECT_MODE=true` + `SOCKS5_PROXY` → `${XRAY_IP}:1080` → REALITY OUT |
| Fake-TLS | `MTPROXY_EE_DOMAIN` required when enabled |
| nginx | **Outside compose** — sites stay on host (see profiles below) |
| AWG path | Unchanged |

### Target flow (when enabled)

```mermaid
flowchart TB
  subgraph clients [Clients]
    AWG[AWG client]
    VLESS[VLESS client]
    TG[Telegram app]
    SITE[Site visitor / DPI probe]
  end

  subgraph IN ["IN server — kit + host nginx"]
    NGX_S["nginx host :443<br/>stream SNI router — profile sni"]
    NGX_H["nginx http :8080 or :443<br/>TLS websites"]
    AWG_C["vpn-amneziawg"]
    DNS_C["vpn-coredns"]
    XRAY["vpn-xray<br/>SOCKS :1080 + REALITY outbound"]
    MTP["vpn-teleproxy<br/>Fake-TLS optional"]
  end

  OUT["OUT server<br/>VLESS REALITY exit"]

  AWG -->|UDP AWG_PORT| AWG_C
  AWG_C --> XRAY
  DNS_C --> XRAY
  VLESS -.->|profile sni :443| NGX_S
  TG --> MTP
  SITE --> NGX_H
  NGX_S -.-> MTP
  NGX_S -.-> XRAY
  NGX_S -.-> NGX_H
  MTP -->|SOCKS5| XRAY
  XRAY --> OUT
```

**Notes**

- All `vpn-*` containers share bridge `vpn` (pinned IPs via `docker-network-plan`).
- **Host TCP :443 — single listener.** See mutex table below.
- VLESS inbound exists today (`ENABLE_XRAY_INBOUND`); client export scripts are a future sprint.
- Stage 1 default profile **`standalone`**: MTProxy on `MTPROXY_HOST_PORT` (default **8444**), nginx sites on **:443** unchanged.

---

## Profiles

### `MTPROXY_MODE=standalone` (MVP — stage 1–4)

| Component | Port |
|-----------|------|
| nginx sites | **:443** (unchanged) |
| `vpn-teleproxy` | **`MTPROXY_HOST_PORT`** default **8444** (`0.0.0.0:8444→container:443`) |
| Stats | `127.0.0.1:8888` only |

Telegram links use `port=8444` (or your `MTPROXY_EXTERNAL_PORT`).

### `MTPROXY_MODE=sni` (prod target — stage 6+)

| Component | Port |
|-----------|------|
| nginx stream | **:443** — SNI router (host ops, not in kit) |
| `vpn-teleproxy` | `127.0.0.1:8444` → container `:443` |
| nginx sites | `:8080` behind stream (certbot → DNS-01) |
| Client links | `port=443` (`MTPROXY_EXTERNAL_PORT=443`) |

Document nginx stream config in a maintenance window before switching prod sites.

---

## Host :443 mutex

| ENABLE_MTPROXY | MTPROXY_MODE | Who owns host :443 |
|----------------|--------------|-------------------|
| 0 | — | nginx and/or xray inbound (`ENABLE_XRAY_INBOUND`) |
| 1 | standalone | **nginx** (sites); MTProxy on **8444** |
| 1 | sni | **nginx stream** only; proxies on loopback high ports |

`make build` fails if `MTPROXY_MODE=standalone` and `MTPROXY_HOST_PORT=443` with public publish (conflicts with sites).

---

## `.env` variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ENABLE_MTPROXY` | `0` | Master switch |
| `MTPROXY_MODE` | `standalone` | `standalone` \| `sni` |
| `TELEPROXY_VERSION` | `4.12.0` | Pinned upstream image tag (`EXTERNAL_PORT` for link port needs ≥4.12.0) |
| `MTPROXY_SECRET` | empty | 32 hex chars; auto-generated in container if empty |
| `MTPROXY_EE_DOMAIN` | — | Fake-TLS domain (required when enabled) |
| `MTPROXY_SNI` | empty | For nginx SNI map (stage 6) |
| `MTPROXY_CONTAINER_PORT` | `443` | Listen port inside container |
| `MTPROXY_HOST_PORT` | `8444` | Host-side publish port |
| `MTPROXY_PUBLISH` | `0.0.0.0` | Bind address (`127.0.0.1` forced in `sni` mode) |
| `MTPROXY_EXTERNAL_PORT` | derived | Port in `tg://` links |
| `MTPROXY_STATS_PORT` | `8888` | Loopback stats only |
| `MTPROXY_DIRECT_MODE` | `true` | Direct-to-DC via SOCKS egress |
| `MTPROXY_WORKERS` | `1` | Teleproxy workers |
| `MTPROXY_DC_PROBE_INTERVAL` | `30` | DC health probes |
| `MTPROXY_MEM_LIMIT` | `128m` | Container memory cap |

**Derived at `make build` (do not set in `.env`):**

- `TELEPROXY_IP` / `TELEPROXY_IPV6` — docker bridge `.5`
- `IN_INGRESS_ADDR` — from `IN_INGRESS` (IPv4)
- `MTPROXY_SOCKS5_PROXY` — `socks5://USER:PASS@XRAY_IP:1080`
- `MTPROXY_CONFIG_DOWNLOAD_PROXY` — defaults to SOCKS5

---

## Enable on staging (standalone)

### Prerequisites

- OUT exit reachable (same as AWG stack).
- Host nginx sites on **:443** unchanged (`ENABLE_XRAY_INBOUND=0` typical).
- Security group / firewall: open **TCP `MTPROXY_HOST_PORT`** (default **8444**) to the internet.
- Fake-TLS domain set (`MTPROXY_EE_DOMAIN` — e.g. `www.google.com`).

### Deploy steps

```bash
# .data/.env
ENABLE_MTPROXY=1
MTPROXY_MODE=standalone
MTPROXY_EE_DOMAIN=www.google.com
TELEPROXY_VERSION=4.12.0
MTPROXY_HOST_PORT=8444
ENABLE_XRAY_INBOUND=0

make build && make images-pull-upstream && make refresh-full
make verify-mtproxy
make verify-mtproxy && make check --phases 7-11   # or: make regression-443
```

### Smoke checklist (staging)

| Step | Command | Pass |
|------|---------|------|
| Container up | `docker ps --filter name=vpn-teleproxy` | running, healthy |
| Client link | `docker logs vpn-teleproxy 2>&1 \| grep -A5 "Connection Links"` | `tg://` link with `port=8444` |
| Stats loopback | `curl -s http://127.0.0.1:8888/stats \| head` | JSON metrics |
| Sites unchanged | `curl -sI https://your-domain/` | 200/301 as before |
| AWG path | client ping + curl via VPN | unchanged |
| Telegram | add proxy from link on test phone | connects, messages send |
| Ingress smoke | `make verify-mtproxy-smoke` | OK — link port + TCP + stats |

Save exported links: **`make mtproxy-export NAME=<name>`** → `.data/clients_mtproxy/<name>.txt` (runs smoke unless `SKIP_MTPROXY_SMOKE=1`).

### 24h monitoring (staging)

- `docker logs vpn-teleproxy --since 1h` — no crash loops.
- `curl -s http://127.0.0.1:8888/stats` — active connections reasonable.
- `make check` — no new FAIL on phases 7–9.
- Confirm nginx still owns **:443** (`ss -tlnp \| grep ':443'`).

### Rollback

```bash
# .data/.env
ENABLE_MTPROXY=0

make build && make refresh-full
make verify-mtproxy   # OK — MTProxy disabled
```

Removes `vpn-teleproxy` from compose; host **:443** and AWG path unchanged.

---

## Upgrades (Teleproxy image)

1. Pick a release tag from [Teleproxy releases](https://github.com/teleproxy/teleproxy/releases).
2. Set `TELEPROXY_VERSION=<tag>` in `.data/.env`.
3. `make images-pull-upstream && make refresh-full` (never `docker restart vpn-teleproxy` alone).
4. `make verify-mtproxy && make check --phases 7-9`.

`make images-pull-upstream` pulls **only when** `ENABLE_MTPROXY=1`.

---

## Preflight (phases 7–9)

| Phase | Probe | FAIL when |
|-------|-------|-----------|
| 7 | `mtproxy-port` | `vpn-teleproxy` on `0.0.0.0:443`; standalone + public `:443`; stats not loopback |
| 8 | `mtproxy-sync` | `.env` MTProxy flags ≠ rendered compose (`make verify-mtproxy`) |
| 8 | `MTPROXY_*` keys | empty when `ENABLE_MTPROXY=1` |
| 8 | `teleproxy-image` | WARN if image missing — `make images-pull-upstream` |
| 9 | `vpn-teleproxy` | expected only when `ENABLE_MTPROXY=1` |

Manual sync check: **`make verify-mtproxy`**.

See [CHECK.md](./CHECK.md) and [PORT-443.md](./PORT-443.md).

---

---

## Export (stage 5)

```bash
make mtproxy-export NAME=main          # after vpn-teleproxy is up
make mtproxy-list
make mtproxy-rotate-secret             # new MTPROXY_SECRET → make refresh-full
```

Files: `.data/clients_mtproxy/<name>.txt` (mode 600, directory 700). One export = snapshot of the **same** server link (not per-user credentials like AWG).

`vpn-teleproxy` has a **healthcheck** on the stats endpoint (`MTPROXY_STATS_PORT`).

---

## SNI profile — prod 9+ (stage 6)

**Goal:** Telegram (and optional VLESS) on **public `:443`** together with nginx sites — single nginx stream listener.

**Operator runbook:** [SNI-CUTOVER.md](./SNI-CUTOVER.md) (maintenance window, DNS-01, rollback).  
**EE secret note:** map **both** `MTPROXY_SNI` and `MTPROXY_EE_DOMAIN` (and domain from `ee` secret hex tail — often `www.google.com`) → `127.0.0.1:8444`. `make check 11` runs `nginx-sni-map` + `nginx-sni-tls` — see [SNI-9-PLUS.md](./SNI-9-PLUS.md).

### Kit changes (`MTPROXY_MODE=sni`)

| Setting | Value |
|---------|--------|
| `MTPROXY_PUBLISH` | `127.0.0.1` (forced) |
| `MTPROXY_HOST_PORT` | `8444` (loopback backend) |
| `MTPROXY_EXTERNAL_PORT` | `443` (in `tg://` links) |
| `MTPROXY_SNI` | **required** — hostname in nginx `map` |
| `XRAY_INBOUND_PORT` | `8443` typical (loopback if inbound enabled) |
| Xray compose publish | `127.0.0.1:8443` (not `0.0.0.0`) |

### Host nginx (operator)

Template: **`config/examples/nginx-stream-443.conf.example`**

1. Install stream snippet → `/etc/nginx/stream.d/vpn-bridge-443.conf`
2. Map `MTPROXY_SNI` → `127.0.0.1:8444`, `REALITY_INBOUND_SERVER_NAME` → `127.0.0.1:8443`, sites → `127.0.0.1:8080`
3. Move site vhosts: `listen 443` → `listen 127.0.0.1:8080 ssl` (same certs; **certbot DNS-01**)
4. `nginx -t && systemctl reload nginx`

### Deploy (sni)

```bash
# .data/.env
ENABLE_MTPROXY=1
MTPROXY_MODE=sni
MTPROXY_SNI=google.com   # must match EE hex tail in secret / ClientHello SNI
MTPROXY_EE_DOMAIN=www.google.com
ENABLE_XRAY_INBOUND=1          # optional
XRAY_INBOUND_PORT=8443
REALITY_INBOUND_SERVER_NAME=apple.com

make build && make images-pull-upstream && make refresh-full
make verify-sni-443
make regression-443
```

### Maturity

| Profile | Score | TG client port | Notes |
|---------|-------|----------------|-------|
| `standalone` | **8.5–8.8** | `:8444` | Sites on nginx `:443` unchanged |
| `sni` | **9.0–9.3** | `:443` | Requires host nginx stream + site migration |

---

## Roadmap

| Stage | Work |
|-------|------|
| 0–4 | Scaffold, preflight, standalone MVP — **done** |
| 5 | `make mtproxy-export`, healthcheck, `clients_mtproxy/` — **done** |
| 6 | `MTPROXY_MODE=sni`, loopback xray, `verify-sni-443`, nginx example — **done** |
| 7+ | Optional: `preflight` nginx map lint, automated certbot DNS-01 docs per site |

---

## Anti-patterns

- Do not bind `vpn-teleproxy` on `0.0.0.0:443` while nginx serves sites (`standalone` uses 8444).
- Do not fork Teleproxy into `containers/`.
- Do not use `:latest` without a deliberate pin bump workflow.
- Do not `docker restart vpn-teleproxy` alone — use `make refresh-full`.
- Do not put nginx in compose.

→ [All documentation](./README.md)
