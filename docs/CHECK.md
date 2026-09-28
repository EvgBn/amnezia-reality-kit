# Preflight checks (`make check`)

**Last updated:** 2026-09-05

Read-only audit before `make create-data` / `make first-start` / future `make deploy`.  
Implements **P0** of the Makefile host-bootstrap roadmap.

See also: [VERIFY.md](./VERIFY.md) (`make verify-*`).

---

## Purpose

On a **new machine**, failures are often host-level (no Docker, no AWG module, no conntrack, stale route) while the operator only runs `make first-start`.  
`make check` runs grouped probes and prints **OK / WARN / FAIL** with the **next command** to fix each gap.

Exit code:

| Code | Meaning |
|------|---------|
| `0` | No blocking FAIL (WARN allowed) |
| `1` | At least one FAIL — do not treat stack as production-ready |

---

## Architecture: module layout

Implementation lives under **`scripts/preflight/`** (not a monolith in `deployment/`).

```text
scripts/preflight/
├── run.sh                 # orchestrator (CLI, phase selection)
├── README.md
├── lib/
│   ├── emit.sh            # OK/WARN/FAIL output, summary
│   ├── env.sh             # .env groups (OUT_*, REALITY_*, core)
│   ├── registry.sh        # host units, stack containers, build files
│   ├── probes.sh          # docker, ports, systemd (primitives)
│   ├── network.sh         # phase 7 helpers
│   ├── stack.sh           # phase 9 helpers
│   ├── mtproxy.sh         # phase 11 helpers
│   └── out.sh             # phase 10 helpers
└── phases/
    ├── 01-repo.sh … 05-host-sysctl.sh
    ├── 06-host-svc.sh     # Phase 6: HOST SVC
    ├── 07-network.sh      # Phase 7: NETWORK
    ├── 08-data.sh         # Phase 8: DATA
    ├── 09-stack.sh        # Phase 9: STACK (core vpn-* only)
    ├── 10-out.sh          # Phase 10: OUT path
    └── 11-mtproxy.sh      # Phase 11: MTProxy (optional)
```

`scripts/deployment/check.sh` is a thin wrapper: `exec …/preflight/run.sh`.

## Check phases

Checks run in **dependency order** (host → tooling → data → runtime).

```text
Phase 1  REPO      ── scripts, templates present in clone
Phase 2  OS        ── Ubuntu version, swap for image builds
Phase 3  DOCKER    ── engine, compose plugin, socket access, group
Phase 4  KERNEL    ── AmneziaWG module (awg0 in container)
Phase 5  HOST SYS  ── ip_forward, conntrack drop-ins
Phase 6  HOST SVC  ── vpn-host-firewall, vpn-stack-boot (boot route via vpn-stack-boot.sh)
Phase 7  NETWORK   ── XRAY inbound port / :443 policy, UDP AWG_PORT, route (if stack up)
Phase 8  DATA       ── .data/.env, build/*, inbound-sync (.env vs build)
Phase 9  STACK      ── core vpn-* healthy (xray, awg, coredns), route ↔ bridge
Phase 10 OUT        ── OUT_EXIT ping (WARN), SOCKS egress vs OUT_EXPECTED_EGRESS
Phase 11 MTPROXY   ── optional Telegram ingress (skipped when ENABLE_MTPROXY=0)
```

| Scope | Phases | Make target |
|-------|--------|-------------|
| Host bootstrap | 1–5 | `make check-host` / `--host` |
| Deploy readiness | 6–11 | `make check-deploy` / `--deploy` |
| Full audit | 1–11 | `make check` |
| MTProxy only | 11 | `make check 11` |

Each line is independent; the script **never mutates** the system.

---

## Phase details

### Phase 1 — Repository

| Probe | FAIL if | Fix |
|-------|---------|-----|
| `scripts/preflight/run.sh` | missing | broken clone |
| `scripts/clients/awg/add.sh` | missing | `git pull`; ensure `scripts/clients/` tracked |
| `config/templates/awg0.conf.tmpl` | missing | broken clone |

### Phase 2 — OS

| Probe | FAIL/WARN | Fix |
|-------|-----------|-----|
| `/etc/os-release` ID=ubuntu, VERSION_ID ≥ 24.04 | WARN | use supported Ubuntu |
| Swap total ≥ 1 GiB (or RAM ≥ 2 GiB) | WARN | add swap before `make images` |

### Phase 3 — Docker

