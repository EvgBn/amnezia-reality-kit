# Incident forensics (IN host)

Operator scripts for capturing VPN stack state during outages. **Log files are not committed** — default output is `~/log/snapshots/`.

## Quick start

```bash
cd ~/pub/amnezia-reality-kit
make incident-snapshot

# Another AWG client:
CLIENT_IP=10.8.0.9 make incident-snapshot
```

Legacy wrapper (same script):

```bash
~/log/collect-incident-snapshot.sh
```

## Runbook (RCA)

1. **While users see symptoms** — `make incident-snapshot` (do not `make recreate` first).
2. **Telegram hang / voice / UDP** — also `make voice-fail-snapshot` before refresh.
3. **Background** — cron `metrics-tick` every **2 minutes** (see below).
4. After the incident — `make incident-channel-report` (or `DATE=YYYY-MM-DD`) for a markdown timeline draft.
5. Copy off-box: `~/log/snapshots/`, `~/log/metrics/`, `~/log/events/`.
6. Note in the ticket: time (UTC), **AWG on/off**, MTProxy on/off, what failed (DNS / all sites / TG only).

Snapshots include the **last ~30 rows** of today’s metrics CSV (v2) so one file has **slice + ~1h history** at 2m cron.

## Continuous metrics (channel matrix + events)

```bash
make incident-metrics-tick

# Cron (every 2 minutes — recommended on IN):
# */2 * * * * /home/evg/pub/amnezia-reality-kit/scripts/incident/metrics-tick.sh
```

| Output | Purpose |
|--------|---------|
| `~/log/metrics/YYYY-MM-DD.csv` | CSV **v2** — probes CH0–CH7 + **deltas** (nfqueue, peer transfer, inject/P2P in last ~2.5m) |
| `~/log/metrics/.tick-state` | Previous cumulative counters (do not delete) |
| `~/log/events/YYYY-MM-DD.jsonl` | `channel_degraded` / `channel_recovered` with `primary` (CH3–CH5) and optional `correlation` |

Daily RCA report:

```bash
make incident-channel-report
OUT=~/log/reports/rca-$(date -u +%Y-%m-%d).md make incident-channel-report
```

## Channel IDs (canonical → event vs snapshot)

Single rule engine: `incident_primary_from_signals` in `scripts/lib/incident-channel-lib.sh`.
Tick (`metrics-tick`) and snapshot (`verdict v2`) differ only in **inputs** and **label formatter**.

| Code | Meaning | `events.jsonl` `primary` | Snapshot `PRIMARY=` |
|------|---------|--------------------------|---------------------|
| CH0 | IN host uplink | — (snapshot only) | `CH0_IN_UPLINK` |
| CH6 | OUT REALITY TCP | — (snapshot only) | `CH6_OUT_REALITY_TCP` |
| CH5 | Shared SOCKS egress | `CH5` | `CH5_SHARED_SOCKS_EGRESS` |
| CH4 | DNS / DoT path | `CH4` | `CH4_DNS_DOT_PATH` or `CH4_DNS_DOT_CHRONIC_RST` |
| CH3 | AWG UDP relay | `CH3` | `CH3_UDP_RELAY_DEGRADED` |
| — | Client TCP stall | — | `CLIENT_TCP_STALL` |
| — | No path failure in snapshot | — | `NO_SERVER_PATH_FAILURE_IN_SNAPSHOT` |

Snapshot also prints `PRIMARY_CODE=CH3` (canonical) beside verbose `PRIMARY=`.

**Tick signals:** `socks_ok=0` → CH5; cold DNS &gt; `INCIDENT_TICK_COLD_DNS_MS_MAX` or `coredns_streak` ≥ `INCIDENT_TICK_COREDNS_STREAK_MIN` → CH4; inject/one-way deltas → CH3. **Cron tick does not classify CH0/CH6** (no host uplink / OUT-TCP verdict in the 2m probe); use `make incident-snapshot` for those channels. CSV columns `out_icmp_ok` / `out_tcp443_ok` are recorded for correlation only.

**Snapshot signals:** `INC_VERDICT_*` (set by `collect-snapshot.sh` before `incident_verdict_v2_compute`) — same priority order as tick.

`correlation=p2p_udp_storm` / `p2p_udp_heavy_window` — time correlation with `:6881`, not root cause.

### Source order (metrics tick)

`paths.sh` → `incident-udp-log-patterns.sh` → `incident-snapshot-lib.sh` → `incident-channel-lib.sh` → `incident-metrics-collect-lib.sh`. Collect-lib calls `incident_metrics_collect_prereq` (patterns + snapshot + channel). Markdown: `incident-channel-report-lib.sh` → channel-lib (CSV quick stats by header names).

### Lib global contracts (set per call, not exported API)

| Prefix | Set by | Consumed by | Notes |
|--------|--------|-------------|--------|
| `INC_SIG_*` | Caller before `incident_primary_from_signals` | `incident-channel-lib.sh` | Cleared inside the function after copy to locals |
| `INC_PRIMARY_*` | `incident_primary_from_signals` | Events / snapshot label | Cleared by `incident_primary_clear_outputs` after eval |
| `INC_METRICS_*` | `incident_metrics_tick_collect` | `metrics-tick.sh` | Cleared by `incident_metrics_collect_clear` after CSV append |
| `INC_VERDICT_*` | `collect-snapshot.sh` | `incident_verdict_v2_compute` | Snapshot-only inputs (see table below) |

**`INC_SIG_*` (tick mode):** `INC_SIG_MODE=tick`, `INC_SIG_SOCKS_OK`, `INC_SIG_COLD_MS`, `INC_SIG_STREAK`, `INC_SIG_INJECT_DELTA`, `INC_SIG_P2P_DELTA`, `INC_SIG_ONE_WAY_DELTA`.

