# Configuration layout

Operator secrets live in **`.data/.env`** (gitignored). This directory holds **templates**, **static** files, and **examples** only.

## Canonical `.env` template

| File | Role |
|------|------|
| **`config/examples/.env.example`** | **Source of truth** — `make create-data` copies this → `.data/.env` |
| `.env.example` (repo root) | Same content for discoverability — **keep in sync** (`tests/guards/test_env_example_sync.sh`) |

Edit keys in the canonical file, then `make build && make refresh-full`.

## Directories

| Path | Rendered? | Purpose |
|------|-----------|---------|
| **`templates/`** | Yes (`envsubst`) | Policy → `.data/build/` |
| **`static/`** | No | Legacy / reference only (`Corefile` superseded by `Corefile.tmpl`) |
| **`examples/`** | No | Bootstrap templates and operator references |

## Render pipeline

```
.data/.env  +  config/templates/*.tmpl
        │
        ▼  make build  (scripts/setup/render-config.sh)
        │
.data/build/
        ├── awg0.conf              ← merge [Peer] from existing build file
        ├── config.json            ← merge VLESS clients + post-process inbounds
        ├── docker-compose.yml     ← post-process inbound + MTProxy ports
        ├── Corefile               ← from Corefile.tmpl (COREDNS_UPSTREAM)
        ├── ipt2socks-amneziawg-v4.sh
        ├── ipt2socks-amneziawg-v6.sh
        ├── ipt2socks-coredns.sh
        ├── udp-relay-run.sh
        └── ipt2socks-ports.env
```

Build snapshots (before `make build` overwrites `build/`): `.data/build-snapshots/pre-build-*`.

**Do not edit `.data/build/` by hand** — change `.data/.env` or use `make awg-client-add`, then `make build && make refresh-full`.

Template `${VAR}` placeholders are auto-collected (`scripts/setup/collect-envsubst-vars.py`); `make build` fails on leftover `${…}` in rendered files. `config.json` is validated with `xray run -test` when the image is local.

### Template → output map

| Template | Build file |
|----------|----------------|
| `awg0.conf.tmpl` | `awg0.conf` |
| `config.json.tmpl` | `config.json` (via merge) |
| `docker-compose.yml.tmpl` | `docker-compose.yml` |
| `Corefile.tmpl` | `Corefile` |
| `ipt2socks-amneziawg-v4.sh.tmpl` | `ipt2socks-amneziawg-v4.sh` |
| `ipt2socks-amneziawg-v6.sh.tmpl` | `ipt2socks-amneziawg-v6.sh` |
| `ipt2socks-coredns.sh.tmpl` | `ipt2socks-coredns.sh` |
| `udp-relay-run.sh.tmpl` | `udp-relay-run.sh` |
| `ipt2socks-ports.env.tmpl` | `ipt2socks-ports.env` |

### Post-build steps (not in templates)

| Script | Applies to | Why outside tmpl |
|--------|------------|------------------|
| `scripts/setup/merge-awg-peers.sh` | `awg0.conf` | Preserve live `[Peer]` blocks |
| `scripts/setup/merge-xray-config.py` | `config.json` | Preserve VLESS `clients[]` / routing |
| `scripts/setup/apply-xray-inbound.py` | `config.json` | Enable/disable inbound from `ENABLE_XRAY_INBOUND` |
| `scripts/setup/apply-compose-xray-ports.sh` | `docker-compose.yml` | Publish / strip inbound port |
| `scripts/setup/apply-compose-mtproxy.sh` | `docker-compose.yml` | Host ports when `ENABLE_MTPROXY=1` |
| `render_compose` (markers) | `docker-compose.yml` | Strip `teleproxy` when `ENABLE_MTPROXY=0` |

Compose optional services use `# >>> service: name` markers (same as test fixtures), not regex strip.

## Examples (not rendered)

| File | Purpose |
|------|---------|
| `examples/.env.example` | Canonical env template (`make create-data`) |
| `examples/client.conf.example` | AWG client export shape |
| `examples/client.vless.example` | VLESS REALITY inbound client reference |
| `examples/nginx-stream-443.conf.example` | Host nginx SNI router (`MTPROXY_MODE=sni`, generic) |
| `examples/nginx-stream-443.example-host.conf.example` | Same for example-host hosts |
| `examples/site-vhost-8080.conf.example` | Site vhost on loopback `:8080` after SNI cutover |
| `examples/docker-compose.services.reference.yml` | Rendered compose shape (documentation) |

## Static files

| File | Notes |
|------|-------|
| `static/Corefile` | Deprecated default; live mount uses `.data/build/Corefile` from `Corefile.tmpl` |

## Runtime edits (production)

| What | Path | After edit |
|------|------|------------|
| Live secrets / topology | `.data/.env` | `make build && make refresh-full` |
| AWG peers (preferred) | `make awg-client-add` / `remove` | auto build + refresh |
| AWG peers (manual) | `.data/build/awg0.conf` | `make refresh-full` |
| Xray policy | edit `config/templates/*.tmpl` or `.env` | `make build && make refresh-full` |
| CoreDNS upstream | `COREDNS_UPSTREAM` in `.env` | `make build && make refresh-full` |

See also: [../docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md), [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).
