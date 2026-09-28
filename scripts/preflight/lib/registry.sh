#!/usr/bin/env bash
# Phase registry and probe constants (single source of truth for phases 6–11).

_REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/host-artifacts.sh
source "${_REGISTRY_DIR}/../../lib/host-artifacts.sh"
unset _REGISTRY_DIR

# Phase 6 — host systemd units: unit → fix hint (from HOST_DEPLOY_UNITS).
PREFLIGHT_HOST_UNITS=()
for _host_unit in "${HOST_DEPLOY_UNITS[@]}"; do
  PREFLIGHT_HOST_UNITS+=("${_host_unit}|sudo make deploy-host")
done
unset _host_unit

PREFLIGHT_HOST_LEGACY_UNITS=("${HOST_LEGACY_UNIT_HINTS[@]}")

# Phase 9 — base stack containers (compose container_name). MTProxy is phase 11.
PREFLIGHT_STACK_CONTAINERS=(
  vpn-xray
  vpn-amneziawg
  vpn-coredns
)

# Phase 8 — render-config outputs under .data/build/
PREFLIGHT_BUILD_ARTIFACTS=(
  docker-compose.yml
  awg0.conf
  config.json
  ipt2socks-amneziawg-v4.sh
  ipt2socks-amneziawg-v6.sh
  udp-relay-run.sh
  ipt2socks-coredns.sh
  ipt2socks-ports.env
  Corefile
)
