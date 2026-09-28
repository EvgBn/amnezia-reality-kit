# Troubleshooting — symptom matrix

**Last updated:** 2026-09-05

← [Index](./README.md) · [Verify targets](./VERIFY.md)

**First step for any stack issue:** `make check` (or `make check N` for a single phase).  
**After `.env` / port / inbound / MTProxy changes:** `make regression-443` — see [VERIFY.md](./VERIFY.md).

---

## Quick matrix

| Symptom | First check | Doc | Command |
|---------|-------------|-----|---------|
| **Telegram won't connect** (MTProxy / `tg://proxy`) | Phase **11** + SNI map (if `MTPROXY_MODE=sni`) | [SNI-CUTOVER.md](./SNI-CUTOVER.md), [SNI-9-PLUS.md](./SNI-9-PLUS.md) | `make check 11` then `make verify-sni-443` |
| **Telegram voice stuck on Connecting…** | udp-relay inject counter | [VOICE.md](./VOICE.md) | `make voice-gate WATCH=30` → `make refresh-full` if `inject=0` |
| **AWG connects, no Internet** | Route + stack health | [CHECK.md](./CHECK.md) phase 7–9, [FAQ.md](./FAQ.md) | `make check 7-9` → `make start` or `make route` |
| **AWG won't connect at all** | UDP port + module | [DEPLOYMENT.md](./DEPLOYMENT.md), [CHECK.md](./CHECK.md) phase 4–7 | `make check-host` → `sudo make deploy-host` |
| **Website on :443 broken** after VPN change | Xray must not bind :443 when inbound off | [PORT-443.md](./PORT-443.md) | `make verify-inbound` → `make refresh-full` |
| **VLESS clients fail** on IN | Inbound sync | [PORT-443.md](./PORT-443.md) | `make verify-inbound` → `make check 8` |
| **`make check` FAIL inbound-sync** | `.env` ≠ `config.json` / compose | [CHECK.md](./CHECK.md) phase 8 | `make refresh-full` |
| **`make check` FAIL mtproxy-sync** | `.env` ≠ teleproxy ports in compose | [MTPROXY.md](./MTPROXY.md) | `make verify-mtproxy` → `make build && make refresh-full` |
| **OUT egress wrong IP** | SOCKS path | [OUT.md](./OUT.md), [CHECK.md](./CHECK.md) phase 10 | `make check 10` · `CHECK_STRICT=1 make check 10` |
| **DNS leak / wrong resolver** | CoreDNS + awg0 DNAT | [SECURITY.md](./SECURITY.md), [ARCHITECTURE.md](./ARCHITECTURE.md) | `make check 9` · `dc exec coredns dig @127.0.0.1` |
| **After git pull / image update** | Partial restart desync | [FAQ.md](./FAQ.md), [VOICE.md](./VOICE.md) | **`make refresh-full`** (not single-container restart) |
| **Keys / client pubkey mismatch** | Manual recovery | [KEYS-RECOVERY.md](./KEYS-RECOVERY.md) | compare `awg pubkey` vs client export |

---

## Telegram MTProxy (detail)

| Symptom | Likely cause | Command chain |
|---------|--------------|-----------------|
| Link opens, no connection (`standalone`) | Port blocked, teleproxy down, smoke fail | `make verify-mtproxy` → `make verify-mtproxy-smoke` |
| Link on `:443`, TLS error (`sni`) | SNI maps to site backend, not `127.0.0.1:8444` | `make check 11` (`nginx-sni-map`, `nginx-sni-tls`) |
| `ENABLE_MTPROXY=0` but container running | Stale stack | `make check 11` (WARN) → `make refresh-full` |

Canonical SNI invariants: [SNI-9-PLUS.md](./SNI-9-PLUS.md). Host nginx steps: [SNI-CUTOVER.md](./SNI-CUTOVER.md).

---

## Voice / UDP (detail)

| Metric / symptom | Meaning | Fix |
|------------------|---------|-----|
| `relay first inject=0` | Stale SOCKS UDP associate (often after `docker restart` one container) | `make refresh-full` |
| Gate PASS, UI still Connecting… | Path OK, media not up or OUT return issue | Speak during watch; [VOICE.md](./VOICE.md) step 3–4 |
| Chat works, voice fails | UDP path only | `make diagnose-udp-path` |

**Note:** MTProxy does **not** carry voice (TCP only) — [MTPROXY.md § Telegram calls](./MTPROXY.md#telegram-calls--not-supported).

---

## Strict mode

```bash
CHECK_STRICT=1 make check      # WARN → FAIL (staging / CI)
CHECK_STRICT=1 make check 10   # egress mismatch → FAIL
```

---

## Escalation order

```text
make check [N]     → read FAIL line + fix hint
make verify-*      → config drift (see VERIFY.md)
make regression-443 → after port/SNI/inbound edits
make refresh-full  → image/config/deploy sync (full stack)
```

→ [All documentation](./README.md)
