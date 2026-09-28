# Port 443 on IN — phases 0–6

**Last updated:** 2026-09-02

**Goal:** IN server can run a **website on :443** while this repo controls only AWG + internal Xray. Other users may still use **VLESS on :443** (or any port) via `.env`.

---

## Phase 0 — decisions (●○○○)

| Step | Action |
|------|--------|
| 0.1 | **Website on IN :443** — managed **outside** this repo (nginx/caddy, not compose). |
| 0.2 | **AWG clients** — UDP `AWG_PORT` only; never need host :443. |
| 0.3 | **VLESS on IN** — optional; controlled by `.env` (see below). |
| 0.4 | **OUT exit** — stays `OUT_REALITY_PORT=443` on the **OUT server** (separate host). |

### `.env` knobs

| Variable | Default | Meaning |
|----------|---------|---------|
| `ENABLE_XRAY_INBOUND` | `1` | `0` = no public VLESS on IN (free :443). `1` = publish inbound. |
| `XRAY_INBOUND_PORT` | `443` | TCP port for direct VLESS clients on IN (use `8443` if :443 is the website). |
| `OUT_REALITY_PORT` | `443` | OUT server REALITY port (AWG → SOCKS → exit). |

**Website + AWG-only (recommended):**

```bash
ENABLE_XRAY_INBOUND=0
```

**Website + VLESS on another port:**

```bash
ENABLE_XRAY_INBOUND=1
XRAY_INBOUND_PORT=8443
```

**Classic (VLESS on :443, no website on IN):**

```bash
ENABLE_XRAY_INBOUND=1
XRAY_INBOUND_PORT=443
```

After any change: **`make refresh-full`**.

---

## Phase 1 — prove :443 is not blocked (●○○○)

Minimal smoke before editing prod (full nginx/TLS can wait).

```bash
cd ~/vpn-test
make down
ss -tlnp | grep ':443' || echo "443 free"

# optional: hold :443 with a stub (root required)
sudo python3 -m http.server 443 --bind 0.0.0.0 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:443/
sudo kill %1
```

**Pass:** something other than `vpn-xray` can bind :443 after `make down`.

---

## Phase 2 — build without host :443 (●●●○)

Implemented in repo:

1. `render-config.sh` reads `ENABLE_XRAY_INBOUND`, `XRAY_INBOUND_PORT`, `OUT_REALITY_PORT`.
2. `apply-xray-inbound.py` — drops or keeps VLESS inbound in `config.json`.
3. `apply-compose-xray-ports.sh` — adds `0.0.0.0:PORT:PORT/tcp` only when inbound enabled.
4. `make check` phase 7 — checks `XRAY_INBOUND_PORT` if enabled; if disabled, **FAIL** only when `vpn-xray` still holds :443.

### Deploy steps

```bash
# 1. set .env
grep ENABLE_XRAY_INBOUND .data/.env   # set to 0 for website on :443

# 2. regenerate
make build
make build-diff    # optional: review

# 3. apply
make recreate
make start

# 4. verify
ss -tlnp | grep 443          # must NOT show docker-proxy for xray when inbound=0
make check
make ps                      # 3 containers healthy
# AWG client smoke test
```

**Pass criteria:**

- `ENABLE_XRAY_INBOUND=0` → no `0.0.0.0:443` in build compose; no vless inbound in `config.json`.
- AWG traffic still exits via OUT (`OUT_REALITY_PORT`, default 443).
- `make check` OK; phase 7 OK with website on :443 or port free.

---

## Phase 3 — preflight & docs (●●○○)

**Done in repo:**

| Item | Where |
|------|--------|
| Phase 7 port logic | `ENABLE_XRAY_INBOUND=0` → OK if :443 is website; FAIL if `vpn-xray` binds :443 |
| Phase 8 `.env` groups | `REALITY_*` skipped when inbound disabled |
| Phase 8 `inbound-sync` | `.env` vs `config.json` + **xray** compose ports only (`vpn-teleproxy` :8444 ignored) |
| `make verify-inbound` | `scripts/maintenance/verify-inbound-config.sh` |
| FAQ / DEPLOYMENT / CHECK | cross-links to this doc |

**Operator checklist after phase 2:**

```bash
make verify-inbound
make check 8
make check 7
```

---

## Phase 4 — isolation (●●●○)

**Principle:** this repo owns **only** `.data/` + Docker project `vpn`. Everything else on the host is independent.

| Asset | Owner | This repo touches? |
|-------|--------|-------------------|
| Website :443 | nginx/caddy on host (`/etc/nginx`, `/var/www`) | **No** |
| TLS certs | `/etc/letsencrypt/` or caddy | **No** |
| VPN secrets | `.data/.env`, `.data/build/` | **Yes** |
| AWG route | `vpn-stack-boot.sh` / `make route` | **Yes** (route only) |
| Cloud SG | operator | **No** (open UDP `AWG_PORT`; TCP 443 → site, not xray) |

