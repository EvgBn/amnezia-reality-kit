# Telegram group voice — runbook

**Last updated:** 2026-09-02

Telegram group voice (VoIP) uses **IPv4 UDP** through NFQUEUE → **udp-relay** (Go) → shared SOCKS UDP associate → **xray** → REALITY OUT. TCP chat can work while voice hangs on **Connecting…** if the SOCKS associate is stale (`relay first inject=0`).

Technical path and zombie-associate behavior: [IPT2SOCKS.md § udp-relay](./IPT2SOCKS.md#udp-relay-go).

---

## Prerequisites

- Repo root on the **IN** host (`<REPO_ROOT>` or your clone).
- Test phone connected to AWG VPN (note client IP, e.g. `10.8.0.9`).
- For live gate: join a **group voice call** on the test phone before starting the watch window.

```bash
cd <REPO_ROOT>
```

---

## Runbook (in order)

| Step | Command | When |
|------|---------|------|
| 1 | `make diagnose-udp-path` | Static L0–L4 only — **no phone call** |
| 2 | `make voice-gate WATCH=30` | Live gate — pick client + call state, 30s probe |
| 3 | `make voice-path-probe` | After FAIL — MODE-A/B verdict (read-only) |
| 4 | `make voice-fail-snapshot` | Forensics **before** `refresh-full` (tcpdump, associate state) |
| 5 | `make refresh-full` | Stale associate, git pull, `.env`/image change |

```bash
# Automation (no prompts):
NONINTERACTIVE=1 SMOKE_CLIENT_IP=10.8.0.9 make voice-gate WATCH=30
```

---

## Step 2 — voice gate

```bash
make voice-gate WATCH=30
```

**Call state prompt:** choose **[1]** when you already hear audio in the call. The gate checks relay path metrics, not Telegram UI text.

**What PASS means:** NFQUEUE + udp-relay + SOCKS path metrics look healthy (`relay first inject` > 0, byte counters moving). It does **not** guarantee Telegram left **Connecting…** — STUN can pass with `inject=1` while media is not up. Speak during the watch window; if UI still hangs after PASS, check OUT-side return path or retest with active speech.

**What FAIL often shows:**

| Metric | Meaning |
|--------|---------|
| `relay first inject=0` | Return path broken — stale or desynced SOCKS UDP associate |
| `one-way warns>0` | Outbound OK, inbound inject missing |
| FWD-drop > 0 (L2b) | Stale TPROXY/REPLY rules — `make refresh-full` |

---

## Step 3 — path probe (after FAIL)

```bash
make voice-path-probe
# optional: PROBE_WINDOW=300 make voice-path-probe
```

Read-only classification (MODE-A vs MODE-B). Use output to decide whether the break is container-local or OUT-side before recreating the stack.

---

## Step 4 — fail snapshot (before refresh)

```bash
make voice-fail-snapshot
# optional OUT host: make voice-fail-snapshot OUT=user@out.example
```

Captures tcpdump, associate state, and relay logs. Run **before** `make refresh-full` destroys in-container state.

---

## Step 5 — fix: full stack refresh

```bash
make refresh-full
make voice-gate WATCH=30   # retest
```

**Never** `dc restart` / `--force-recreate` on **amneziawg** or **xray** alone — desyncs the shared SOCKS UDP associate (`inject=0`, Connecting…). Exception: **coredns** alone is safe (`dc restart coredns`).

| Service | Restart alone? | Use instead |
|---------|----------------|-------------|
| **amneziawg** | **No** | `make refresh-full` |
| **xray** | **No** | `make refresh-full` |
| **coredns** | Yes | `dc restart coredns` |

After git pull, `.env`, or image rebuild, always prefer **`make refresh-full`** over bare `dc restart`.

---

## Symptom quick reference

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Voice gate FAIL, FWD-drop > 0 | stale TPROXY/REPLY rules | `make refresh-full`; check `make voice-gate` L2b |
| Voice gate PASS, UI still Connecting… | STUN without sustained media; gate is path-only | call state [1]; speak during watch; OUT tcpdump if inject=1 |
| Telegram voice Connecting…, inject=0 | partial container restart (xray ↔ udp-relay desync) | `make refresh-full` |
| Worked, then failed after ~5 min idle | xray closed SOCKS control TCP; old binary without reconnect | rebuild image + `make refresh-full` (see [IPT2SOCKS § zombie associate](./IPT2SOCKS.md#udp-relay-go)) |
| Stale container after git pull | old image or stale associate | `make refresh-full` |

---

## Shell helper

For manual `dc exec` / `dc logs` during investigation, from repo root:

```bash
dc() { docker compose -f .data/build/docker-compose.yml --env-file .data/.env "$@"; }
```

Full convention: [OPERATIONS.md § Convention](./OPERATIONS.md#convention-repo-root).

→ [All documentation](./README.md)
