# amneziawg image (runtime container)

Compose service **`amneziawg`** (`vpn-amneziawg`). VPN tunnel interface, transparent TCP/UDP exit via Xray SOCKS.

Build: `make images` (or `docker compose build` in `.data/build/`). Image tag: `amneziawg:${AMNEZIAWG_RELEASE}`.

## Processes (supervisord)

```
entrypoint.sh
└── supervisord
    ├── amneziawg      /awg-init.sh              awg-quick up awg0; iptables from PostUp in awg0.conf
    ├── ipt2socks-v4   /etc/ipt2socks/v4.sh      TCP v4 → SOCKS (REDIRECT)
    ├── ipt2socks-v6   /etc/ipt2socks/v6.sh      TCP v6 → SOCKS (REDIRECT)
    └── udp-relay      /etc/ipt2socks/udp-relay.sh   IPv4 UDP NFQUEUE → SOCKS associate + inject
```

Startup order: **xray** must be healthy (`depends_on`). `v4.sh`, `v6.sh`, and `udp-relay.sh` wait for `awg0` UP before exec. `awg-migrate-tproxy.sh` runs once at init to drop legacy TPROXY rules.

Healthcheck: `/healthcheck.sh` — `awg0` UP, 2× `ipt2socks`, `udp-relay` running, REDIRECT + NFQUEUE rules present.

## Ports

| Exposure | Port | Protocol | Notes |
|----------|------|----------|-------|
| **Published** (host) | `${AWG_PORT}` → `51820` | UDP | WireGuard/AWG listen; default from `.env` |
| Internal (REDIRECT) | `${AWG_IPT2SOCKS_PORT}` | TCP | ipt2socks v4 on `${AWG_TUNNEL_GATEWAY_IPV4}` |
| Internal (REDIRECT) | `${AWG_IPT2SOCKS_PORT_IPV6}` | TCP | ipt2socks v6 on `${AWG_TUNNEL_GATEWAY_IPV6}` |
| Internal (NFQUEUE) | queue `${AWG_NFQUEUE_NUM}` | UDP | udp-relay; excludes dports `53,784,8853` |
| Egress target | `${XRAY_IP}:${SOCKS_PORT}` | TCP/UDP | Xray SOCKS in `vpn` network (default `172.20.0.4:1080`) |

DNS to clients is DNAT `:53` → CoreDNS (rules in rendered `awg0.conf`, not a container listen port).

## Volumes contract (bind-mount from `.data/build/`)

All runtime config is **rendered at `make build`**, mounted read-only:

| Host (`.data/build/`) | Container path | Purpose |
|-----------------------|----------------|---------|
| `awg0.conf` | `/etc/awg/awg0.conf` | Interface, peers, PostUp iptables/ip6tables |
| `ipt2socks-amneziawg-v4.sh` | `/etc/ipt2socks/v4.sh` | ipt2socks launcher (v4) |
| `ipt2socks-amneziawg-v6.sh` | `/etc/ipt2socks/v6.sh` | ipt2socks launcher (v6) |
| `udp-relay-run.sh` | `/etc/ipt2socks/udp-relay.sh` | udp-relay launcher |
| `ipt2socks-ports.env` | `/etc/ipt2socks/ports.env` | Port/queue vars for init, healthcheck, scripts |

Templates: `config/templates/*.tmpl` → `scripts/setup/render-config.sh`. Do not edit mounts inside the image; change templates or `.env` and rebuild.

## Capabilities & sysctls

From `config/templates/docker-compose.yml.tmpl`:

| Setting | Value | Why |
|---------|-------|-----|
| `cap_add` | `NET_ADMIN`, `NET_RAW` | `awg0`, iptables/ip6tables, NFQUEUE |
| `sysctls` | `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1` | Tunnel forwarding |
| | `src_valid_mark`, `route_localnet`, `rp_filter=0` | REDIRECT/TPROXY-style marks and local routing |
| `ulimits.nofile` | soft `${IPT2SOCKS_NOFILE_LIMIT}`, hard `16384` | Many parallel TCP flows through ipt2socks |

**Host prerequisite:** `amneziawg` kernel module loaded (`make deploy-host`). Entrypoint exits early if `/proc/modules` lacks it.

## Dockerfile targets

| Target | Output | Use |
|--------|--------|-----|
| *(default)* | Runtime image | `make images` |
| `keygen` | `awg` only | `make create-data` key generation when no local image exists |

Binaries baked in: `awg`, `awg-quick`, `ipt2socks` (from `zfl9/ipt2socks:latest`), `udp-relay` (Go, `containers/amneziawg/cmd/udp-relay`).

## See also

- [containers/README.md](../README.md) — stack overview
- [docs/ARCHITECTURE.md § ipt2socks + udp-relay](../../docs/ARCHITECTURE.md#ipt2socks--udp-relay-transparent-proxy) — traffic paths
- [docs/IPT2SOCKS.md](../../docs/IPT2SOCKS.md) — tuning and udp-relay behavior
- [docs/VOICE.md](../../docs/VOICE.md) — UDP/voice smoke and full-stack refresh
