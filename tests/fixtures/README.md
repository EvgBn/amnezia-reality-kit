# Test fixtures

Shared mocks, static data, and bootstrap helpers for `tests/unit`, `tests/integration`, and `tests/guards`.

See also: [`manifest.yaml`](manifest.yaml) (machine-readable catalog).

## Layout

| Path | Role |
|------|------|
| **`common/`** | Composable CLI mocks (docker, awg-docker, curl, ss, openssl) |
| **`data/`** | Static nginx maps, compose/json snippets, `.env` fragments |
| **`host-network/`** | Stateful iptables/ip/systemctl mocks for host teardown |
| **`ensure-boot/`** | ensure-boot.sh injection stubs |
| **`preflight-out/`** | Thin wrappers → `common/` for phase 10 OUT |
| **`docker-compose-markers.yml.tmpl`** | Minimal compose template for `render_compose` tests |

## Bootstrap (`tests/lib/fixture-env.sh`)

| Helper | Purpose |
|--------|---------|
| `fixture_use_docker_mock` | `common/docker-mock.sh` on PATH + `export -f docker` |
| `fixture_use_awg_docker_mock` | AWG client scripts (`exec awg pubkey`, genkey) |
| `fixture_use_ss_mock` | `ss` on PATH for preflight port probes |
| `fixture_use_curl_mock` | `curl` on PATH |
| `fixture_use_openssl_mock` | `openssl` on PATH for SNI TLS probes |
| `fixture_use_out_mocks` | `PREFLIGHT_OUT_DOCKER` / `PREFLIGHT_OUT_CURL` |
| `fixture_use_docker_trace_mock <log>` | docker mock that logs all commands and exits 0 |
| `fixture_load_case <ns> <case> [dest]` | Copy `data/cases/<ns>/<case>/` into sandbox |
| `fixture_host_network_sandbox <tmpdir>` | Host-network unit sandbox (iptables/ip/systemctl) |
| `fixture_host_network_sandbox_integration <tmpdir>` | Extended sandbox for host-remove integration |
| `fixture_copy_data <rel> <dest>` | Copy from `fixtures/data/` |
| `fixture_teardown` | Remove temp PATH bins from helpers |

## `common/docker-mock.sh`

| Env var | Purpose |
|---------|---------|
| `DOCKER_MOCK_PS` | `docker ps` output (newline-separated names) |
| `DOCKER_MOCK_HEALTH` | Health.Status inspect (default: `healthy`) |
| `DOCKER_MOCK_EXTERNAL_PORT` | `EXTERNAL_PORT=` in Config.Env inspect |
| `DOCKER_MOCK_LOGS_FILE` | `docker logs` body from file |
| `DOCKER_MOCK_IMAGE_INSPECT_RC` | `docker image inspect` exit code (default: 0) |
| `DOCKER_MOCK_PING_RC` / `OUT_MOCK_PING_RC` | `docker exec … ping` exit code |
| `DOCKER_MOCK_COMMAND_LOG_FILE` | Append trace lines (`docker …`) |
| `DOCKER_MOCK_TRACE_ONLY` | `1` → log any command and exit 0 |

**CLI:** `ps`, `inspect`, `image inspect`, `logs`, `exec` (ping)

## `common/awg-docker-mock.sh`

| Env var | Purpose |
|---------|---------|
| `DOCKER_MOCK_AWG_PUBKEY_MAP` | `PRIVKEY=PUBKEY` lines for `awg pubkey` |
| `DOCKER_MOCK_AWG_DEFAULT_PUB` | Fallback pubkey (default: `PUB_DROP`) |
| `DOCKER_MOCK_AWG_GENKEY_PRIV` / `_PUB` | `sh -c '…genkey…'` output |

## `common/ss-mock.sh`

| Env var | Purpose |
|---------|---------|
| `SS_MOCK_PORTS` | Comma-separated `tcp:8444`, `udp:51820`, … |
| `SS_MOCK_PROCESS_tcp_8444` | Process name for `-p` output |

## `data/`

| Subdir | Examples |
|--------|----------|
| `env/` | `disabled-mtproxy.env`, `sni-mode.env`, `enabled-standalone.env` |
| `nginx/` | `sni-map-good.conf`, `sni-map-bad.conf` |
| `compose/` | `teleproxy-standalone.yml`, `xray-socks-only.yml` |
| `json/` | `xray-socks-only.json`, `xray-inbound-sni.json` |
| `awg/` | `awg0-with-peer.conf` |
| `cases/` | Named matrix dirs (`verify-inbound/*`) |
| `integration/` | `stack-env-gw.env` |
| `preflight/` | Golden snippets for phases 01–09 (seed) |

## Contract tests

`tests/unit/test_fixtures_contract.sh` smokes every mock, validates `manifest.yaml` paths (bidirectional), consumer test files, and `# contract:` headers.

## Legacy domain packages

`host-network/docker-mock.sh` and `preflight-out/*.sh` delegate to `common/`. Domain-specific stateful mocks (`iptables-mock.sh`, `ensure-compose-mock.sh`, …) remain in place.
