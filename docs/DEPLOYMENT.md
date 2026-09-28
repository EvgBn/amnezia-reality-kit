# Deployment Guide (Makefile)

**Last updated:** 2026-09-03

**Operator one-pager:** [QUICKSTART.md](./QUICKSTART.md). This doc is the full reference (migrate, teardown, MTProxy, troubleshooting).

Step-by-step deployment using **`make` targets**. Live secrets and build output live in `.data/` (gitignored).

---

## Prerequisites

- Ubuntu 24.04+
- Docker Engine + Compose plugin (install: `sudo ./scripts/setup/install-docker.sh`)
- User in the `docker` group, or root/sudo for Docker
- Ports **443/tcp** (only if `ENABLE_XRAY_INBOUND=1` in `.env`) and **AWG UDP** (default `58285`) free — see [PORT-443.md](./PORT-443.md) if :443 is used by a website
- Only **one** stack at a time (`vpn-xray`, `vpn-amneziawg`, `vpn-coredns`, network `vpn`)

**IPv6:** Docker bridge must use **ULA** (`DOCKER_NETWORK_SUBNET_IPV6`, default `fd87:172:20::/64`), not `2001:db8::/32` (RFC 3849). OUT exit needs a real **GUA** in `OUT_EXIT`, e.g. `OUT_EXIT='6; 2a10:1fc0:c::5375:710f'`. See [ARCHITECTURE.md](./ARCHITECTURE.md#docker-network-vpn) and `.env.example`.

**Docker bridge IPv4:** set **one** variable `DOCKER_NETWORK_SUBNET_IPV4` (default `10.200.97.0/24` — intentionally outside the usual `172.17–172.31` ladder). `make build` derives gateway and container IPs (`.2` CoreDNS, `.3` AWG, `.4` Xray). Do **not** add `COREDNS_IP` / `AMNEZIAWG_IP` / `XRAY_IP` unless you pin a custom address. On shared hosts, pick any free `/24` — `make network-plan` shows the resolved plan; `make check` phase 8 fails early on pool overlap.

---

## Choose your path

| | **Path A — New server** | **Path B — Migrate** |
|---|-------------------------|----------------------|
| When | Fresh VPS, no prior stack | Replacing an old install on the same host |
| Host bootstrap | `sudo make deploy-host` (required) | `sudo make deploy-host` if not done yet |
| Data | `make create-data` (new `.env`, new AWG keys) | **Same clients:** `rsync` old `.data/` → Option A. **New AWG keys:** `create-data COPY_FROM=…` → Option B |
| Stop old stack | skip | `make down` in old repo first |

**Order rule:** on a new machine, always **`sudo make deploy-host` before `make create-data`**.  
`make create-data` only creates `.data/` with **new** server secrets — it does not install the kernel module, firewall, or boot unit, and does not start containers.

---

## Path A — New server

### 1. Clone

```bash
git clone git@github.com-amnezia-kit:EvgBn/amnezia-reality-kit.git ~/vpn-test
cd ~/vpn-test
```

Local mirror:

```bash
git clone ~/amnezia-reality-kit ~/vpn-test
cd ~/vpn-test
```

### 2. Install Docker (if needed)

```bash
sudo ./scripts/setup/install-docker.sh
# re-login or: newgrp docker
```

### 3. Host bootstrap (once per machine)

```bash
sudo make deploy-host
```

Installs: L0 host prep (forward, conntrack, firewall), L2 boot autoboot (`vpn-stack-boot.service`, wrapper, `/etc/vpn-bridge/env`), L1 AmneziaWG kmod when enabled.

Optional deploy-time flags (independent):

```bash
sudo ENABLE_STACK_AUTOBOOT=0 make deploy-host   # no boot unit — use make start after reboot
sudo ENABLE_AWG_KMOD_HOST=0 make deploy-host  # no kmod install — L2 still on by default
```

**Portable clone path:** `vpn-stack-boot.service` always calls the stable wrapper `/usr/local/sbin/vpn-stack-ensure`; it reads `REPO_ROOT` from `/etc/vpn-bridge/env` at boot. After moving the repo, run `sudo make deploy-host` from the new location (updates env + unit migration; no baked clone path in systemd).

Verify host only (no `.data/` required yet):

```bash
make check-host    # phases 1–5 — fix FAIL before continuing
```

### 4. Create operator data (`.data/`)

Creates `.data/.env` with **new** server secrets, `.data/build/` (via `build --bootstrap`, zero peers OK):

```bash
make create-data
```

Without `COPY_FROM`, fill **OUT_*** REALITY exit fields in `.data/.env` before clients can reach the internet.

**Keygen images:** `make create-data` auto-detects any local `amneziawg:*` image; if none exist, it builds a minimal keygen image once. Override with `AWG_IMAGE=…` only when needed.

### 5. Unit tests (optional — contributors / CI only)

```bash
make unit-test          # unit + guards + integration + go (make test = alias)
make unit-test-shell    # fast: tests/unit + tests/guards
```

### 6. First deploy

```bash
make first-start    # validate → build → images → start (up + host route)
```

`make start` = `make up` + `make route`. Prefer it over bare `make up`.

> **`make up` alone does not add the host route** — you will see WARN in `make check` until you run `make start` or `make route`. See [FAQ.md](./FAQ.md).

Verify:

```bash
make ps
make route-status
make check         # all 9 phases
```

All three containers should be **healthy**: `vpn-xray`, `vpn-amneziawg`, `vpn-coredns`.

### 7. Add a client

```bash
make awg-client-add NAME=phone
make awg-client-list
```

Client configs: `.data/clients_awg/<name>.conf` — transfer to the device and open in AmneziaWG.

### 8. Connect and verify

Connect VPN on the phone, then:

```bash
make check
```

---

## Path B — Migrate from an old stack

### 1. Stop the old stack

From the **old** repo directory:

```bash
cd ~/old-vpn-dir
make down
make ps    # no vpn-* containers
```

`make route-remove` is optional — `host-remove` clears the route if you tear down the host later.

### 2. Clone (or pull) the new repo

```bash
git clone git@github.com-amnezia-kit:EvgBn/amnezia-reality-kit.git ~/vpn-test
cd ~/vpn-test
```

### 3. Host bootstrap (if not done on this machine)

```bash
sudo make deploy-host
make check-host
```

Skip if this host already ran `deploy-host` for the same machine.

### 4. Bring over `.data/` (pick one path)

Path B splits here. **Do not** run `create-data COPY_FROM` and then `rsync` the old `.data/` on top — you only need one of the options below.

| Goal | What to run |
|------|-------------|
| **Same phones** — keep existing `.conf` files, server pubkey, peers | **Option A** (skip `create-data`) |
| **New AWG identity** — new server keys; phones need new `.conf` | **Option B** (`create-data COPY_FROM`) |

#### Option A — Same AWG clients (recommended on same IN host)

Copy the **entire** working `.data/` from the old repo (`.env`, `build/`, `clients_awg/`, peers in `awg0.conf`). No `create-data`.

```bash
cd ~/vpn-test
rsync -a ~/old-vpn-dir/.data/ ./.data/
make build
make first-start    # or make refresh-full if stack was up before
make check
```

Phones keep working; no `awg-client-add` unless you add new devices.

#### Option B — New server secrets, OUT + network from old `.env`

Use when the old `.data/` is lost but you still have a good `.env`, or you **want** to rotate AWG/SOCKS/inbound keys and re-issue client configs.

```bash
cd ~/vpn-test
make create-data COPY_FROM=~/old-vpn-dir/.data/.env
make first-start
```

`COPY_FROM` copies **OUT REALITY**, docker/iptables topology, and tuple endpoints (`IN_INGRESS`, `OUT_EXIT`, …) from the source `.env`. It does **not** copy `AWG_SERVER_*`, `SOCKS_PASSWORD`, inbound REALITY keys, `[Peer]` blocks, or `clients_awg/`.

Then add clients and distribute new configs:

```bash
make awg-client-add NAME=phone
make awg-client-list
```

Transfer `.data/clients_awg/<name>.conf` to each device.

#### If you already ran Option B but need Option A

You ran `create-data COPY_FROM` and phones stopped connecting — either **replace** `.data/` with Option A `rsync`, or minimally restore from the old tree: same `AWG_SERVER_PRIVATE_KEY` / `AWG_SERVER_PUBLIC_KEY` / `SOCKS_PASSWORD` in `.env`, copy `build/awg0.conf` (with `[Peer]` blocks) and `clients_awg/`, then `make build && make refresh-full`.

---

## Host route and boot (not a separate systemd unit)

| Mechanism | Role |
|-----------|------|
| `make route` / `make route-remove` | Runtime host route for AWG subnet (`scripts/maintenance/vpn-awg-route.sh`) |
| `make start` | `make up` + `make route` — daily start |
| `vpn-stack-boot.service` | Boot unit installed by `deploy-host` |
| `/usr/local/sbin/vpn-stack-ensure` | Stable systemd ExecStart; reads `REPO_ROOT` from `/etc/vpn-bridge/env` |
| `vpn-stack-boot.sh` | Called by wrapper at boot: load kmod → compose stack → `vpn-awg-route.sh apply` |

After `make down` / Docker network recreate, the bridge name changes (`br-…`) — run **`make start`** (not bare `make up`).

---

## Preflight (`make check`)

Read-only audit — never mutates the system. See [CHECK.md](./CHECK.md).

```bash
make check-host    # phases 1–5: host + Docker
make check         # all 9 phases (stack + .data/ if present)
make check-deploy  # phases 6–9 only
```

Exit `0` = no blocking FAIL (WARN may remain). Exit `1` = fix FAIL lines first.

Verbose:

```bash
./scripts/preflight/run.sh --host -v
```

---

## Daily operations

**Start stack** (containers + host route):

```bash
make start
```

**Stop stack:**

```bash
make down
```

**After `git pull`, `git checkout`, `make images`, or `.env` edit** — full stack refresh:

```bash
make refresh-full    # down → build → images → recreate → start
```

**Do not** rely on `docker restart vpn-amneziawg` or `docker restart vpn-xray` alone after code or image changes — Telegram voice UDP can break (`inject=0`). See [FAQ.md § After git checkout](./FAQ.md#after-git-checkout-or-git-pull).

**Rebuild after `.env` changes:** same as above — `make refresh-full` even if `make build` prints `no changes`.

---

## AWG client management

```bash
make awg-client-list
make awg-client-add NAME=<name>
make awg-client-remove NAME=<name>
# or: make awg-client-remove NUM=<#>   # row from list
# or: make awg-client-remove           # interactive (TTY)
```

---

## REALITY SNI / mask (`.data/.env`)

| Variable | Role | Bootstrap default |
|----------|------|-------------------|
| `REALITY_DEST` | Inbound REALITY `dest` (`host:443`) | `cloudflare.com:443` |
| `REALITY_INBOUND_SERVER_NAME` | Inbound `serverNames[0]` | `apple.com` |
| `OUT_REALITY_SERVER_NAME` | Outbound exit `serverName` (AWG via SOCKS) | `dl.google.com` |

After edits: `make refresh-full`.

---

## MTProxy SNI cutover (prod 9+)

When moving from **standalone** (`:8444`) to **sni** (TG on public `:443` with nginx stream):

1. Read **[SNI-CUTOVER.md](./SNI-CUTOVER.md)** — host-specific runbook (inventory, DNS-01, nginx, rollback).
2. Use `config/examples/nginx-stream-443.conf.example` or host copy (e.g. `nginx-stream-443.example-host.conf.example`).
3. Set `MTPROXY_MODE=sni`, `MTPROXY_SNI=<EE domain in secret>`, `make refresh-full`.
4. Verify: `make verify-sni-443`, `make regression-443`, `make check 11`.

**Do not** cut over without DNS-01 cert renewal — HTTP-01 on `:443` fails behind stream.

---

## Stack stop policy (`.stack-stopped`)

| Command | Containers now | After reboot |
|---------|----------------|--------------|
| `make start` | up + route | up (clears `.data/.stack-stopped`) |
| `make down` | down | down (writes `.stack-stopped`) |
| `make up` | up | unchanged (does not clear flag) |

Boot always loads the AmneziaWG kernel module; compose orchestration is skipped while `.stack-stopped` exists.

Strict CI gate: `CHECK_STRICT=1 make check` or `make check --strict` (WARN → FAIL).

---

## Makefile reference

| Target | Purpose |
|--------|---------|
| `sudo make deploy-host` | **Host bootstrap** — kmod, firewall, boot unit (once per machine, **before `make create-data`**) |
| `make create-data [COPY_FROM=…]` | Create `.data/` with new secrets + `build --bootstrap` |
| `make build` | Write `.data/build/` from templates + `.env` (do not edit `build/` by hand) |
| `make build-diff` | Preview build changes without writing |
| `make images` | Build Docker images (amneziawg, coredns, ipt2socks) |
| `make unit-test` | Full test suite: `tests/unit`, `tests/guards`, `tests/integration`, Go udp-relay (`make test` = alias) |
| `make unit-test-shell` | Fast shell tests only (`tests/unit` + `tests/guards`) |
| `make first-start` | `validate` → `build` → `images` → `start` |
| **`make start`** | **Clear `.stack-stopped` + `up` + `route` — daily stack start** |
| **`make refresh-full`** | **`down` → `build` → `images` → `recreate` → `start`** |
| `make up` / `make down` / `make ps` / `make logs` | Stack control (`down` persists stop across reboot) |
| `make route` / `make route-remove` / `make route-status` | Host AWG subnet route (runtime script) |
| `make check` / `make check-host` / `make check-deploy` | Preflight phases 1–11 / 1–5 / 6–11 (`CHECK_STRICT=1` for CI) |
| **`make remove-full`** | **`down` → remove `vpn` network → `host-remove` (keeps `.data/`)** |
| `sudo make host-remove` | Host teardown only — stack must be stopped first |
| `sudo make kmod-remove` | Unload AmneziaWG kmod only (subset of host-remove) |
| `make network-plan` | Show derived docker bridge IPs from `.data/.env` (read-only) |
| `make help` | Full target list |

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `make create-data` before `deploy-host` on new VPS | Run `sudo make deploy-host` first, then `make check-host` |
| `make create-data` — AWG image not found | Docker + network; auto-builds keygen image, or `AWG_IMAGE=…` |
| `DNS_PROBE_*` on client | `make ps` — `vpn-coredns` must be **healthy**; [OPERATIONS.md](./OPERATIONS.md) |
| `make down` / `docker` permission denied | Add user to `docker` group or use sudo |
| Port already in use | [PORT-443.md](./PORT-443.md) |
| Ping `10.8.0.1` OK, sites fail | OUT REALITY in `.env` — use `COPY_FROM` from working prod |
| After git pull / `.env` edit | **`make refresh-full`** |
| After `make down` then start again | **`make start`** (not bare `make up`) |
| Telegram voice Connecting…, inject=0 | **`make refresh-full`** |
| `docker compose up` — **Pool overlaps** / network `vpn` fails | Another project uses the same RFC1918 range. In `.data/.env`: set `DOCKER_NETWORK_SUBNET_IPV4` to a free `/24` (default `10.200.97.0/24`; any unused range works). **Delete** lines `COREDNS_IP=`, `AMNEZIAWG_IP=`, `XRAY_IP=`, `DOCKER_NETWORK_GATEWAY_IPV4=` if present — they override SSOT. Then `make network-plan` → `make build` → `sudo make deploy-host` → `make refresh-full` |

See also: [ARCHITECTURE.md](./ARCHITECTURE.md), [OPERATIONS.md](./OPERATIONS.md), [SECURITY.md](./SECURITY.md).

---

## Host teardown

Remove host-level VPN artifacts (optional — decommissioning a test VM or before moving repo path).

**Full cycle** (stack + host; keeps `.data/`):

```bash
make remove-full
```

Order: `make down` → remove Docker network `vpn` (if leftover) → `sudo make host-remove`.

**Manual steps** (same result):

```bash
make down
sudo make host-remove
```

`host-remove` also removes the AWG host route; `make route-remove` is optional beforehand.

**Partial** — kernel module and boot unit only:

```bash
sudo make kmod-remove
```

**Not removed:** Docker images, `.data/` (secrets, clients, build output). Delete data manually only if intended: `rm -rf .data`. `net.ipv4.ip_forward` in `/etc/sysctl.conf` is left unchanged. Live conntrack sysctl values persist until reboot.

**Redeploy after teardown:**

```bash
sudo make deploy-host
make refresh-full    # or make create-data if .data/ was wiped
```

→ [All documentation](./README.md)
