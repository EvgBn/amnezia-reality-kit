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

## Continuous metrics (trigger time-series)

```bash
make incident-metrics-tick
# Cron example (every minute):
# */1 * * * * /home/evg/pub/amnezia-reality-kit/scripts/incident/metrics-tick.sh
```

CSV: `~/log/metrics/YYYY-MM-DD.csv` — use with snapshot for RCA (conn/FD/swap before peak).

## Environment

| Variable | Default |
|----------|---------|
| `INCIDENT_OUT_DIR` | `~/log/snapshots` |
| `OUT_DIR` | same as `INCIDENT_OUT_DIR` (alias) |
| `INCIDENT_METRICS_DIR` | `~/log/metrics` |
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
| AWG / NFQUEUE | canonical `iptables -x` counters |
| coredns ipt2socks | DoT path errors (separate from awg) |
| diagnose-udp-path | L0–L4; warn if L2 nfq disagrees with canonical |
| **verdict** | Machine-readable `IN_UPLINK`, `SOCKS_EGRESS`, `TRIGGER`, RST evidence flag |

Trust **canonical_nfqueue_pkts** over diagnose L2 when they disagree (human-readable vs `-x` counters).

## When to use

1. **`make incident-snapshot`** — broad bundle while symptoms are visible.
2. **`make incident-metrics-tick`** — background CSV (cron).
3. **`make voice-fail-snapshot`** — deeper UDP capture (tcpdump) before `make refresh-full`.

See `docs/OPERATIONS.md` (incident snapshot) and `docs/VOICE.md`.
