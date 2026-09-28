# Client management

Add, remove, and list VPN users by protocol.

## AmneziaWG (tunnel clients)

```bash
./awg/add.sh <name>
./awg/remove.sh <name>
./awg/list.sh
```

Or from repo root:

```bash
make awg-client-list
make awg-client-add    NAME=<name>
make awg-client-remove                 # pick # from list (TTY)
make awg-client-remove NAME=<name>
make awg-client-remove NUM=<#>
```

Exports: `.data/clients_awg/<name>.conf`

## REALITY / VLESS (inbound clients)

```bash
./reality/add.sh <name>
./reality/remove.sh <name>
```

Exports: `.data/clients_xray/<name>.vless`

> **Note:** REALITY client scripts are path-migrated but not yet tested on production.
> See [ISSUES.md](../../ISSUES.md).

## MTProxy (Telegram)

```bash
make mtproxy-export NAME=<name>   # saves link + runs ingress smoke
make mtproxy-list
make verify-mtproxy-smoke         # same checks without writing a file
make mtproxy-rotate-secret
```

Exports: `.data/clients_mtproxy/<name>.txt`

See [MTPROXY.md](../../docs/MTPROXY.md) for `standalone` vs `sni` profiles.