| Probe | FAIL if | Fix |
|-------|---------|-----|
| `docker` in PATH | missing | `sudo ./scripts/setup/install-docker.sh` (future: `make install-docker`) |
| `docker compose version` | missing | same |
| `docker info` succeeds for current user | no | add user to `docker` group or use sudo wrapper |
| User in group `docker` (when not root) | WARN | `sudo usermod -aG docker $USER` + re-login |

### Phase 4 — Kernel (AmneziaWG)

| Probe | FAIL if | Fix |
|-------|---------|-----|
| `amneziawg` in `/proc/modules` or `modprobe amneziawg` works | no | `sudo make deploy-host` or `sudo ./scripts/maintenance/rebuild-amneziawg.sh` |
| `amneziawg.ko` for `uname -r` | missing | `sudo make deploy-host` after kernel upgrade |
| `vpn-stack-boot.service` enabled, `ExecStart=/usr/local/sbin/vpn-stack-ensure` | stale absolute path / 203 | `sudo make deploy-host` |
| `vpn-stack-boot.sh` executable in clone | missing | verify `REPO_ROOT`; `sudo make deploy-host` |
| `/etc/vpn-bridge/env` `REPO_ROOT` matches clone | mismatch | `sudo make deploy-host` |

Boot path: `vpn-stack-boot.service` → `vpn-stack-ensure` → `vpn-stack-boot.sh` (kernel module + compose stack + `vpn-awg-route.sh apply`).

### Phase 5 — Host sysctl

| Probe | WARN if | Fix |
|-------|---------|-----|
| `net.ipv4.ip_forward = 1` | not 1 | `sudo make deploy-host` |
| `/etc/sysctl.d/99-vpn-conntrack.conf` exists | missing | same |
| `nf_conntrack` loaded | missing | same |

### Phase 6 — Host services (`06-host-svc.sh`)

| Unit | WARN if | Fix |
|------|---------|-----|
| `vpn-host-firewall.service` | not enabled | `sudo make deploy-host` |
| `vpn-stack-boot.service` | not enabled | `sudo make deploy-host` |

### Phase 7 — Network (`07-network.sh` + `lib/network.sh`)

Reads `ENABLE_XRAY_INBOUND`, `XRAY_INBOUND_PORT` from `.data/.env`. See [PORT-443.md](./PORT-443.md). MTProxy ports → **phase 11**.

| Probe | FAIL/WARN | Fix |
|-------|-----------|-----|
| **`ENABLE_XRAY_INBOUND=1`** — TCP `${XRAY_INBOUND_PORT}` held by `vpn-xray` | FAIL if foreign process | free port or change `XRAY_INBOUND_PORT` |
| **`ENABLE_XRAY_INBOUND=0`** — TCP `:443` held by `vpn-xray` | **FAIL** | `ENABLE_XRAY_INBOUND=0`, **`make refresh-full`** |
| **`ENABLE_XRAY_INBOUND=0`** — `:443` held by nginx/other | **OK** (website expected) | — |
| **`ENABLE_XRAY_INBOUND=0`** — `:443` free | **OK** | — |
| UDP `${AWG_PORT:-58285}` — free or held by `vpn-amneziawg` | FAIL if foreign process | stop old stack / change port |
| Route `${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}` via `${AMNEZIAWG_IP:-172.20.0.3}` | WARN if stack up but no route | **`make start`** or `make route` |
| Route check | SKIP if no `vpn-*` running | — |

### Phase 8 — Data layer (`08-data.sh` + `lib/env.sh`)

| Probe | FAIL/WARN | Fix |
|-------|-----------|-----|
| `.data/.env` exists | WARN if missing | `make create-data [COPY_FROM=…]` |
| `OUT_*` keys (5) | FAIL per empty key | edit `.env` or `COPY_FROM` |
| `REALITY_*` keys (4) | FAIL per empty key **if `ENABLE_XRAY_INBOUND=1`** | same |
| `REALITY_*` | OK skipped if `ENABLE_XRAY_INBOUND=0` | — |
| Core keys (AWG, SOCKS, COREDNS, AWG_PORT) | FAIL per empty key | same |
| AWG server pubkey vs client exports | **not checked** | see [KEYS-RECOVERY.md](./KEYS-RECOVERY.md) — run manually after key/restore changes |
| **`DOCKER_NETWORK_SUBNET_IPV4`** vs other Docker networks | **FAIL** if pool overlaps (phase 8) | set a free `/24` in `.env` (default `10.200.97.0/24`); remove explicit `COREDNS_IP` / `AMNEZIAWG_IP` / `XRAY_IP` if any; `make network-plan` → `make build` → `sudo make deploy-host` → `make refresh-full` |
| **`DOCKER_NETWORK_SUBNET_IPV6`** not `2001:db8::/32` | **FAIL** if RFC3849 docs prefix | set ULA in `.env` (e.g. `fd87:172:20::/64`); **`make refresh-full`** |
| **`COREDNS_IPV6`** | FAIL if RFC3849; WARN if empty | pin inside Docker ULA; must match `awg0.conf` DNAT |
| **`OUT_EXIT`** | FAIL if missing/invalid; WARN if `6; 2001:db8::…` placeholder | `OUT_EXIT='4; <ip>'` or `OUT_EXIT='6; <gua>'` |
| **`OUT_EXPECTED_EGRESS`** | WARN if empty (phase 10 SKIP egress) | `OUT_EXPECTED_EGRESS='4; <expected curl IP>'` (real egress, not `.env.example` placeholder) |
| **`IN_INGRESS`** | FAIL if missing | `IN_INGRESS='4; <public-ip>'` |
| `.data/build/*` artifacts | WARN per missing file | `make create-data` or `make build` |
| **`inbound-sync`** | **FAIL** if xray `.env` flags ≠ `config.json` / xray ports in compose | **`make refresh-full`** |

