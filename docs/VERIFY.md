# Verify targets (`make verify-*`)

**Last updated:** 2026-09-05

← [Index](./README.md) · [Troubleshooting](./TROUBLESHOOTING.md)

Config-level checks (`.env` ↔ `.data/build/`) and optional live smoke.  
**Read-only** — no mutations. Requires `make create-data` and usually `make build`.

---

## Target map

| Make target | Script | What it checks | Needs stack up? |
|-------------|--------|----------------|-----------------|
| `make verify-inbound` | `scripts/maintenance/verify-inbound-config.sh` | `ENABLE_XRAY_INBOUND`, `XRAY_INBOUND_PORT`, VLESS in `config.json`, xray compose publish (loopback when `MTPROXY_MODE=sni`) | No |
| `make verify-mtproxy` | `scripts/maintenance/verify-mtproxy-config.sh` | `ENABLE_MTPROXY`, `MTPROXY_MODE`, host/container ports, teleproxy compose block | No |
| `make verify-mtproxy-smoke` | `scripts/maintenance/verify-mtproxy-smoke.sh` | TG link export, TCP to published port, stats, SNI lint/probe in `sni` mode | **Yes** |
| `make verify-sni-443` | `scripts/maintenance/verify-sni-443.sh` | Required `.env` keys for SNI profile; nginx map lint + TLS probe via `mtproxy-sni.sh` | Partial (lint works offline; probes need nginx :443) |
| `make regression-443` | *(orchestrator)* | All four `verify-*` above + **`make check` phases 7–11** | Smoke + phases 10–11 need stack |

Canonical port policy: [PORT-443.md](./PORT-443.md). MTProxy: [MTPROXY.md](./MTPROXY.md). SNI: [SNI-9-PLUS.md](./SNI-9-PLUS.md).

---

## `make regression-443`

Runs in order:

```text
verify-inbound
verify-mtproxy
verify-mtproxy-smoke
verify-sni-443
preflight/run.sh --phases 7-11
```

**When to run:** after changing `ENABLE_XRAY_INBOUND`, `XRAY_INBOUND_PORT`, `MTPROXY_*`, `MTPROXY_MODE`, or nginx SNI map — before declaring prod ready.

**Manual follow-up** (printed by Makefile): AWG client ping/curl; if website on :443 — `curl https://your-domain/`.

---

## Relation to `make check`

| Verify target | Overlapping check phase | Difference |
|---------------|-------------------------|------------|
| `verify-inbound` | **Phase 8** (`inbound-sync`) | Verify is standalone, explicit exit; phase 8 is one probe among many |
| `verify-mtproxy` | **Phase 8** (`mtproxy-sync`), **11** (ports) | Verify = compose parity only; phase 11 adds container health, smoke, nginx |
| `verify-mtproxy-smoke` | **Phase 11** (`mtproxy-smoke`) | Same smoke lib; verify target for ad-hoc use / regression bundle |
| `verify-sni-443` | **Phase 11** (`nginx-sni-map`, `nginx-sni-tls`) | Skipped when `MTPROXY_MODE≠sni`; phase 11 skips whole MTProxy block when disabled |
| `regression-443` | **Phases 7–11** | Config verify + network/runtime/OUT/MTProxy audit |

| Phase | Scope | Typical verify overlap |
|-------|-------|------------------------|
| 7 | XRAY inbound port on host, AWG UDP, route | Indirect (live ports vs `verify-inbound` static files) |
| 8 | `.env` keys, build artifacts, inbound-sync, mtproxy-sync | **`verify-inbound`**, **`verify-mtproxy`** |
| 9 | `vpn-*` healthy (xray, amneziawg, coredns) | — |
| 10 | OUT ping + SOCKS egress | — |
| 11 | teleproxy, smoke, nginx SNI | **`verify-mtproxy-smoke`**, **`verify-sni-443`** |

Full phase reference: [CHECK.md](./CHECK.md).

---

## Examples

```bash
# After editing .env inbound flags
make build && make verify-inbound && make refresh-full

# MTProxy standalone — config only
make verify-mtproxy

# MTProxy — full path (stack must be up)
make verify-mtproxy-smoke

# SNI profile gate (skipped if MTPROXY_MODE=standalone)
make verify-sni-443

# Port / SNI regression bundle
make regression-443
```

---

## Implementation notes

- SNI lint/TLS: `scripts/lib/mtproxy-sni.sh` (shared by phase 11, smoke, `verify-sni-443`).
- Override nginx snippet: `NGINX_STREAM_SNIPPET=/path/to/map.conf`.
- `verify-inbound` / `verify-mtproxy` use embedded Python for compose/json parity.

→ [All documentation](./README.md)
