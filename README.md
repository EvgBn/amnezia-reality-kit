# Amnezia Reality Kit

AmneziaWG + Xray REALITY — IN server operator kit (checks & runbooks; egress to a separate OUT exit).

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 40, 'rankSpacing': 40, 'padding': 10, 'diagramPadding': 6, 'wrappingWidth': 180}, 'themeVariables': {'fontSize': '14px'}}}%%
flowchart LR
  AWG[AWG Client]

  subgraph repo [this repo]
    IN[IN SERVER]
  end

  OUT[OUT Server]

  AWG -->|AmneziaWG| IN
  IN -->|VLESS REALITY| OUT
```

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 40, 'rankSpacing': 40, 'padding': 10, 'diagramPadding': 6, 'wrappingWidth': 180}, 'themeVariables': {'fontSize': '14px'}}}%%
flowchart TB
  subgraph clients [Clients]
    AWG[AWG client]
    VLESS[VLESS client]
    TG[Telegram app]
    SITE[Site visitor / DPI probe]
  end

  subgraph IN ["IN server — kit + host nginx"]
    NGX_S["nginx host :443<br/>stream SNI router — profile sni"]
    NGX_H["nginx http :8080 or :443<br/>TLS websites"]
    AWG_C["vpn-amneziawg"]
    DNS_C["vpn-coredns"]
    XRAY["vpn-xray<br/>SOCKS :1080 + REALITY outbound"]
    MTP["vpn-teleproxy<br/>Fake-TLS optional"]
  end

  OUT["OUT server<br/>VLESS REALITY exit"]

  AWG -->|UDP AWG_PORT| AWG_C
  AWG_C --> XRAY
  DNS_C --> XRAY
  VLESS -.->|profile sni :443| NGX_S
  TG --> MTP
  SITE --> NGX_H
  NGX_S -.-> MTP
  NGX_S -.-> XRAY
  NGX_S -.-> NGX_H
  MTP -->|SOCKS5| XRAY
  XRAY --> OUT
```

## Documentation

| | Link |
|---|------|
| Quick deploy | [docs/QUICKSTART.md](./docs/QUICKSTART.md) |
| All documentation | [docs/README.md](./docs/README.md) |

## Quick start (IN server)

```bash
git clone git@github.com-amnezia-kit:EvgBn/amnezia-reality-kit.git ~/vpn-test
cd ~/vpn-test

sudo ./scripts/setup/install-docker.sh    # if needed
sudo make deploy-host
make check-host

make create-data
make first-start
make awg-client-add NAME=phone
make check
```

## Client apps (AmneziaWG)

**Config files for the client:** `.data/clients_awg/<name>.conf` — one per `make awg-client-add NAME=<name>`. Transfer to the phone/PC and open in AmneziaWG.

| Platform | Download app |
|----------|--------------|
| Android | [Google Play](https://play.google.com/store/apps/details?id=org.amnezia.vpn) |
| iOS / macOS | [App Store](https://apps.apple.com/us/app/amneziawg/id6478942365) |
| Windows | [GitHub releases](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) |
| Other | [amnezia.org/downloads](https://amnezia.org/downloads) |

## Contact

Telegram: [@amnezia_reality_kit](https://t.me/amnezia_reality_kit)

---

## Repo layout

```
├── Makefile                        # create-data, build, images, start, refresh-full, check, …
├── .env.example                    # mirror of config/examples/.env.example
├── ISSUES.md                       # known gaps
├── tests/                          # unit, integration, guards, fixtures
├── .data/                          # gitignored — live .env + build/
├── config/                         # templates, examples — see config/README.md
├── containers/                     # amneziawg, coredns, ipt2socks
├── scripts/                        # setup, preflight, deployment, maintenance
└── docs/
    ├── QUICKSTART.md               # operator funnel (deploy + daily)
    └── README.md                   # full index
```

## Credits

Inspired by [seb0ch/vpn](https://github.com/seb0ch/vpn).

Built on:

| Project | Role |
|---------|------|
| [amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) | AmneziaWG kernel |
| [amnezia-vpn/amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) | AmneziaWG tools |
| [XTLS/Xray-core](https://github.com/XTLS/Xray-core) | Xray |
| [zfl9/ipt2socks](https://github.com/zfl9/ipt2socks) | Transparent TCP → SOCKS5 (IPv4+IPv6) |
| [coredns/coredns](https://github.com/coredns/coredns) | DNS server |
| [teleproxy/teleproxy](https://github.com/teleproxy/teleproxy) | Optional MTProxy (MTProto TCP); image `ghcr.io/teleproxy/teleproxy` — [MTPROXY.md](./docs/MTPROXY.md) |
| [Amnezia](https://amnezia.org/downloads) | Client apps |
| [Amnezia Docs](https://docs.amnezia.org) | Documentation |
