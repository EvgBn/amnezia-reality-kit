# VPN Server — Operations Guide

**Last updated:** 2026-09-02

**Operator daily commands:** [QUICKSTART.md](./QUICKSTART.md#daily-operations). This doc is deep monitoring, tuning, and backup.

## Convention (repo root)

There is **no** `docker-compose.yml` in the repo root. The Docker stack lives under `.data/build/` (from `make build`).

```bash
cd <REPO_ROOT>

# Prefer Makefile wrappers:
make ps
make logs
make refresh-full

# Raw compose (exec, logs with filters):
dc() { docker compose -f .data/build/docker-compose.yml --env-file .data/.env "$@"; }
```

All `dc …` examples below use this helper.

---

## Daily Monitoring

### Quick Health Check

```bash
cd <REPO_ROOT>

# All containers should be "healthy"
make ps

# Check ipt2socks FD monitoring (critical for stability; see IPT2SOCKS.md tuning section)
dc exec amneziawg sh -c '
  echo "=== FD Usage ==="
  for p in $(pgrep -x ipt2socks); do
    cat /proc/$p/limits | grep "open files"
    echo "pid=$p fd=$(ls -1 /proc/$p/fd 2>/dev/null | wc -l)"
  done
  echo
  echo "=== Active SOCKS connections ==="
  ss -tn | grep 172.20.0.4:1080 | wc -l
'

# Check for errors in logs (last hour)
dc logs --since 1h | grep -iE "error|warn|failed" | grep -v "level=info"
```

**Expected output:**

```
FD Usage:
Max open files            8192                 8192                 files
<100

Active SOCKS connections:
<50
```

---

## Monitoring Commands

### ipt2socks Health

```bash
cd <REPO_ROOT>

# FD usage (target: <2000/8192, alert >6000)
dc exec amneziawg sh -c 'for p in $(pgrep -x ipt2socks); do echo "pid=$p fd=$(ls -1 /proc/$p/fd 2>/dev/null | wc -l)"; done'

# Active SOCKS flows to Xray (alert >400 under sustained load)
dc exec amneziawg ss -tn | grep 172.20.0.4:1080 | wc -l

# Client Recv-Q (target: 0-10, alert >50)
dc exec amneziawg ss -tn src 10.8.0.0/24

# Listen queue depth
dc exec amneziawg ss -ltn | grep 12345

# Check for stale connections
dc exec amneziawg ss -tn state close-wait | grep 172.20.0.4:1080

# Exhaustion warnings (should be 0)
dc logs amneziawg --since 1h | grep -iE "EMFILE|accept.*failed|nofile"
```

---

### Xray Health

```bash
cd <REPO_ROOT>

# EOF/reset errors (target: 0/hour)
dc logs xray --since 1h | grep -iE 'EOF|closed|reset' | wc -l

# SOCKS authentication failures
dc logs xray --since 1h | grep "rejected" | wc -l

# REALITY connection status
dc logs xray --since 10m | grep -E "accepted|socks-in|exit"

# Test SOCKS from host (replace password from .env)
curl -4 -I -x socks5h://127.0.0.1:1080 --proxy-user "vpn-user:<SOCKS_PASSWORD>" https://google.com

# Check exit IP
curl -4 -x socks5h://127.0.0.1:1080 --proxy-user "vpn-user:<SOCKS_PASSWORD>" https://api.ipify.org
# Expected: OUT public IPv4 (same as OUT_EXPECTED_EGRESS after check)
```

---

### CoreDNS Health

```bash
cd <REPO_ROOT>

# Test DNS resolution
dc exec coredns dig @127.0.0.1 google.com +short +time=2

# DoT upstream connections
dc exec coredns ss -tn | grep :853 | wc -l

# CoreDNS ipt2socks FD usage
dc exec coredns sh -c 'p=$(pgrep -x ipt2socks); echo "pid=$p fd=$(ls -1 /proc/$p/fd 2>/dev/null | wc -l)"'

# Check for DNS timeouts
dc logs coredns --since 1h | grep -i timeout
```

---

### AWG Tunnel Health

```bash
cd <REPO_ROOT>

# Peer handshakes (inside container)
dc exec amneziawg awg show awg0 latest-handshakes

# Active peers
dc exec amneziawg awg show awg0 peers

# Transfer stats
dc exec amneziawg awg show awg0 transfer

# From host: ping gateway
ping -c 2 10.8.0.1
```

---

### Docker Network

```bash
# Check IPv6 is enabled
docker network inspect vpn | grep -E "EnableIPv6|IPv6"
# Expected: "EnableIPv6": true

# Check bridge interface
docker network inspect vpn -f '{{.Id}}' | cut -c1-12 | xargs -I {} echo br-{}

# Verify host route exists
ip route show | grep 10.8.0.0/24
# Expected: 10.8.0.0/24 via 172.20.0.3 dev br-XXXX

# Container IPv6 addresses (pinned in compose: AMNEZIAWG_IPV6, COREDNS_IPV6, XRAY_IPV6)
dc exec xray ip -6 addr show eth0 | grep inet6
dc exec coredns ip -6 addr show eth0 | grep inet6
```

---

## Testing from Client

**On AWG client:**

```bash
# DNS test
dig @10.8.0.1 google.com +short

# DNS leak test
curl -4 https://1.1.1.1/cdn-cgi/trace | grep -E "ip=|loc="
# Expected: ip=<egress-ipv4>, loc=<OUT_COUNTRY>  (egress-ipv4 ≈ OUT_EXPECTED_EGRESS)

# Exit IP
curl -4 https://api.ipify.org
# Expected: OUT public IPv4 (same as OUT_EXPECTED_EGRESS after check)

# HTTP test
curl -4 -I https://google.com
# Expected: HTTP/2 200 or 301

# Latency
ping -c 10 10.8.0.1
# Expected: <50ms stable
```

---

## Troubleshooting Decision Tree

### Issue: Client cannot resolve DNS

```
1. Test CoreDNS directly from server:
   dc exec coredns dig @127.0.0.1 google.com +short
   ├─ SERVFAIL → Check xray REALITY tunnel: dc logs xray --tail=50
   └─ Works → Check iptables DNAT: dc exec amneziawg iptables -t nat -L PREROUTING -n -v | grep :53

2. If DNAT shows 0 packets:
   ├─ Full stack refresh: make refresh-full (do not force-recreate amneziawg alone — breaks voice UDP)
   └─ Verify awg0 interface: dc exec amneziawg ip addr show awg0

3. If CoreDNS fails:
   ├─ Check DoT upstream: dc exec coredns ss -tn | grep :853
   └─ Restart coredns: dc restart coredns
```

---

### Issue: Client Recv-Q >50, slow HTTP

```
1. Check ipt2socks FD exhaustion:
   dc exec amneziawg sh -c 'for p in $(pgrep -x ipt2socks); do echo "pid=$p fd=$(ls -1 /proc/$p/fd 2>/dev/null | wc -l)"; done'
   └─ If >6000: approaching IPT2SOCKS_NOFILE_LIMIT → make refresh-full

2. Check active connections:
   dc exec amneziawg ss -tn | grep 172.20.0.4:1080 | wc -l
   └─ If >400: high connection count → make refresh-full

3. Check Xray EOF errors:
   dc logs xray --tail=50 | grep EOF
   └─ If present: xray → OUT connection issue, check OUT server status
```

**Fix:** `make refresh-full` (clears stale SOCKS connections without desyncing xray ↔ udp-relay). Do not `docker restart` or `--force-recreate` a single container — Telegram voice hangs on Connecting… (`inject=0`). See [FAQ.md](./FAQ.md#after-git-checkout-or-git-pull).

---

### Issue: "Connection reset" or "SSL_ERROR_SYSCALL"

```
1. Check xray can reach OUT IPv6:
   dc exec xray ping6 -c 2 '<OUT_EXIT address>'   # IPv6 from OUT_EXIT='6; …'
   └─ "Network unreachable" → IPv6 missing in docker network

2. Verify IPv6 enabled:
   docker network inspect vpn | grep EnableIPv6
   └─ Should be "true"

3. Check xray has IPv6 address:
   dc exec xray ip -6 addr show eth0
   └─ Should show address inside DOCKER_NETWORK_SUBNET_IPV6 (default fd87:172:20::/64)

4. If IPv6 missing:
   make refresh-full
```

---

### Issue: Telegram voice stuck on Connecting…

See **[VOICE.md](./VOICE.md)** — full runbook (gate → probe → snapshot → `make refresh-full`).

---

### Issue: AWG tunnel down (ping 10.8.0.1 fails from host)

```
1. Check container status:
   dc ps | grep amneziawg
   └─ Should be "healthy"

2. Check awg0 interface:
   dc exec amneziawg ip addr show awg0
   └─ Should show UP state

3. Check host route:
   ip route show | grep 10.8.0.0/24
   └─ If missing: restore route

   sudo ip route add 10.8.0.0/24 via 172.20.0.3 \
     dev $(docker network inspect vpn -f '{{.Id}}' | cut -c1-12 | xargs -I {} echo br-{})
```

---

### Issue: Container unhealthy

```
1. Identify which container:
   dc ps

2. Check healthcheck logs:
   docker inspect <container_name> --format='{{json .State.Health}}' | jq

3. Check container logs:
   dc logs <container_name> --tail=50

4. Common fixes:
   ├─ amneziawg / xray: awg0 down, ipt2socks crash, config change → make refresh-full
   ├─ coredns: DNS timeout → dc restart coredns (safe alone)
   └─ xray: Config error → fix config, then make refresh-full (not restart xray alone)
```

---

## Voice / UDP troubleshooting

See **[VOICE.md](./VOICE.md)** — Telegram group voice runbook (gate → probe → snapshot → refresh-full).

---

## Maintenance Procedures

### Container restart policy

| Service | Restart alone? | Use instead |
|---------|----------------|-------------|
| **amneziawg** | **No** (breaks voice UDP) | `make refresh-full` |
| **xray** | **No** (breaks voice UDP) | `make refresh-full` |
| **coredns** | Yes | `dc restart coredns` |

```bash
# DNS only — safe:
dc restart coredns

# AWG / xray / config / image / git pull — full stack:
make refresh-full
```

---

### Host teardown

Remove host-level VPN artifacts when decommissioning a test machine or before moving the repo path. Does **not** delete Docker images or `.data/`.

```bash
make remove-full       # down + host-remove (.data/ kept)
# or: make down && sudo make host-remove
# or: sudo make kmod-remove   # kernel module + boot unit only
```

See [DEPLOYMENT.md § Host teardown](./DEPLOYMENT.md#host-teardown).

---

### Restart Full Stack

```bash
cd <REPO_ROOT>

# After git pull, .env, or image rebuild — prefer this (not bare restart):
make refresh-full

# Graceful restart all containers (TCP may recover; voice UDP often needs refresh-full after):
dc restart
```

**Impact:** `refresh-full` ~30s full disruption; bare `restart` ~10s but can leave stale UDP state.

---

### Full Recreate (after config changes)

```bash
cd <REPO_ROOT>

make refresh-full

# Verify
make ps
ping -c 2 10.8.0.1
make voice-gate WATCH=30   # optional — Telegram group voice smoke test
```

**Impact:** Full disruption (~30s). Runs `down` → `build` → `images` → `recreate` → `start` so all containers and the `vpn` network share fresh SOCKS UDP state.

---

### Update Xray

```bash
cd <REPO_ROOT>

dc pull xray
make refresh-full

# Verify
dc logs xray --tail=20
curl -4 -x socks5h://127.0.0.1:1080 --proxy-user "vpn-user:<SOCKS_PASSWORD>" https://api.ipify.org
```

---

### Add AWG Client

1. **Generate keys on client:**

```bash
awg genkey | tee client_private.key | awg pubkey > client_public.key
```

2. **Choose free IP:** Check `dc exec amneziawg awg show awg0 peers`, pick unused from 10.8.0.0/24 (e.g., 10.8.0.8).

3. **Add peer to server** (prefer Makefile):

```bash
cd <REPO_ROOT>

make awg-client-add NAME=<name>
make awg-client-list

# Manual edit instead:
# nano .data/build/awg0.conf
# make refresh-full
```

4. **Create client config:**

```bash
cd <REPO_ROOT>/.data/clients_awg

cat > new_client.conf <<EOF
[Interface]
PrivateKey = <client_private_key>
Address = 10.8.0.8/32, fd86:ea04:1115::8/128
DNS = 10.8.0.1

[Peer]
PublicKey = <server_public_key from .data/build/awg0.conf or make awg-client-list>
Endpoint = <ingress-host>:<AWG_PORT>   # IPv4 from IN_INGRESS
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
```

5. **Test from client:**

```bash
# Import config and connect
awg-quick up new_client

# Test
ping -c 2 10.8.0.1
curl -4 https://api.ipify.org  # Should show OUT public IPv4 (OUT_EXPECTED_EGRESS)
```

---

### Remove AWG Client

```bash
cd <REPO_ROOT>

# Prefer:
make awg-client-remove NAME=<name>

# Or manual edit:
# nano .data/build/awg0.conf
# make refresh-full

# Verify
dc exec amneziawg awg show awg0 peers
```

---

### Change Xray SOCKS Password

```bash
cd <REPO_ROOT>

# 1. Update .env
nano .data/.env
# Change SOCKS_PASSWORD=new_password

# 2. Regenerate config (SOCKS pass is rendered from .env into config.json + ipt2socks scripts)
make build

# 3. Full stack refresh
make refresh-full

# 4. Test
curl -4 -x socks5h://127.0.0.1:1080 --proxy-user "vpn-user:new_password" https://api.ipify.org
```

---

### Rotate Xray REALITY Keys

**When:** Every 6-12 months or if keys compromised.

**Steps:**

1. Generate new keypair on OUT server
2. Update IN server (`<IN_SERVER>`) xray config `outbound.exit.streamSettings.realitySettings.publicKey`
3. `make refresh-full`
4. Test: `curl -4 -x socks5h://127.0.0.1:1080 --proxy-user "vpn-user:<SOCKS_PASSWORD>" https://google.com`

---

## Log Analysis

### Find Connection Exhaustion Events

```bash
cd <REPO_ROOT>

# Search for EMFILE (out of FD)
dc logs amneziawg --since 24h | grep EMFILE

# Search for accept failures
dc logs amneziawg --since 24h | grep "accept.*failed"
```

**If found:** Increase `IPT2SOCKS_NOFILE_LIMIT` and container ulimits (default 8192; see [IPT2SOCKS.md](./IPT2SOCKS.md#tuning--monitoring)).

---

### Find Xray REALITY Issues

```bash
cd <REPO_ROOT>

# Connection resets (could indicate OUT server issues)
dc logs xray --since 6h | grep -iE "EOF|reset|connection.*closed"

# Authentication failures
dc logs xray --since 6h | grep "rejected"

# REALITY handshake failures
dc logs xray --since 6h | grep -i "reality"
```

---

### Find DNS Issues

```bash
cd <REPO_ROOT>

# CoreDNS upstream timeouts
dc logs coredns --since 1h | grep -i timeout

# DoT connection failures
dc logs coredns --since 1h | grep -iE "tls|853"

# NXDOMAIN responses (normal, but high rate = suspicious)
dc logs coredns --since 1h | grep NXDOMAIN | wc -l
```

---

## Backup & Restore

### Backup Configuration

```bash
cd <REPO_ROOT>

# Create timestamped backup
tar czf ~/vpn-bridge-backup-$(date +%Y%m%d-%H%M%S).tar.gz \
  .data/.env \
  .data/build/ \
  .data/clients_awg/

# Verify backup
tar tzf ~/vpn-bridge-backup-*.tar.gz | head -20
```

**⚠️ Security:** Backup contains secrets. Store encrypted off-server.

---

### Restore Configuration

```bash
cd <REPO_ROOT>

make down

tar xzf ~/vpn-bridge-backup-20260830-*.tar.gz -C .

make up
make start    # preferred: containers + host route
```

---

## Performance Tuning

### Current Limits

| Parameter | amneziawg | coredns | Notes |
|-----------|---------------|-------------|-------|
| `IPT2SOCKS_NOFILE_LIMIT` | 8192 | 8192 | Compose ulimits; raise if FD pressure under load |
| ipt2socks processes | 2 (v4 + v6) | 1 (DoT :853) | supervisord-managed |
| `IPT2SOCKS_UDP_TIMEOUT` | 60s | N/A | UDP not proxied in coredns path |
| Container memory | 512MB | 256MB | Per container |
| Log retention | 10MB | 10MB | Per container |

**These limits support ~100 parallel HTTPS connections (1 active AWG client = ~50 connections).**

### If Load Increases (5+ Active Clients)

```bash
cd <REPO_ROOT>

# Monitor metrics under load
watch -n 5 'dc exec amneziawg sh -c "
  for p in \$(pgrep -x ipt2socks); do echo pid=\$p FD: \$(ls -1 /proc/\$p/fd 2>/dev/null | wc -l) / 8192; done
  echo Conn: \$(ss -tn | grep 172.20.0.4:1080 | wc -l)
"'
```

**If FD usage >6000 or connections >400:**

1. **Increase `IPT2SOCKS_NOFILE_LIMIT` in `.env`:**

```bash
IPT2SOCKS_NOFILE_LIMIT=16384
```

2. **Increase docker ulimits:**

```yaml
ulimits:
  nofile:
    soft: 16384
    hard: 32768
```

3. **Regenerate and recreate containers:**

```bash
make refresh-full
```

See also [IPT2SOCKS.md](./IPT2SOCKS.md#tuning--monitoring).

---

## Alerts & Thresholds

**Recommended monitoring (if using Prometheus/Grafana):**

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| ipt2socks FD usage | >6000 | >7500 | Increase `IPT2SOCKS_NOFILE_LIMIT` / ulimits |
| ipt2socks connections | >400 | >480 | Raise `IPT2SOCKS_NOFILE_LIMIT`, `make refresh-full` |
| Client Recv-Q | >50 | >100 | `make refresh-full` (not single-container restart) |
| Xray EOF errors | >10/hour | >50/hour | Check OUT server; `make refresh-full` if voice broken |
| Container unhealthy | any | any | `make refresh-full` (awg/xray); `dc restart coredns` if DNS only |
| Disk usage | >80% | >90% | Rotate/compress logs |

---

## Security Checks

```bash
cd <REPO_ROOT>

# Verify no RFC1918 leaks from clients
dc exec amneziawg iptables -t filter -L FORWARD -n -v | grep -E "10\.|172\.|192\.168"
# Should show DROP rules with 0 packets

# Verify no DoQ leaks
dc exec amneziawg iptables -t filter -L FORWARD -n -v | grep -E ":784|:8853"
# Should show DROP rules with 0 packets

# Verify MASQUERADE is working
dc exec amneziawg iptables -t nat -L POSTROUTING -n -v | grep 10.8.0.0
# Should show packets counted

# Check host firewall (docker cannot access host)
sudo iptables -L INPUT -n -v | grep 172.20.0.0
# Should show DROP rule
```

---

## Useful Shortcuts

Add to `~/.bashrc` (define `dc` once — see [Convention](#convention-repo-root)):

```bash
dc() { docker compose -f <REPO_ROOT>/.data/build/docker-compose.yml --env-file <REPO_ROOT>/.data/.env "$@"; }
alias vpn-status='cd <REPO_ROOT> && make ps'
alias vpn-logs='cd <REPO_ROOT> && make logs'
alias vpn-health='cd <REPO_ROOT> && dc exec amneziawg sh -c "for p in \$(pgrep -x ipt2socks); do echo pid=\$p FD: \$(ls -1 /proc/\$p/fd 2>/dev/null | wc -l); done; echo Conn: \$(ss -tn | grep 172.20.0.4:1080 | wc -l)"'
alias vpn-refresh='cd <REPO_ROOT> && make refresh-full'
alias vpn-test='curl -4 -x socks5h://127.0.0.1:1080 --proxy-user "vpn-user:<SOCKS_PASSWORD>" https://api.ipify.org'
```

---

**Last updated:** 2026-09-02

→ [All documentation](./README.md)
