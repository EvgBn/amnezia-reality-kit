.PHONY: help extract-env network-plan build build-diff create-data route route-remove kmod-remove host-remove remove-full first-start check check-watch check-host check-deploy deploy-host mtu \
        start up down ps logs images images-ipt2socks images-pull-upstream recreate refresh-full validate \
        unit-test unit-test-shell unit-test-integration test-go test-one test verify-inbound verify-mtproxy verify-mtproxy-smoke verify-sni-443 regression-443 \
        smoke-voice-chat voice-smoke-report voice-path-probe voice-fail-snapshot diagnose-udp-path diagnose-udp-path-watch voice-gate \
        awg-client-add awg-client-remove awg-client-list mtproxy-export mtproxy-list mtproxy-rotate-secret \
        mtproxy-link mtproxy-link-list

.DEFAULT_GOAL := help

# ── First-time setup ──────────────────────────────────────────────────────────
# COPY_FROM: existing .data/.env to reuse OUT exit settings (optional)
AWG_IMAGE ?=
COPY_FROM ?=

create-data:
	@chmod +x scripts/setup/bootstrap-data.sh scripts/maintenance/vpn-awg-route.sh
	COPY_FROM="$(COPY_FROM)" AWG_IMAGE="$(AWG_IMAGE)" ./scripts/setup/bootstrap-data.sh
	./scripts/setup/render-config.sh --bootstrap

route:
	@chmod +x scripts/maintenance/vpn-awg-route.sh
	./scripts/maintenance/vpn-awg-route.sh apply

route-remove:
	@chmod +x scripts/maintenance/vpn-awg-route.sh
	sudo ./scripts/maintenance/vpn-awg-route.sh remove

route-status:
	@chmod +x scripts/maintenance/vpn-awg-route.sh
	./scripts/maintenance/vpn-awg-route.sh status

# macOS only — path MTU probe for AWG client tuning
MTU_HOST ?=
mtu:
	@chmod +x scripts/maintenance/mtu.sh
	@if [ -z '$(MTU_HOST)' ]; then \
		echo 'Usage: make mtu HOST=<server-ip-or-hostname>' >&2; \
		exit 1; \
	fi
	./scripts/maintenance/mtu.sh '$(MTU_HOST)'

# First full stack bring-up after create-data (validate → build → images → start)
first-start: validate build images start
	@echo "Stack up. Verify: make check && make ps"
	@echo "Add AWG client: make awg-client-add NAME=<name>"
	@echo "After .env or git changes use: make refresh-full (not first-start)"

# make check [N] [N-M]  — extra goals passed as phase args (e.g. make check 7)
ifeq (check,$(filter check,$(MAKECMDGOALS)))
CHECK_RUN_ARGS := $(filter-out check,$(MAKECMDGOALS))
ifneq ($(strip $(CHECK_RUN_ARGS)),)
$(CHECK_RUN_ARGS):
	@:
endif
endif

# make check-watch [N]  — same phase args; INTERVAL=seconds (default 30)
ifeq (check-watch,$(filter check-watch,$(MAKECMDGOALS)))
CHECK_WATCH_ARGS := $(filter-out check-watch,$(MAKECMDGOALS))
ifneq ($(strip $(CHECK_WATCH_ARGS)),)
$(CHECK_WATCH_ARGS):
	@:
endif
endif

CHECK_WATCH_INTERVAL ?= 30