**`INC_SIG_*` (snapshot mode):** `INC_SIG_MODE=snapshot`, `INC_SIG_HOST`, `INC_SIG_OUT_ICMP`, `INC_SIG_OUT_TCP`, `INC_SIG_SOCKS`, `INC_SIG_DNS_LOCAL`, `INC_SIG_UDP_RELAY`, `INC_SIG_INJECT_N`, `INC_SIG_P2P_N`, `INC_SIG_IPT2SOCKS_TO`, `INC_SIG_RST_COREDNS`.

**`INC_PRIMARY_*` (outputs):** `INC_PRIMARY_CODE` (canonical CH0–CH6 / `NO_FAILURE` / `CLIENT_TCP_STALL`), `INC_PRIMARY_CORRELATION`, `INC_PRIMARY_SUBTYPE` (`dns_path`, `dns_rst_chronic`).

**`INC_METRICS_*` (outputs):** `INC_METRICS_ROW` (full CSV v2 line), `INC_METRICS_TS`, `INC_METRICS_SOCKS_OK`, `INC_METRICS_COLD_INT`, `INC_METRICS_STREAK`, `INC_METRICS_INJECT_D`, `INC_METRICS_P2P_D`, `INC_METRICS_ONE_WAY_D`, `INC_METRICS_NFQ_NOW`, `INC_METRICS_PEER_RX_NOW`, `INC_METRICS_PEER_TX_NOW`, `INC_METRICS_MT_NOW`.

| `INC_VERDICT_*` | Meaning |
|-----------------|--------|
| `INC_VERDICT_HOST` | IN uplink (`ok` / `fail`) |
| `INC_VERDICT_OUT_ICMP` | OUT ICMP from xray netns |
| `INC_VERDICT_OUT_TCP` | OUT TCP probe |
| `INC_VERDICT_SOCKS` | SOCKS curl (`ok` / `timeout` / `fail`) |
| `INC_VERDICT_DNS_LOCAL` | Cold dig on CoreDNS |
| `INC_VERDICT_DNS_CLIENT` | AWG → CoreDNS dig (informational) |
| `INC_VERDICT_UDP_RELAY` | UDP relay health |
| `INC_VERDICT_INJECT_FAIL_N` | inject failures in `LOG_SINCE` |
| `INC_VERDICT_P2P_N` | `:6881` lines in `LOG_SINCE` |
| `INC_VERDICT_IPT2SOCKS_CLIENT_TO` | ipt2socks client timeouts in window |
| `INC_VERDICT_RST_COREDNS` | CoreDNS ipt2socks RST count |

Install cron on IN host:

```bash
./scripts/incident/install-metrics-cron.sh
```

## Environment

| Variable | Default |
|----------|---------|
| `INCIDENT_OUT_DIR` | `~/log/snapshots` |
| `OUT_DIR` | same as `INCIDENT_OUT_DIR` (alias) |
| `INCIDENT_METRICS_DIR` | `~/log/metrics` |
| `INCIDENT_EVENTS_DIR` | `~/log/events` |
| `INCIDENT_LOG_DELTA_SINCE` | `150s` (log counters per tick; match ~2m cron) |
| `INCIDENT_TICK_MAX_GAP_SEC` | `600` (ignore `.tick-state` after longer pause → zero cumulative deltas) |
| `INCIDENT_METRICS_TAIL_LINES` | `30` (embedded in snapshot) |
| `OUT` | `${INCIDENT_OUT_DIR}/incident-<timestamp>.log` |
| `CLIENT_IP` | `10.8.0.7` |
| `LOG_SINCE` | `45m` |

UDP / ipt2socks grep patterns: `scripts/lib/incident-udp-log-patterns.sh` (shared with `make voice-fail-snapshot`).

## Snapshot sections (audit-oriented)

| Block | Purpose |
|-------|---------|
| meta + container clocks | UTC/local; correlate xray access timestamps |
| host | IN uplink + swap |
| health | Docker health + FailingStreak |
| **egress matrix** | OUT ICMP, OUT TCP probe, SOCKS curl + timings, expected egress IP |
| **DNS depth** | cached/cold dig, client dig @ CoreDNS, coredns timestamped errors |
| **load signals** | SOCKS conn, FD, teleproxy accept burst, :6881 heuristic |
| **channel matrix tail** | Last N rows of metrics CSV v2 |
| AWG / NFQUEUE | canonical `iptables -x` counters |
| coredns ipt2socks | DoT path errors (separate from awg) |
| diagnose-udp-path | L0–L4; warn if L2 nfq disagrees with canonical |
| **verdict** | `IN_UPLINK`, `SOCKS_EGRESS`, `TRIGGER`, RST evidence — **v1 = load/egress trigger heuristic** (legacy block in snapshot) |
| **verdict v2** | `PRIMARY`, `PRIMARY_CODE`, `CORRELATION` — **v2 = channel RCA draft** (`incident_primary_from_signals`) |

Trust **canonical_nfqueue_pkts** over diagnose L2 when they disagree (human-readable vs `-x` counters).

## When to use

1. **`make incident-snapshot`** — broad bundle while symptoms are visible.
2. **`make incident-metrics-tick`** — background CSV + events (cron).
3. **`make incident-channel-report`** — markdown merge CSV + events for a day.
4. **`make voice-fail-snapshot`** — deeper UDP capture (tcpdump) before `make refresh-full`.

See `docs/OPERATIONS.md` (incident snapshot) and `docs/VOICE.md`.
