# Container images

Custom Docker images built by `make images` (via `docker compose build` in `.data/build/`).

**Not in this directory:** **xray** runs as upstream image `teddysun/xray` in compose — SOCKS `:1080` + REALITY outbound. Config: `.data/build/config.json`.

## Runtime containers (supervisord)

| Directory | Compose service | Role |
|-----------|-----------------|------|
| **[amneziawg/](amneziawg/README.md)** | `amneziawg` (`vpn-amneziawg`) | AWG `awg0`, iptables, ipt2socks (TCP v4/v6), **udp-relay** (NFQUEUE UDP), inject return path |
| **coredns/** | `coredns` (`vpn-coredns`) | CoreDNS `:53`, ipt2socks for DoT `:853` → xray SOCKS |

Shared container pattern:

```
Dockerfile → entrypoint.sh → supervisord
              ├── *-init.sh   (long-lived or one-shot setup)
              └── healthcheck.sh
```

Startup ordering uses **wait loops in rendered shell scripts** (for `awg0 UP`, ipt2socks ready), not supervisord extensions.

Rendered launch scripts and configs are **bind-mounted** from `.data/build/` (not baked into the image): `awg0.conf`, `ipt2socks-*.sh`, `udp-relay-run.sh`, `ports.env`.

## Build artifact (not a runtime container)

| Directory | Output | Used by |
|-----------|--------|---------|
| **ipt2socks/** | `zfl9/ipt2socks:latest` | `make images-ipt2socks`; COPY into amneziawg and coredns Dockerfiles |

See [IPT2SOCKS.md](../docs/IPT2SOCKS.md) and [ARCHITECTURE.md § Traffic Flows](../docs/ARCHITECTURE.md#traffic-flows).
