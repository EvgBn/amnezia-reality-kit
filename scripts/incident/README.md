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

## Environment

| Variable | Default |
|----------|---------|
| `INCIDENT_OUT_DIR` | `~/log/snapshots` |
| `OUT_DIR` | same as `INCIDENT_OUT_DIR` (alias) |
| `OUT` | `${INCIDENT_OUT_DIR}/incident-<timestamp>.log` |
| `CLIENT_IP` | `10.8.0.7` |
| `LOG_SINCE` | `45m` |

UDP / ipt2socks grep patterns: `scripts/lib/incident-udp-log-patterns.sh` (shared with `make voice-fail-snapshot`).

## When to use

1. **`make incident-snapshot`** — broad bundle (host uplink, docker health, WG peer, NFQUEUE, udp-relay signals, `diagnose-udp-path`).
2. **`make voice-fail-snapshot`** — deeper UDP capture (tcpdump timeline) before `make refresh-full`.

See `docs/OPERATIONS.md` (incident snapshot) and `docs/VOICE.md`.
