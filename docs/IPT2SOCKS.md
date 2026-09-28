# ipt2socks + udp-relay transparent proxy

**Last updated:** 2026-09-02

Transparent TCP + UDP exit in container netns:

- **TCP:** `iptables`/`ip6tables` REDIRECT → **ipt2socks** `-T` (v1.1.4) → Xray SOCKS `:1080` → REALITY OUT.
- **UDP (non-DNS, IPv4):** `iptables` NFQUEUE → **udp-relay** (Go, in amneziawg image) → same SOCKS path → REALITY OUT.

## Why ipt2socks (TCP only in amneziawg)

- IPv4 + IPv6 TCP REDIRECT (`-R -4 -T` / `-R -6 -T`) in one binary.
- Container-integrated via supervisord (no sidecar netns hacks).

UDP exit uses a separate **udp-relay** binary (NFQUEUE userspace relay with shared SOCKS UDP associate). IPv6 UDP is not relayed yet (FORWARD DROP anti-leak). We do **not** use `ipt2socks -U` — it has no NFQUEUE inject return path.

## udp-relay (Go)

Binary: `/usr/local/bin/udp-relay` in **amneziawg** (built from this repo; Go not required on host).

**Source layout:** `containers/amneziawg/cmd/udp-relay/` — NFQUEUE entrypoint (`main`, inject); `containers/amneziawg/internal/udprelay/` — relay logic (SOCKS5, sessions, reconnect).

**What it does (per packet):**

1. **NFQUEUE** — read client IPv4/UDP (VoIP, STUN, QUIC, etc.; not DNS `:53`)
2. **Parse** — src/dst IP, ports, payload
3. **SOCKS5** — one shared UDP ASSOCIATE to xray `:1080` (all AWG clients)
4. **Outbound** — send payload to xray via SOCKS UDP
5. **Read loop** — wait for replies on the same associate
6. **Inject** — build IPv4/UDP reply and deliver back to the client via AWG
7. **Reconnect** — if xray closes the SOCKS control TCP (`connIdle`, ~5 min idle), dial a fresh associate (see below)

**Zombie associate (why reconnect matters):** SOCKS UDP ASSOCIATE has a TCP control leg and a UDP relay leg. xray closes TCP on idle; without watching that socket, udp-relay kept a dead UDP socket — outbound looked OK, **inject stayed 0**, Telegram voice hung on Connecting…. Reconnect swaps the associate and resets sessions. Logs: `socks tcp control eof`, `associate reconnected`. Regression tests: `containers/amneziawg/tests/udprelay/zombie_associate_test.go`.

## UDP note

Client DNS (UDP/TCP `:53`) uses **DNAT → CoreDNS**, not ipt2socks. CoreDNS upstream is **DoT TCP :853** → ipt2socks in coredns.

Non-DNS IPv4 UDP (VoIP, STUN, QUIC, etc.) uses **NFQUEUE → udp-relay → SOCKS → REALITY OUT**. QUIC is **not blocked** in Phase 1; monitor volume in Phase 2 and decide policy from metrics.

### Exit path (AWG client → OUT)

```
Phone (AWG client)
    │
    ▼
amneziawg (172.20.0.3)
    │
    ├─ TCP: ipt2socks ──SOCKS5 TCP──► 172.20.0.4:1080
    │
    └─ UDP: udp-relay ──SOCKS5 UDP associate──► 172.20.0.4:1080
                                              │
                                              ▼
                                         vpn-xray (xray)
                                              │
                                              ▼ REALITY outbound
                                         OUT server
```

