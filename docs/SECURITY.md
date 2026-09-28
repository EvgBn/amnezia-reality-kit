# VPN Server — Security & DNS Leak Protection

**Last updated:** 2026-09-05

**Compose commands:** use `dc` below or `make ps` / `make logs`. Define once from repo root:

```bash
cd <REPO_ROOT>
dc() { docker compose -f .data/build/docker-compose.yml --env-file .data/.env "$@"; }
```

Details: [OPERATIONS.md § Convention](./OPERATIONS.md#convention-repo-root).

**Overall score:** **9.4/10** (IPv4 DNS leak protection) — average of per-vector scores in [§1–13](#dns-leak-attack-vectors--mitigations) below; IPv6 DNS not E2E verified.

---

## Threat Model

### Adversary Capabilities

1. **Local ISP (entry):** Can see AWG encrypted UDP traffic to ingress host (`IN_INGRESS`) on `<AWG_PORT>`
2. **DPI:** Cannot decrypt AWG/REALITY tunnels (obfuscation + TLS 1.3)
3. **DNS surveillance:** Can log DNS queries to public resolvers (1.1.1.1, 8.8.8.8)
4. **BGP hijacking:** Could redirect traffic to fake resolvers

### Protection Goals

1. **No DNS leaks:** All DNS queries must exit via REALITY tunnel
2. **No IP leaks:** All HTTP/HTTPS must exit via OUT server (public egress IPv4; verify with `OUT_EXPECTED_EGRESS` in `make check`)
3. **No RFC1918 access:** Clients cannot reach docker internal networks or host services
4. **DoH/DoT stealth:** Upstream DNS queries from CoreDNS must be indistinguishable from HTTPS

---

## DNS Leak Attack Vectors & Mitigations

### 1. Plain DNS (UDP :53)

**Attack:** Client sends DNS query directly to 8.8.8.8:53, bypassing VPN DNS.

**Mitigation:**

```bash
# iptables DNAT (amneziawg)
-A PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination 172.20.0.2:53
```

**Verified:**

```bash
dig @8.8.8.8 google.com
# Response comes from 10.8.0.1 (iptables rewrote destination)

dc exec amneziawg iptables -t nat -L PREROUTING -n -v | grep ":53"
```

**Score:** 9/10 (IPv4 only)

---

### 2. Plain DNS (TCP :53)

**Mitigation:**

```bash
-A PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination 172.20.0.2:53
```

**Score:** 9/10

---

### 3. DNS to Arbitrary IP

**Mitigation:** DNAT is **destination-independent** — matches any UDP/TCP :53.

**Score:** 9/10

---

### 4. IPv6 DNS

**Mitigation:**

```bash
-A PREROUTING -i awg0 -p udp --dport 53 -j DNAT --to-destination [<coredns-ipv6>]:53
-A PREROUTING -i awg0 -p tcp --dport 53 -j DNAT --to-destination [<coredns-ipv6>]:53
```

**Status:** Rules exist in `awg0.conf`, but **not E2E tested**. `COREDNS_IPV6` is pinned in compose — verify DNAT target matches live address (`make check`).

**Score:** 7/10

---

### 5. DNS-over-HTTPS (DoH :443)

**Mitigation:** iptables REDIRECT tcp !:53 → ipt2socks → REALITY.

**Score:** 9/10

---

### 6. DNS-over-TLS (DoT :853)

**Mitigation:** Same as DoH — TCP :853 → REDIRECT → ipt2socks → REALITY.

**Score:** 9/10

---

### 7. DNS-over-QUIC (DoQ :784, :8853)

**Mitigation:**

```bash
-A FORWARD -i awg0 -p udp --dport 784 -j DROP
-A FORWARD -i awg0 -p udp --dport 8853 -j DROP
```

**Score:** 8/10

---

### 8. CoreDNS Upstream DoT

**Mitigation:**

```bash
-A OUTPUT -p tcp --dport 853 -j REDIRECT --to-ports 12347
# ipt2socks :12347 → Xray SOCKS → REALITY → OUT → 1.1.1.1:853
# Never direct to 1.1.1.1 from <IN_SERVER>
```

**Verified:**

```bash
dc exec coredns ss -tn | grep :853
# Connection to 172.20.0.4:1080 (Xray SOCKS)
```

**Score:** 9/10

---

### 9. HTTP/HTTPS IP Leak

**Mitigation:** REDIRECT tcp !:53 → ipt2socks → REALITY.

**Verified:**

```bash
curl -4 https://api.ipify.org
# Returns: OUT public IPv4 (set OUT_EXPECTED_EGRESS='4; …' to match)
```

**Score:** 9/10

---

### 10. Configuration Persistence

**Mitigation:** iptables in `awg0.conf` PostUp; container ipt2socks via compose `restart: unless-stopped`; Docker IPv6 enabled.

**Score:** 9/10

---

### 11. DNS Query Logging

**Mitigation:** No `log` plugin in `coredns/Corefile`; json-file log rotation.

**Score:** 8/10

---

### 12. RFC1918 Access

**Mitigation:** FORWARD DROP for RFC1918/100.64/169.254; explicit ACCEPT for CoreDNS :53.

**Score:** 8/10

---

### 13. ipt2socks/ulimits

**Mitigation:** `IPT2SOCKS_NOFILE_LIMIT=8192`, compose ulimits (8192/16384), `IPT2SOCKS_THREADS`, healthchecks (2× ipt2socks + REDIRECT rules), supervisord restarts.

**Score:** 9/10

---

## Vector summary

Per-vector scores (details in §1–13 above). No weighted rollup table — use [Security Hardening Checklist](#security-hardening-checklist) for operator pass/fail.

| Area | Score | Note |
|------|-------|------|
| Plain DNS UDP | 9/10 | DNAT → CoreDNS |
| Plain DNS TCP | 9/10 | DNAT → CoreDNS |
| DNS arbitrary IP | 9/10 | destination-independent DNAT |
| IPv6 DNS | 7/10 | rules exist; **E2E not verified** |
| DoH :443 | 9/10 | REDIRECT → ipt2socks → REALITY |
| DoT :853 | 9/10 | REDIRECT → ipt2socks → REALITY |
| DoQ block | 8/10 | FORWARD DROP :784 / :8853 |
| CoreDNS upstream DoT | 9/10 | OUTPUT :853 → ipt2socks → OUT |
| HTTP/HTTPS exit | 9/10 | exit IP = OUT server |
| Config persistence | 9/10 | PostUp rules + restart policy |
| DNS logging | 8/10 | no CoreDNS `log` plugin |
| RFC1918 block | 8/10 | FORWARD DROP + CoreDNS :53 allow |
| ipt2socks reliability | 9/10 | ulimits + healthchecks |

---

## Remaining Gaps

- **IPv6 DNS E2E:** ip6tables DNAT/REDIRECT rules exist; not verified with a real IPv6-only client on the tunnel

---

## Security Hardening Checklist

| Item | Status |
|------|--------|
| All DNS forced through CoreDNS | ✅ |
| CoreDNS upstream via REALITY | ✅ |
| HTTP/HTTPS via REALITY | ✅ |
| DoQ blocked | ✅ |
| RFC1918 blocked | ✅ |
| IPv6 enabled in Docker | ✅ |
| Xray → OUT IPv6 working | ✅ |
| ipt2socks ulimits tuned (`IPT2SOCKS_NOFILE_LIMIT`) | ✅ |
| ipt2socks v4 + v6 listeners (healthcheck) | ✅ |
| Healthchecks enabled | ✅ |
| Logs capped | ✅ |
| CoreDNS log plugin removed | ✅ |
| Host firewall (docker → host) | ✅ |
| Systemd AWG route | ✅ |
| IPv6 TCP proxy (ipt2socks v6 + ip6tables REDIRECT) | ✅ |
| IPv6 DNS E2E test | ❌ TODO |

---

## Attack Surface Analysis

Depends on `.env` — see [PORT-443.md](./PORT-443.md).

| Port | Service | Exposure | Risk |
|------|---------|----------|------|
| `<AWG_PORT>`/udp | AmneziaWG | Public | Low |
| `XRAY_INBOUND_PORT`/tcp (default 443) | Xray VLESS inbound | Public **only if `ENABLE_XRAY_INBOUND=1`** | Low |
| 443/tcp | Website (nginx/caddy) | Public when inbound disabled (`ENABLE_XRAY_INBOUND=0`) | Outside repo |
| 1080/tcp | Xray SOCKS | 127.0.0.1 only | Low |

IPv4 UDP exit (VoIP) is NFQUEUE → udp-relay inside **amneziawg**, not a separate public port. IPv6 UDP from clients is dropped at FORWARD (anti-leak).

---

## Incident Response

Use `dc` helper from [OPERATIONS.md § Convention](./OPERATIONS.md#convention-repo-root) for exec commands.

```bash
dc exec amneziawg iptables -t nat -L PREROUTING -n -v | grep :53
dc exec coredns dig @127.0.0.1 google.com +short
dig @10.8.0.1 google.com
```

### Suspected IP Leak

```bash
curl -4 https://api.ipify.org
dc exec amneziawg iptables -t nat -L PREROUTING -n -v | grep 12345
dc exec amneziawg ss -tn | grep 172.20.0.4:1080
```

### Suspected Compromise

```bash
dc stop xray
dc logs xray --since 24h > /tmp/xray-forensics.log
make refresh-full
# Rotate REALITY keys on OUT server
```

---

## Reporting security issues

Vulnerability reports: [SECURITY-DISCLOSURE.md](./SECURITY-DISCLOSURE.md) (email/Telegram with **`[security]`** — not public issues).

Support: [README § Contact](../README.md#contact).

---

## References

| Project | Role |
|---------|------|
| [seb0ch/vpn](https://github.com/seb0ch/vpn) | Inspiration / upstream architecture |
| [amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) | AmneziaWG kernel |
| [amnezia-vpn/amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) | AmneziaWG tools |
| [XTLS/Xray-core](https://github.com/XTLS/Xray-core) | Xray |
| [zfl9/ipt2socks](https://github.com/zfl9/ipt2socks) | ipt2socks |
| [coredns/coredns](https://github.com/coredns/coredns) | DNS server |
| [teleproxy/teleproxy](https://github.com/teleproxy/teleproxy) | Optional MTProxy (MTProto TCP); `ghcr.io/teleproxy/teleproxy` — [MTPROXY.md](./MTPROXY.md) |
| [Amnezia — Downloads](https://amnezia.org/downloads) | Client apps |
| [Amnezia Docs](https://docs.amnezia.org) | Documentation |
| [DNS Leak Test](https://dnsleaktest.com/) | External audit tool |
| [IP Leak Test](https://ipleak.net/) | External audit tool |

→ [All documentation](./README.md)
