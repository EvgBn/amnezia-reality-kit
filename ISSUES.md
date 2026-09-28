# Known issues and planned work

## MTProxy (Teleproxy) — SNI host nginx

**Status:** kit stages 0–6 implemented (`ENABLE_MTPROXY=0` default).

**Operator-owned for 9+ (`MTPROXY_MODE=sni`):**

- Architecture: **[docs/SNI-9-PLUS.md](docs/SNI-9-PLUS.md)** — map lint + TLS probes in `make check 11`
- Runbook: **[docs/SNI-CUTOVER.md](docs/SNI-CUTOVER.md)** (example-host inventory filled)
- nginx `stream` + `ssl_preread` on host `:443` — `config/examples/nginx-stream-443*.conf.example`
- Site vhosts moved to `listen 127.0.0.1:8080 ssl`; certbot renew via :80 or DNS-01
- Validate: `make verify-sni-443`, `make regression-443`, `make check 11`

**Done in kit (9.2):** `scripts/lib/mtproxy-sni.sh` — nginx map lint + `:443` SNI TLS probe (phase 11 `nginx-sni-map`, `nginx-sni-tls`).

---

## REALITY (VLESS) client scripts — not tested

**Status:** path-migrated to `scripts/clients/reality/`, not validated on production.

**Scope:** `add.sh`, `remove.sh`, `remove-client.py` — inbound VLESS user management
(config.json `clients[]`, `.data/clients_xray/<name>.vless`).

**Near-term plan:**

1. Smoke-test add/remove against a non-production name.
2. Fix inbound `security: "none"` if REALITY clients are needed on this host.
3. Verify `docker compose restart xray` picks up config after in-place writes.
4. Add `reality/list.sh` and document ingress (`IN_INGRESS`, `XRAY_INBOUND_PORT`).

**Production today:** AWG clients only (`scripts/clients/awg/` — tested).

---

## AWG over IPv6 — not end-to-end tested

**Status:** server-side IPv6 path is configured (tunnel ULA, `ipt2socks` v6 listener, `ip6tables` REDIRECT/DNAT in rendered `awg0.conf`), but **no production validation with an IPv6-capable AWG client**.

**Reason:** no IPv6 AWG client available in the current test setup (IPv4 client exports and `curl -4`-style checks only).

**What is untested:**

- Client tunnel over IPv6 (`AllowedIPs` includes `::/0`, v6 address on tunnel)
- IPv6 DNS E2E through CoreDNS (`AAAA` via tunnel gateway)
- IPv6 TCP exit via `:12346` REDIRECT → ipt2socks v6 → REALITY OUT

**If you have a verified working IPv6 AmneziaWG client setup against this stack**, please write to the project contacts (see [README § Contact](./README.md#contact)). Include client app/version, OS, and a short repro (e.g. `curl -6`, `dig AAAA`).
