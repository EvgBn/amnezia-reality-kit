# Preflight (`make check`)

Read-only probes before deploy. **Does not modify the system.**

## Layout

```text
scripts/preflight/
├── run.sh                 # orchestrator (CLI, phase selection)
├── README.md
├── lib/
│   ├── emit.sh            # OK/WARN/FAIL output, summary
│   ├── env.sh             # .env groups: OUT_*, REALITY_*, core
│   ├── registry.sh        # units, containers, build artifacts
│   ├── probes.sh          # docker, ports, systemd (low-level)
│   ├── network.sh         # phase 7: ports, AWG route
│   ├── stack.sh           # phase 9: health, route ↔ bridge
│   ├── mtproxy.sh         # phase 11: optional Telegram MTProxy
│   └── out.sh             # phase 10: OUT ping + egress
└── phases/
    ├── 01-repo.sh … 05-host-sysctl.sh   # host bootstrap
    ├── 06-host-svc.sh                   # HOST SVC
    ├── 07-network.sh                    # NETWORK
    ├── 08-data.sh                       # DATA
    ├── 09-stack.sh                      # STACK (core vpn-*)
    ├── 10-out.sh                        # OUT path
    └── 11-mtproxy.sh                    # MTPROXY (optional)
```

## Phase map

| Phase | Slug | Module | Scope flag |
|-------|------|--------|------------|
| 6 | HOST SVC | `06-host-svc.sh` + `registry.sh` | `--deploy` |
| 7 | NETWORK | `07-network.sh` + `network.sh` | `--deploy` |
| 8 | DATA | `08-data.sh` + `env.sh` + `registry.sh` | `--deploy` |
| 9 | STACK | `09-stack.sh` + `stack.sh` + `registry.sh` | `--deploy` |
| 10 | OUT | `10-out.sh` + `out.sh` | `--deploy` |
| 11 | MTPROXY | `11-mtproxy.sh` + `mtproxy.sh` | `--deploy` (SKIP if `ENABLE_MTPROXY=0`) |

## Commands

```bash
make check              # all 11 phases
make check 11           # MTProxy only
make start              # fix route WARN: up + route
make check-host         # phases 1–5 (new machine)
make check-deploy       # phases 6–11 (after deploy-host / make create-data)
./scripts/preflight/run.sh --deploy -v
./scripts/preflight/run.sh --phases 9-11
```

Full reference: [docs/CHECK.md](../../docs/CHECK.md)