Build artifacts (same set as `render-config.sh`):

- `docker-compose.yml`, `awg0.conf`, `config.json`
- `ipt2socks-amneziawg-v4.sh`, `ipt2socks-amneziawg-v6.sh`, `ipt2socks-coredns.sh`, `udp-relay-run.sh`, `ipt2socks-ports.env`, `Corefile`

| `ipt2socks-*.sh` mode **755** | **FAIL** if not executable | `make build` |

| `amneziawg:${AMNEZIAWG_RELEASE}` image (or `AWG_IMAGE`) | WARN if missing | `make images` or `AWG_IMAGE=… make create-data` |

### Phase 9 — Stack runtime (`09-stack.sh` + `lib/stack.sh`)

| State | Result | Fix |
|-------|--------|-----|
| No `.data/build/` yet | **SKIP** stack | `make create-data && make first-start` |
| Configured, **`make down`** (`.stack-stopped`) | **OK** intentionally stopped | **`make start`** when ready |
| Configured, stopped, **no** `.stack-stopped`, boot enabled | **WARN** (FAIL with `CHECK_STRICT=1`) | **`make down`** to persist, or **`make start`** |
| `vpn-*` running but unhealthy | **FAIL** | `make logs`, **`make refresh-full`** |
| Running + healthy + route OK | **OK** | — |
| Per-container health (when up) | **FAIL** if unhealthy | `make logs`; **`make refresh-full`** (or `dc restart coredns` if DNS-only) |
| Expected containers | **3** core (`vpn-xray`, `vpn-amneziawg`, `vpn-coredns`); **+1** `vpn-teleproxy` when `ENABLE_MTPROXY=1` | `make ps` |
| Route ↔ bridge (when up) | WARN if stale / missing | **`make start`** |

**Summary messages:**

| Situation | Footer (not generic “All checks passed”) |
|-----------|------------------------------------------|
| Stack running, no FAIL/WARN | `All checks passed — stack running.` |
| Stack stopped after `make down` | `Stack stopped — host/data OK. Start: make start` |
| Fresh clone, no `.data/` | `Host OK — not deployed. Next: make create-data && make first-start` |

### Phase 10 — OUT path (`10-out.sh` + `lib/out.sh`)

Runs only when stack is **up** and `vpn-xray` is healthy. ICMP failure **never blocks** the egress probe.

| Probe | Default | `--strict` / `CHECK_STRICT=1` |
|-------|---------|-------------------------------|
| Stack not running | **SKIP** | same |
| **`OUT_EXIT-reach`** (ping/ping6 from `vpn-xray`) | **OK** if replies; **WARN** `not received (icmp)` | **WARN** only (never FAIL) |
| **`OUT egress-match`** (curl `-4` via SOCKS `127.0.0.1:1080` → api.ipify.org) | **SKIP** if `OUT_EXPECTED_EGRESS` empty | same |
| Egress IP matches `OUT_EXPECTED_EGRESS` | **OK** | same |
| Egress mismatch or curl failed | **WARN** | **FAIL** |

Manual equivalent:

```bash
docker exec vpn-xray ping6 -c2 '<OUT_EXIT_ADDRESS>'
curl -sf -4 -x socks5h://127.0.0.1:1080 --proxy-user "$SOCKS_USER:$SOCKS_PASSWORD" https://api.ipify.org
```

### Phase 11 — MTProxy (`11-mtproxy.sh` + `lib/mtproxy.sh`)