check:
	@chmod +x scripts/deployment/check.sh scripts/preflight/run.sh scripts/preflight/phases/*.sh scripts/lib/stack-state.sh
	CHECK_STRICT="$(CHECK_STRICT)" ./scripts/deployment/check.sh $(if $(CHECK_RUN_ARGS),$(CHECK_RUN_ARGS),)

check-watch:
	@chmod +x scripts/deployment/check-watch.sh scripts/deployment/check.sh scripts/preflight/run.sh scripts/preflight/phases/*.sh scripts/lib/stack-state.sh
	CHECK_STRICT="$(CHECK_STRICT)" CHECK_WATCH_INTERVAL="$(CHECK_WATCH_INTERVAL)" ./scripts/deployment/check-watch.sh $(if $(CHECK_WATCH_ARGS),$(CHECK_WATCH_ARGS),)

check-host:
	@chmod +x scripts/deployment/check.sh scripts/preflight/run.sh scripts/preflight/phases/*.sh scripts/lib/stack-state.sh
	CHECK_STRICT="$(CHECK_STRICT)" ./scripts/preflight/run.sh --host $(if $(CHECK_STRICT),--strict,)

check-deploy:
	@chmod +x scripts/deployment/check.sh scripts/preflight/run.sh scripts/preflight/phases/*.sh scripts/lib/stack-state.sh
	CHECK_STRICT="$(CHECK_STRICT)" ./scripts/preflight/run.sh --deploy $(if $(CHECK_STRICT),--strict,)

deploy-host:
	@chmod +x scripts/deployment/deploy-host.sh \
		scripts/deployment/install-ensure-wrapper.sh \
		scripts/deployment/vpn-stack-ensure.sh \
		scripts/lib/host-base.sh \
		scripts/lib/host-autoboot.sh \
		scripts/lib/host-awg-kmod.sh \
		scripts/maintenance/rebuild-amneziawg.sh \
		scripts/maintenance/vpn-stack-boot.sh \
		scripts/maintenance/vpn-awg-route.sh
	sudo ./scripts/deployment/deploy-host.sh

kmod-remove:
	@chmod +x scripts/maintenance/kmod-remove.sh
	sudo ./scripts/maintenance/kmod-remove.sh

host-remove:
	@chmod +x scripts/maintenance/remove-host.sh \
		scripts/maintenance/kmod-remove.sh
	sudo ./scripts/maintenance/remove-host.sh

# Full teardown: stack down + host artifacts. Keeps .data/ (secrets, clients, build).
remove-full: down
	@docker network rm vpn 2>/dev/null || true
	@$(MAKE) host-remove
	@echo "remove-full done (.data/ kept). Redeploy: sudo make deploy-host && make refresh-full"

# ── AWG client management ─────────────────────────────────────────────────────
AWG_CLIENTS := ./scripts/clients/awg

awg-client-add:
	@if [ -z '$(NAME)' ]; then \
		echo 'Error: missing client name.' >&2; \
		echo '  You ran: make awg-client-add' >&2; \
		if [ -t 2 ]; then \
			printf '  Need:    make awg-client-add \033[32mNAME=<client>\033[0m\n' >&2; \
		else \
			echo '  Need:    make awg-client-add NAME=<client>' >&2; \
		fi; \
		echo '' >&2; \
		echo 'Example:' >&2; \
		echo '  make awg-client-add NAME=phone' >&2; \
		echo '' >&2; \
		echo 'See existing clients: make awg-client-list' >&2; \
		exit 1; \
	fi
	$(AWG_CLIENTS)/add.sh '$(NAME)'

awg-client-remove:
	@if [ -n '$(NAME)' ]; then \
		$(AWG_CLIENTS)/remove.sh '$(NAME)'; \
	elif [ -n '$(NUM)' ]; then \
		$(AWG_CLIENTS)/remove.sh --num '$(NUM)'; \
	elif [ -t 0 ] && [ -e /dev/tty ]; then \
		$(AWG_CLIENTS)/remove.sh --interactive; \
	else \
		echo 'Error: specify who to remove.' >&2; \
		echo '' >&2; \
		echo '  make awg-client-remove NAME=<client>   # by name' >&2; \
		echo '  make awg-client-remove NUM=<#>         # by row # from list' >&2; \
		echo '  make awg-client-remove                  # interactive (TTY only)' >&2; \
		echo '' >&2; \
		echo 'Numbered list: make awg-client-list' >&2; \
		exit 1; \
	fi

awg-client-list:
	$(AWG_CLIENTS)/list.sh

# ── MTProxy (Telegram) ────────────────────────────────────────────────────────
MTPROXY_CLIENTS := ./scripts/clients/mtproxy

mtproxy-export:
	@if [ -z '$(NAME)' ]; then \
		echo 'Error: missing export name.' >&2; \
		echo '  make mtproxy-export NAME=<name>' >&2; \
		echo '  make mtproxy-list' >&2; \
		exit 1; \
	fi
	@chmod +x $(MTPROXY_CLIENTS)/export.sh
	FORCE='$(FORCE)' $(MTPROXY_CLIENTS)/export.sh '$(NAME)'

mtproxy-list:
	@chmod +x $(MTPROXY_CLIENTS)/list.sh
	$(MTPROXY_CLIENTS)/list.sh

mtproxy-rotate-secret:
	@chmod +x $(MTPROXY_CLIENTS)/rotate-secret.sh
	$(MTPROXY_CLIENTS)/rotate-secret.sh

# Deprecated aliases (stage 5 naming)
mtproxy-link:
	@echo '[deprecated] use: make mtproxy-export NAME=<name>' >&2
	@$(MAKE) mtproxy-export NAME='$(NAME)' FORCE='$(FORCE)'

mtproxy-link-list:
	@echo '[deprecated] use: make mtproxy-list' >&2
	@$(MAKE) mtproxy-list

# ── Config build (.data/build/) ───────────────────────────────────────────────
extract-env:
	./scripts/setup/render-config.sh --extract-env

build:
	./scripts/setup/render-config.sh

build-diff:
	./scripts/setup/render-config.sh --diff

network-plan:
	@bash -c 'set -euo pipefail; \
	. ./scripts/lib/docker-network-plan.sh; \
	docker_network_plan_resolve "$${PWD}/.data/.env"; \
	echo "DOCKER_NETWORK_SUBNET_IPV4=$${DOCKER_NETWORK_SUBNET_IPV4}"; \
	echo "DOCKER_NETWORK_GATEWAY_IPV4=$${DOCKER_NETWORK_GATEWAY_IPV4}"; \
	echo "VPN_DOCKER_SUBNET_CIDR=$${VPN_DOCKER_SUBNET_CIDR}"; \
	echo "COREDNS_IP=$${COREDNS_IP}  AMNEZIAWG_IP=$${AMNEZIAWG_IP}  XRAY_IP=$${XRAY_IP}"; \
	echo "COREDNS_IPV6=$${COREDNS_IPV6}  AMNEZIAWG_IPV6=$${AMNEZIAWG_IPV6}  XRAY_IPV6=$${XRAY_IPV6}"'

up:
	./scripts/deployment/up.sh up -d

# Start stack for daily use: containers + host AWG route (prefer over bare make up)
start:
	@chmod +x scripts/lib/stack-state.sh scripts/deployment/up.sh scripts/maintenance/vpn-awg-route.sh
	@./scripts/lib/stack-state.sh clear
	@$(MAKE) up
	@$(MAKE) route
	@echo "Stack started (containers + host route). Verify: make check"

down:
	@chmod +x scripts/deployment/up.sh scripts/lib/stack-state.sh
	./scripts/deployment/up.sh down

recreate:
	./scripts/deployment/up.sh up -d --force-recreate

# Full stack refresh after git pull/checkout, .env edit, or image rebuild.
# Do NOT use bare make start or docker restart single containers (stale xray ↔ udp-relay SOCKS UDP).
refresh-full: down build images recreate start
	@echo "Stack refreshed (down + build + images + recreate + start). Verify: make check"

ps:
	./scripts/deployment/up.sh ps

logs:
	./scripts/deployment/up.sh logs --tail=50

images-ipt2socks:
	docker build -t zfl9/ipt2socks:latest containers/ipt2socks

images-pull-upstream:
	@chmod +x scripts/setup/images-pull-upstream.sh
	./scripts/setup/images-pull-upstream.sh

images: images-ipt2socks images-pull-upstream
	./scripts/deployment/up.sh build

validate:
	./scripts/deployment/up.sh config --quiet

TEST_MATCH ?= test_*.sh
TEST_RUNNER := ./tests/lib/run-tests.sh

test-go:
	@if command -v go >/dev/null; then \
	  cd containers/amneziawg && CGO_ENABLED=0 go test -count=1 ./internal/udprelay ./tests/udprelay/...; \
	else \
	  echo "[test-go] SKIP: install go 1.22+ or use CI"; \
	fi

unit-test-shell:
	@chmod +x $(TEST_RUNNER)
	@$(TEST_RUNNER) tests/unit tests/guards

unit-test-integration:
	@chmod +x $(TEST_RUNNER)
	@$(TEST_RUNNER) tests/integration

unit-test: unit-test-shell unit-test-integration test-go
	@echo "All unit tests passed."

test-one:
	@test -n "$(TEST)" || { echo "Usage: make test-one TEST=mtproxy_sni"; exit 1; }
	@f=$$(find tests/unit tests/integration tests/guards -name "test_$(TEST).sh" 2>/dev/null | head -1); \
	test -n "$$f" || { echo "not found: test_$(TEST).sh"; exit 1; }; \
	echo "==> $$f"; bash "$$f"

test: unit-test

verify-inbound:
	@chmod +x scripts/maintenance/verify-inbound-config.sh
	./scripts/maintenance/verify-inbound-config.sh

verify-mtproxy:
	@chmod +x scripts/maintenance/verify-mtproxy-config.sh
	./scripts/maintenance/verify-mtproxy-config.sh

verify-mtproxy-smoke:
	@chmod +x scripts/maintenance/verify-mtproxy-smoke.sh scripts/lib/mtproxy-smoke.sh
	./scripts/maintenance/verify-mtproxy-smoke.sh

verify-sni-443:
	@chmod +x scripts/maintenance/verify-sni-443.sh scripts/maintenance/verify-inbound-config.sh scripts/maintenance/verify-mtproxy-config.sh
	./scripts/maintenance/verify-sni-443.sh

# Phase 5 regression after changing ENABLE_XRAY_INBOUND / ports (see docs/PORT-443.md)
regression-443: verify-inbound verify-mtproxy verify-mtproxy-smoke verify-sni-443
	@chmod +x scripts/deployment/check.sh scripts/preflight/run.sh scripts/preflight/phases/*.sh
	./scripts/preflight/run.sh --phases 7-11
	@echo "Manual: AWG client ping/curl; if website on :443 — curl https://your-domain/"

# Voice smoke (Telegram group voice on test phone, VPN on SMOKE_CLIENT_IP):
#   make diagnose-udp-path              — static L0–L4 only (NO phone call)
#   make voice-gate [WATCH=30]          — deploy gate: voice ACTIVE during WATCH seconds
#   make voice-smoke-report [SMOKE_DURATION=30]  — full metrics + logs (same timing as voice-gate)
#   NONINTERACTIVE=1 make voice-gate  — skip call-state prompt (CI/automation only)
# Prompts every run: already in call / will join / abort.
WATCH ?= 30
PREP ?= 5

diagnose-udp-path:
	@chmod +x scripts/smoke/diagnose-udp-path.sh scripts/lib/voice-smoke-help.sh scripts/lib/voice-smoke-metrics.sh
	./scripts/smoke/diagnose-udp-path.sh

diagnose-udp-path-watch: voice-gate

voice-gate:
	@chmod +x scripts/smoke/diagnose-udp-path.sh scripts/lib/voice-smoke-help.sh scripts/lib/voice-smoke-metrics.sh
	NONINTERACTIVE=$(NONINTERACTIVE) PREP=$(PREP) ./scripts/smoke/diagnose-udp-path.sh --watch "$(WATCH)"

smoke-voice-chat:
	@chmod +x scripts/smoke/smoke-voice-chat.sh scripts/lib/voice-smoke-help.sh scripts/lib/voice-smoke-metrics.sh
	NONINTERACTIVE=$(NONINTERACTIVE) PREP=$(PREP) ./scripts/smoke/smoke-voice-chat.sh

voice-smoke-report: smoke-voice-chat

voice-path-probe:
	@chmod +x scripts/smoke/voice-path-probe.sh
	./scripts/smoke/voice-path-probe.sh

voice-fail-snapshot:
	@chmod +x scripts/smoke/voice-fail-snapshot.sh scripts/smoke/voice-path-probe.sh
	./scripts/smoke/voice-fail-snapshot.sh

# ── Help ─────────────────────────────────────────────────────────────────────
help:
	@h() { \
	  if [ -n "$$1" ]; then _pfx='sudo '; else _pfx='     '; fi; \
	  printf '  %s%-42s %s\n' "$$_pfx" "$$2" "$$3"; \
	}; \
	echo 'AmneziaWG + Xray REALITY — operator commands (run from repo root)'; \
	echo 'Guides: docs/DEPLOYMENT.md  docs/CHECK.md  docs/FAQ.md'; \
	echo ''; \
	echo '━━━ New server — do these once, in order ━━━'; \
	echo '  0. Install Docker if needed:  sudo ./scripts/setup/install-docker.sh'; \
	echo '  1. sudo make deploy-host'; \
	echo '     Once per machine: kernel module, firewall, boot unit, /etc/vpn-bridge/env.'; \
	echo '     Run BEFORE make create-data on a fresh VPS.'; \
	echo '  2. make check-host'; \
	echo '     Host-only audit (phases 1–5). Fix every FAIL before continuing.'; \
	echo '  3. make create-data [COPY_FROM=/path/to/old/.data/.env]'; \
	echo '     Creates .data/ with NEW server secrets. COPY_FROM = OUT exit + network only.'; \
	echo '  4. make first-start'; \
	echo '     First full deploy on this clone: validate → build → images → start.'; \
	echo '  5. make awg-client-add NAME=phone'; \
	echo '     New VPN profile → import .data/clients_awg/phone.conf into Amnezia app.'; \
	echo '  6. Connect phone to VPN, then: make check'; \
	echo '     Full audit (phases 1–9). WARN is OK for learning; fix FAIL.'; \
	echo ''; \
	echo '━━━ Start / stop (every day) ━━━'; \
	echo '  Prefer make start over make up — start also adds the host route.'; \
	echo '  make down keeps the stack stopped across reboot (writes .data/.stack-stopped).'; \
	h '' 'make start' 'Start stack + host route; clears .stack-stopped (survives reboot)'; \
	h '' 'make down' 'Stop all vpn-* containers; stays down after reboot until make start'; \
	h '' 'make up' 'Containers only, this session — does NOT clear .stack-stopped'; \
	h '' 'make ps' 'Container status'; \
	h '' 'make logs' 'Last 50 log lines per service'; \
	echo ''; \
	echo '━━━ After git pull, .env edit, or image rebuild ━━━'; \
	h '' 'make refresh-full' 'Safe full cycle: down → build → images → recreate → start'; \
	echo '  Do not docker-restart a single container — breaks Telegram voice (stale UDP relay).'; \
	echo ''; \
	echo '━━━ Health checks ━━━'; \
	h '' 'make check [N]' 'Preflight phases 1–11 (or one phase, e.g. make check 11)'; \
	h '' 'make check-host' 'Phases 1–5 — host + Docker (no .data/ required)'; \
	h '' 'make check-deploy' 'Phases 6–10 — after make create-data'; \
	echo '  CHECK_STRICT=1 make check  — treat WARN as FAIL (staging / CI gate)'; \
	h '' 'make check-watch [N]' 'Repeat check every INTERVAL=30 seconds'; \
	h '' 'make verify-inbound' 'Xray inbound ports vs .env (see docs/PORT-443.md)'; \
	h '' 'make verify-mtproxy' 'MTProxy ports vs .env (see docs/MTPROXY.md)'; \
	h '' 'make verify-mtproxy-smoke' 'MTProxy link + TCP + stats (stack must be up)'; \
	h '' 'make verify-sni-443' 'SNI profile gate (skipped when MTPROXY_MODE=standalone)'; \
	h '' 'make regression-443' 'verify-inbound + verify-mtproxy + verify-mtproxy-smoke + verify-sni-443 + check phases 7–11'; \
	echo ''; \
	echo '━━━ AWG clients (phones on VPN) ━━━'; \
	h '' 'make awg-client-list' 'Peers + tunnel IPs'; \
	h '' 'make awg-client-add NAME=<name>' 'New .conf in .data/clients_awg/'; \
	h '' 'make awg-client-remove' 'Interactive remove (needs TTY)'; \
	h '' 'make awg-client-remove NAME=<name>' 'Remove by name'; \
	h '' 'make awg-client-remove NUM=<#>' 'Remove by row from list'; \
	echo ''; \
	echo '━━━ MTProxy (Telegram) ━━━'; \
	h '' 'make mtproxy-list' 'Exported tg:// links in .data/clients_mtproxy/'; \
	h '' 'make mtproxy-export NAME=<name>' 'Export current link + ingress smoke test'; \
	h '' 'make mtproxy-rotate-secret' 'New MTPROXY_SECRET in .env → refresh-full'; \
	echo ''; \
	echo '━━━ Host teardown (decommission / move clone) ━━━'; \
	h '' 'make remove-full' 'down → docker network vpn → host-remove (.data/ kept)'; \
	h sudo 'make host-remove' 'Host only: route, firewall, wrapper, kmod, env (stack must be down)'; \
	h sudo 'make kmod-remove' 'Kernel module + boot unit only (subset of host-remove)'; \
	h '' 'make route-remove' 'AWG host route only'; \
	h '' 'make down' 'Stop containers only (before host-remove if not using remove-full)'; \
	echo ''; \
	echo '━━━ Config & build ━━━'; \
	h '' 'make create-data' 'Create .data/ with NEW server secrets (first clone; not stack start)'; \
	h '' 'make first-start' 'First full deploy: validate → build → images → start (after create-data)'; \
	h '' 'make build' 'Write .data/build/ from templates + .env (do not edit build/ by hand)'; \
	h '' 'make build-diff' 'Preview build changes without writing'; \
	h '' 'make images' 'Build Docker images (amneziawg, coredns, ipt2socks)'; \
	h '' 'make validate' 'Check docker-compose.yml syntax'; \
	h '' 'make route' 'Apply host AWG route (included in make start)'; \
	h '' 'make route-status' 'Show current AWG route'; \
	h '' 'make recreate' 'Force-recreate containers (prefer refresh-full)'; \
	h '' 'make extract-env' 'Rebuild .env from existing build output'; \
	h '' 'make network-plan' 'Show derived docker bridge IPs from .data/.env (read-only)'; \
	h '' 'make mtu HOST=<ip>' 'macOS only: probe path MTU for AWG client tuning'; \
	echo ''; \
	echo '━━━ Developers / CI (not production deploy) ━━━'; \
	h '' 'make test' 'Full test suite: unit + guards + integration + go'; \
	h '' 'make unit-test-shell' 'Fast shell tests (tests/unit + tests/guards)'; \
	h '' 'make unit-test-integration' 'Integration tests (render-config, host-remove)'; \
	h '' 'make test-go' 'Go tests for udp-relay'; \
	h '' 'make test-one TEST=name' 'Run a single test file (e.g. TEST=mtproxy_sni)'; \
	echo ''; \
	echo '━━━ Telegram voice smoke (optional) ━━━'; \
	echo '  Phone on VPN, stack up (make start), then:'; \
	h '' 'make diagnose-udp-path' 'Static L0–L4 path check — no call needed'; \
	h '' 'make voice-gate [WATCH=30]' 'Live gate during a test call'; \
	h '' 'make voice-smoke-report' 'Full metrics + logs (alias: smoke-voice-chat)'; \
	h '' 'make voice-path-probe' 'Diagnose after voice-gate FAIL'; \
	h '' 'make voice-fail-snapshot' 'Capture state before refresh-full'; \
	echo '  Automation: NONINTERACTIVE=1 SMOKE_CLIENT_IP=10.8.0.x make voice-gate'
