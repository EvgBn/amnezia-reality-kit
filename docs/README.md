# Documentation

Single index for everything under `docs/` and related repo guides (`config/`, `containers/`, `scripts/`).

---

## Deploy & run

| Document | Purpose |
|----------|---------|
| [QUICKSTART.md](./QUICKSTART.md) | Deploy + daily ops on one page |
| [DEPLOYMENT.md](./DEPLOYMENT.md) | Full guide: paths A/B, migrate, teardown, clients |
| [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) | Symptom → first check → command |
| [FAQ.md](./FAQ.md) | WARN in `make check`, `make up` vs route, pitfalls |
| [VERIFY.md](./VERIFY.md) | `make verify-*`, `regression-443` vs check phases |

### OUT server & IN ports

| Document | Purpose |
|----------|---------|
| [OUT.md](./OUT.md) | OUT exit (VLESS REALITY), `OUT_*` in `.env` |
| [PORT-443.md](./PORT-443.md) | Host `:443` vs website, `ENABLE_XRAY_INBOUND` |

### MTProxy & SNI

| Document | Purpose |
|----------|---------|
| [MTPROXY.md](./MTPROXY.md) | Teleproxy, standalone vs SNI profile |
| [SNI-9-PLUS.md](./SNI-9-PLUS.md) | SNI invariants, verification layers |
| [SNI-CUTOVER.md](./SNI-CUTOVER.md) | Prod cutover runbook (nginx stream `:443`) |

### Runbooks

| Document | Purpose |
|----------|---------|
| [VOICE.md](./VOICE.md) | Telegram group voice (UDP / `voice-gate`) |
| [KEYS-RECOVERY.md](./KEYS-RECOVERY.md) | AWG keys, `.env` drift, pubkey checks |

---

## Architecture & traffic

| Document | Purpose |
|----------|---------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Components, traffic flows, Docker network, xray config |
| [IPT2SOCKS.md](./IPT2SOCKS.md) | ipt2socks (TCP) + udp-relay (UDP), tuning |
| [SECURITY.md](./SECURITY.md) | Threat model, DNS leak vectors, hardening checklist |
| [SECURITY-DISCLOSURE.md](./SECURITY-DISCLOSURE.md) | Report vulnerabilities (`[security]` in subject) |

---

## Checks & monitoring

| Document | Purpose |
|----------|---------|
| [CHECK.md](./CHECK.md) | `make check` — phases 1–11, OK/WARN/FAIL |
| [OPERATIONS.md](./OPERATIONS.md) | Monitoring, FD tuning, backup, alerts |

---

## Config & examples

| Document | Purpose |
|----------|---------|
| [../config/README.md](../config/README.md) | Templates, `make build`, `.data/build/` layout |
| [../config/examples/.env.example](../config/examples/.env.example) | Canonical `.env` template |
| [../config/examples/client.conf.example](../config/examples/client.conf.example) | AWG client export shape |
| [../config/examples/client.vless.example](../config/examples/client.vless.example) | VLESS REALITY client reference |
| [../config/examples/nginx-stream-443.conf.example](../config/examples/nginx-stream-443.conf.example) | Host nginx SNI router (generic) |
| [../config/examples/nginx-stream-443.example-host.conf.example](../config/examples/nginx-stream-443.example-host.conf.example) | SNI router — example-host hosts |
| [../config/examples/site-vhost-8080.conf.example](../config/examples/site-vhost-8080.conf.example) | Site vhost on loopback `:8080` after SNI |
| [../config/examples/docker-compose.services.reference.yml](../config/examples/docker-compose.services.reference.yml) | Rendered compose shape (reference) |

---

## Containers

| Document | Purpose |
|----------|---------|
| [../containers/README.md](../containers/README.md) | Images overview, supervisord pattern |
| [../containers/amneziawg/README.md](../containers/amneziawg/README.md) | `vpn-amneziawg` — processes, volumes, ports, caps |
| [../containers/ipt2socks/README.md](../containers/ipt2socks/README.md) | `zfl9/ipt2socks` build artifact |

---

## Scripts & contributing

| Document | Purpose |
|----------|---------|
| [../scripts/preflight/README.md](../scripts/preflight/README.md) | `make check` module internals |
| [../scripts/clients/README.md](../scripts/clients/README.md) | `awg-client-add`, REALITY clients |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Tests, guards, doc update rules |
| [../ISSUES.md](../ISSUES.md) | Known gaps, roadmap |

---

## Repository layout

```
├── Makefile                        # create-data, build, start, refresh-full, check, …
├── .env.example                    # mirror of config/examples/.env.example
├── ISSUES.md
├── tests/                          # unit, integration, guards, fixtures
├── .data/                          # gitignored — .env, build/, clients_awg/
├── config/                         # templates/, examples/, static/
├── containers/                     # amneziawg, coredns, ipt2socks
├── scripts/                        # setup, preflight, deployment, maintenance, clients
└── docs/                           # this tree (QUICKSTART.md = operator funnel)
```

Client configs after `make awg-client-add`: **`.data/clients_awg/<name>.conf`**.

→ [Repository root](https://github.com/EvgBn/amnezia-reality-kit/tree/main)