Optional Telegram ingress. **Skipped** when `ENABLE_MTPROXY=0` (unless stale `vpn-teleproxy` → WARN). See [MTPROXY.md](./MTPROXY.md).

| Probe | FAIL/WARN | Fix |
|-------|-----------|-----|
| **`ENABLE_MTPROXY=0`** | **SKIP** phase | — |
| **`ENABLE_MTPROXY=0`** + `vpn-teleproxy` running | **WARN** stale | `make refresh-full` |
| **`MTPROXY_*` env** | FAIL per empty key | edit `.env` |
| **`mtproxy-sync`** | FAIL if `.env` ≠ compose | `make build && make refresh-full` |
| **`teleproxy-image`** | WARN if missing | `make images-pull-upstream` |
| **Ports** (`MTPROXY_HOST_PORT`, stats loopback, sni `:443`) | FAIL/WARN per profile | see MTPROXY.md |
| **`nginx-sni-map`** (sni only) | FAIL if required SNI missing in host stream map | edit `/etc/nginx/stream.d/vpn-bridge-443.conf`; [SNI-9-PLUS.md](./SNI-9-PLUS.md) |
| **`nginx-sni-tls`** (sni only) | FAIL if `:443` SNI returns site cert (misroute) | add EE/secret SNIs to map → `127.0.0.1:8444` |
| **`vpn-teleproxy` health** | FAIL if missing/unhealthy | `make refresh-full` |
| **`mtproxy-smoke`** | FAIL if link/TCP/stats/SNI bad; WARN if ufw blocks client port | `make verify-mtproxy-smoke` |

---

## Mapping FAIL → next Makefile step (roadmap)

| Symptom (check output) | Today | Planned target |
|------------------------|-------|----------------|
| Docker missing | `sudo scripts/setup/install-docker.sh` | `make install-docker` |
| No AWG module / sysctl / firewall units | `sudo make deploy-host` | same |
| No AWG host route (stack up) | **`make start`** or `make route` | same |
| No `.data/.env` | `make create-data COPY_FROM=…` | same |
| Stack not up | `make first-start` | `make deploy` |
| Route missing | **`make start`** | part of `make deploy` |

---

## Usage

```bash
cd ~/vpn-test
make check              # all 11 phases
make check 11           # MTProxy only (skipped when ENABLE_MTPROXY=0)
make check 7            # single phase (1–11)
make check 7-11         # phase range
make check-host         # phases 1–5 only (new machine)
make check-deploy       # phases 6–11 (systemd, ports, .env, stack, OUT, MTProxy)
make check-watch        # repeat full check every INTERVAL seconds (default 30)
make check-watch 7 INTERVAL=60   # watch phase 7 only, every 60s
```

Verbose (show passing lines too):

```bash
./scripts/preflight/run.sh 7 -v
./scripts/preflight/run.sh --host -v
./scripts/preflight/run.sh --deploy -v
```

Phase range (script only):

```bash
./scripts/preflight/run.sh --phases 3-5
```

JSON for automation (optional):

```bash
./scripts/preflight/run.sh --json
```

---

## Implementation

| File | Role |
|------|------|
| `scripts/preflight/run.sh` | Orchestrator, CLI, exit code |
| `scripts/preflight/phases/*.sh` | One module per phase |
| `scripts/preflight/lib/*.sh` | Shared emit, env, probes |
| `scripts/deployment/check.sh` | Back-compat wrapper |
| `scripts/preflight/lib/registry.sh` | Units, containers, build file list |
| `scripts/preflight/lib/network.sh` | Phase 7 port/route probes |
| `scripts/preflight/lib/mtproxy.sh` | Phase 11 MTProxy (ports, sync, smoke, container) |
| `scripts/preflight/lib/stack.sh` | Phase 9 health + route↔bridge |
| `scripts/preflight/lib/out.sh` | Phase 10 ping + SOCKS egress |
| `Makefile` | `make check`, `make check-host`, `make check-deploy`, `make check-watch` |
| `docs/CHECK.md` | This document |
| `docs/DEPLOYMENT.md` | Step 0: run check before create-data |

Future P1 targets (`host-bootstrap`, `deploy`) will **reuse the same phase modules** or call `make check` at the start.

---

## FAQ

**WARN `no host route` after `make up`?** → [FAQ.md](./FAQ.md) — use **`make start`** instead of `make up`.

---

## Non-goals (check does not verify)

- Cloud provider firewall / Security Group on OUT
- TLS certificate on OUT (REALITY handshake details)
- AWG client `.conf` export paths / phone smoke test
- ICMP reachability as hard gate (phase 10 ping is WARN-only)

→ [All documentation](./README.md)
