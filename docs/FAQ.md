# FAQ

**Last updated:** 2026-09-02

---

## AWG keys deleted (or clients won't connect)

**Symptom:** AmneziaWG client hangs / no handshake; `make check` may still show **51 OK**.

**Short answer:** Restore `.data/.env` from backup, find the server **private** key whose `awg pubkey` matches `[Peer] PublicKey` in client `.conf`, update `.env` + **`make refresh-full`**, then verify runtime pubkey equals client pubkey.

**Do not assume** `AWG_SERVER_*` in `.env` matches client exports — verify cryptographically (`awg pubkey` vs `[Peer] PublicKey`).

Full incident write-up, failed vs correct rollback steps, and search script: **[KEYS-RECOVERY.md](./KEYS-RECOVERY.md)**.

Quick verify after any key restore:

```bash
echo "runtime: $(docker exec vpn-amneziawg awg show awg0 public-key)"
echo "client:  $(grep '^PublicKey' .data/clients_awg/evg.conf | awk '{print $3}')"
```

Both lines must be identical.

---

## Does every `make build` create a backup?

**No — not every run.**

`make build` calls `scripts/setup/render-config.sh`. A backup is created **only when** build actually **rewrites** `.data/build/`.

### When backup is **not** created

1. **Output unchanged** — `awg0.conf`, ipt2socks scripts, `docker-compose.yml`, and `config.json` match what is already in `build/`:

   ```text
   [render-config] no changes — production files unchanged
   ```

   The script exits **before** the backup step.

2. **`make build-diff` / `--dry-run`** — diff or validation only; nothing is written to `build/`, no backup.

3. **`--no-backup`** — backup disabled explicitly (not recommended on prod).

### When backup **is** created

When build **does** change `build/` (and `--no-backup` was not passed):

| Item | Detail |
|------|--------|
| **Path** | `.data/build-snapshots/pre-build-YYYYMMDD-HHMMSS/` |
| **Contents** | **Current** files from `build/` copied **before** overwrite: `awg0.conf`, `config.json`, `ipt2socks-*.sh`, `ipt2socks-ports.env`, `docker-compose.yml` |
| **Log** | `[render-config] backup: …/` |

### What build does **not** backup

- **`.data/.env`** — only `build/` artifacts
- **`clients_awg/`** — use separate backups (see [OPERATIONS.md § Backup](./OPERATIONS.md))

### Why old `pre-build-*` folders matter

If `build/awg0.conf` has no `[Peer]` blocks, build reuses peers from the **latest** `pre-build-*` snapshot.

**Summary:** backup on every invoke — **no**; only when build output **change**, unless dry-run / `--no-backup`. Repeated `make build` with an unchanged `.env` usually prints `no changes` and adds no new backup directory.

---

## I ran `make up` — why does `make check` WARN about the route?

After `make up`, check may look like this:

```text
── Phase 7: Network ──
[WARN] ROUTE    10.8.0.0/24                  no host route  → make start

── Phase 9: Stack runtime ──
[WARN] STACK    route-bridge                 no route for 10.8.0.0/24  → make start

=== Summary ===
OK: 38  WARN: 2  FAIL: 0  SKIP: 0

No blocking FAIL — address WARN before declaring prod-ready.
  Typical fix: make start
```

**This is expected if you used `make up` instead of `make start`.**

| Target | What it does |
|--------|----------------|
| `make up` | Containers only (compose `up -d`) |
| **`make start`** | **`make up` + `make route`** — use this for daily start |
| `make first-start` | First deploy: `validate` → `build` → `images` → **`start`** |

`make up` does **not** add the host route `10.8.0.0/24 via 172.20.0.3`. AWG clients over UDP `:58285` often still work; the host route is for diagnostics and ops (see [ARCHITECTURE.md](./ARCHITECTURE.md)).

### What to run instead

**Option 1 — full path (fresh clone, first time):**

```bash
make first-start
```

**Option 2 — images built and `.data/` ready (normal daily start):**

```bash
make start
```

**Option 3 — you already ran `make up`:**

```bash
make route             # add route only
# or
make start             # idempotent: up + route
make check             # All checks passed
```

### Cheat sheet

| Goal | Command |
|------|---------|
| **Start stack (recommended)** | **`make start`** |
| Containers only (advanced) | `make up` |
| Host route only | `make route` |
| Full first deploy from scratch | `make first-start` |
| Preflight audit | `make check` |

### Route after bridge recreate

`vpn-stack-boot.service` applies the host AWG route at boot. After Docker network recreate (not a normal `make down`), the bridge name changes (`br-…`) and the old route is gone. Use **`make start`** (or `make route` if containers are already up).

### `make down` and reboot

`make down` stops containers **and** writes `.data/.stack-stopped`. After reboot the boot unit loads the kernel module but **does not** run `compose up` until **`make start`**. Bare `make up` starts containers for this session only; use `make start` when you want the stack up across reboots.

See also: [DEPLOYMENT.md §5](./DEPLOYMENT.md), [CHECK.md Phase 7/9](./CHECK.md).

---

## After git checkout or git pull

**Always redeploy the full stack:**

```bash
make refresh-full
```

| Short cut | Risk |
|-----------|------|
| `make start` only | Old containers keep running; new image/config not applied |
| `docker restart vpn-amneziawg` | xray still holds old SOCKS UDP state → voice Connecting…, `inject=0` |
| `docker restart vpn-xray` alone | Same if amneziawg was not recreated with it |

**Symptom:** Telegram group voice hangs on Connecting…; `make voice-gate` shows `relay first inject=0`, `one-way warns=1`, while TCP chat still works.

**Fix:** `make refresh-full` (not git rollback — runtime state was stale, not necessarily code). Voice runbook: [VOICE.md](./VOICE.md).

Details: [DEPLOYMENT.md §2](./DEPLOYMENT.md#2-clone-the-repository).

---

## After `make down`, does `make check` still pass?

If `.data/` exists but no `vpn-*` containers are running, Phase 9 shows:

```text
[WARN] STACK    stack                        stopped (no vpn-* containers)  → make start

=== Summary ===
OK: 35  WARN: 1  FAIL: 0  SKIP: 1

Stack stopped — host/data OK.  Start: make start
```

Exit code stays **0** (host and data are fine), but the message is **not** “all checks passed — stack running”. That only appears when containers are up and healthy.

| Situation | Meaning |
|-----------|---------|
| After `make down` | Host + `.data/` OK; stack intentionally stopped |
| Clients should work again | **`make start`** |

---

## I need :443 for a website on the same IN server

Set in `.data/.env`:

```bash
ENABLE_XRAY_INBOUND=0
```

Then **`make refresh-full`**. The repo will not publish TCP :443; AWG and IN→OUT exit still work. Direct VLESS clients on IN need `ENABLE_XRAY_INBOUND=1` and `XRAY_INBOUND_PORT=8443` (or another port). See [PORT-443.md](./PORT-443.md).

→ [All documentation](./README.md)