**Safe workflow:**

```bash
# VPN update — does not restart nginx
cd ~/vpn-test
git pull
make refresh-full

# Website update — does not touch .data/
sudo systemctl reload nginx
```

**Do not:** put nginx in this compose file; do not store site TLS in `.data/`.

---

## Phase 5 — regression (●●●○)

Automated slice:

```bash
make regression-443
```

Runs `make verify-inbound` + `make check` phases **7–9**.

**Manual matrix** (after `ENABLE_XRAY_INBOUND=0` + website on :443):

| Check | Command | Pass |
|-------|---------|------|
| Config sync | `make verify-inbound` | OK, inbound disabled |
| Preflight | `make check` | no FAIL on tcp/443 |
| Stack | `make ps` | 3 containers healthy |
| Route | `make route-status` | `10.8.0.0/24 via …` |
| AWG | client ping `10.8.0.1`, browse web | exit IP = OUT |
| Website | `curl -I https://your-domain/` | 200, parallel with VPN up |

**If AWG works but site fails:** nginx issue — unrelated to render.  
**If site works but AWG fails:** `make check 9`, OUT `OUT_*` in `.env`.

---

## MTProxy on :8444 (optional — `ENABLE_MTPROXY=1`)

When Telegram MTProxy is enabled in **`standalone`** mode, host **:443** stays with nginx; MTProxy publishes **`0.0.0.0:8444→container:443`**. See [MTPROXY.md](./MTPROXY.md).

| Variable | Website + MTProxy (MVP) |
|----------|-------------------------|
| `ENABLE_XRAY_INBOUND` | `0` |
| `ENABLE_MTPROXY` | `1` |
| `MTPROXY_MODE` | `standalone` |
| `MTPROXY_HOST_PORT` | `8444` |

After change: **`make build && make images-pull-upstream && make refresh-full`**.

**Regression gate:**

```bash
make regression-443    # verify-inbound + verify-mtproxy-smoke + check phases 7–11
```

| Check | Command | Pass |
|-------|---------|------|
| Xray inbound | `make verify-inbound` | OK, inbound disabled (MTProxy :8444 not checked here) |
| MTProxy sync | `make verify-mtproxy` | OK, publish `0.0.0.0:8444` |
| Host :443 | `ss -tlnp \| grep ':443'` | nginx, **not** `vpn-teleproxy` |
| MTProxy port | `ss -tlnp \| grep ':8444'` | `vpn-teleproxy` / docker-proxy |
| Stack | `make ps` | 3 or 4 containers healthy |

**Mutex:** `vpn-teleproxy` must **never** bind `0.0.0.0:443` while nginx serves sites in `standalone` mode.

### Prod 9+ — single `:443` (SNI profile)

When sites and Telegram share public **`:443`**, use **`MTPROXY_MODE=sni`**: nginx **stream** SNI router → sites on `127.0.0.1:8080`, MTProxy on `127.0.0.1:8444`. TG link uses **`port=443`**.

**Runbook:** [SNI-CUTOVER.md](./SNI-CUTOVER.md)  
**Config:** `config/examples/nginx-stream-443.example-host.conf.example` (example-host)

| Variable | SNI profile |
|----------|-------------|
| `MTPROXY_MODE` | `sni` |
| `MTPROXY_SNI` | e.g. `google.com` (must match EE secret / ClientHello) |
| `MTPROXY_PUBLISH` | `127.0.0.1` (forced) |
| `MTPROXY_EXTERNAL_PORT` | `443` |

Requires **certbot DNS-01** before cutover. Validate: `make verify-sni-443`, `make regression-443`.

---

## Phase 6 — prod rollout & rollback (●●●●)

### Staging (`~/vpn-test`)

```bash
cd ~/vpn-test
# 1. set .env
sed -i 's/^ENABLE_XRAY_INBOUND=.*/ENABLE_XRAY_INBOUND=0/' .data/.env

# 2. apply
make build && make build-diff
make recreate && make start

# 3. gate
make regression-443
ss -tlnp | grep 443    # nginx/site, NOT docker-proxy+xray
```

### Production

1. Maintenance window or low traffic.
2. Site on :443 **already up** (phase 1) or brief VPN `make down`.
3. Edit prod `.data/.env` → `ENABLE_XRAY_INBOUND=0`.
4. `make refresh-full`.
5. `make regression-443` + one AWG client smoke test.
6. Monitor 24 h: site uptime + AWG clients.

### Rollback (restore VLESS on :443)

```bash
# in .data/.env
ENABLE_XRAY_INBOUND=1
XRAY_INBOUND_PORT=443

make refresh-full
make verify-inbound
```

**Note:** rollback **conflicts** with website on :443 — stop site or use `XRAY_INBOUND_PORT=8443` instead.

### Rollback (build only)

```bash
ls -dt .data/build-snapshots/pre-build-* | head -1
# restore files from backup, then:
make recreate && make start
```

→ [All documentation](./README.md)