IPs are defaults from `.env` (`AMNEZIAWG_IP`, `XRAY_IP`). DNS (:53) uses **coredns** instead — see [ARCHITECTURE.md § Traffic Flows](./ARCHITECTURE.md#traffic-flows).

## Images

```bash
make images-ipt2socks   # tags zfl9/ipt2socks:latest from GitHub release v1.1.4
make images             # builds amneziawg (includes udp-relay via multi-stage Go build)
```

Container Dockerfiles `COPY --from=zfl9/ipt2socks:latest`. udp-relay is compiled in `containers/amneziawg/Dockerfile` (Go not required on host).

## Build artifacts (`.data/build/`)

| File | Role |
|------|------|
| `ipt2socks-amneziawg-v4.sh` | AWG TCP v4 listener `:12345` on tunnel gateway (REDIRECT) |
| `ipt2socks-amneziawg-v6.sh` | AWG TCP v6 listener `:12346` (REDIRECT) |
| `udp-relay-run.sh` | NFQUEUE → `/usr/local/bin/udp-relay` → SOCKS |
| `ipt2socks-coredns.sh` | DoT `:853` → `:12347` + ipt2socks |
| `ipt2socks-ports.env` | Healthcheck port / NFQUEUE constants |

`make build` removes obsolete TPROXY build artifacts if present.

## `.env` keys

| Key | Default |
|-----|---------|
| `AWG_IPT2SOCKS_PORT` | `12345` |
| `AWG_IPT2SOCKS_PORT_IPV6` | `12346` |
| `AWG_NFQUEUE_NUM` | `100` |
| `AWG_UDP_RELAY_LOG_LEVEL` | `info` |
| `AWG_UDP_RELAY_PORT` | `12348` |
| `AWG_UDP_RELAY_PORT_IPV6` | `12349` |
| `COREDNS_IPT2SOCKS_PORT` | `12347` |
| `AWG_TUNNEL_SUBNET_IPV6` | `fd86:ea04:1115::/64` |
| `IPT2SOCKS_THREADS` | `2` |
| `IPT2SOCKS_NOFILE_LIMIT` | `8192` |
| `IPT2SOCKS_UDP_TIMEOUT` | `60` (udp-relay session timeout) |

## Deploy

```bash
make images
make refresh-full
make check
```

Voice gate and troubleshooting: **[VOICE.md](./VOICE.md)**.

Client E2E: `curl -4`, `curl -6`, `dig @10.8.0.1 A` / `AAAA`.

## Healthcheck (amneziawg)

- 2× `ipt2socks` processes (tcp v4/v6)
- 1× `udp-relay` process (NFQUEUE UDP exit)
- iptables REDIRECT (TCP) + mangle NFQUEUE (UDP v4)
- FORWARD udp !:53 DROP (anti-leak)

## Tuning & monitoring

Under heavy parallel HTTPS, watch file descriptors and active SOCKS connections (`dc` from [OPERATIONS.md § Convention](./OPERATIONS.md#convention-repo-root)):

```bash
# amneziawg — two ipt2socks processes (v4 + v6) + udp-relay
dc exec amneziawg sh -c \
  'for p in $(pgrep -x ipt2socks); do echo "ipt2socks pid=$p fd=$(ls -1 /proc/$p/fd 2>/dev/null | wc -l)"; done; \
   p=$(pgrep -f /usr/local/bin/udp-relay); echo "udp-relay pid=$p"'

# coredns — one ipt2socks for DoT upstream
dc exec coredns sh -c \
  'p=$(pgrep -x ipt2socks); echo "pid=$p fd=$(ls -1 /proc/$p/fd 2>/dev/null | wc -l)"'
```

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Client Recv-Q high, sites hang | FD / connection pressure | Raise `IPT2SOCKS_NOFILE_LIMIT`, check ulimits in compose |
| `FAIL: ipt2socks` in healthcheck | supervisord crash, bad mount | `dc logs amneziawg`; `make refresh-full` |
| `FAIL: udp-relay` in healthcheck | old image without Go binary | `make refresh-full` |
| Voice / UDP issues | see runbook | [VOICE.md](./VOICE.md) |
| Stale container after git pull / checkout | Old image or stale SOCKS UDP associate | `make refresh-full` |

Compose ulimits (`IPT2SOCKS_NOFILE_LIMIT` / hard 16384) apply to both containers.

## Upstream

| Project | Role |
|---------|------|
| [zfl9/ipt2socks](https://github.com/zfl9/ipt2socks) v1.1.4 | Transparent **TCP** → SOCKS5 (`-T` only; no `-U` in this stack) |
| `containers/amneziawg/cmd/udp-relay` | Binary entry: NFQUEUE + inject |
| `containers/amneziawg/internal/udprelay` | UDP relay library: SOCKS5, sessions, reconnect |

→ [All documentation](./README.md)
