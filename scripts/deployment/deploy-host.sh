#!/usr/bin/env bash
# Host-only bootstrap for amnezia-reality-kit (IN container stack).
#
# Layers (see docs/ARCHITECTURE.md § Host bootstrap):
#   L0 BASE_HOST       — always (ip_forward, conntrack, firewall); no flag
#   L1 AWG_KMOD_HOST   — ENABLE_AWG_KMOD_HOST
#   L2 STACK_AUTOBOOT  — ENABLE_STACK_AUTOBOOT
#
# Stack deploy: make create-data && make first-start
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/host-artifacts.sh
source "${SCRIPT_DIR}/../lib/host-artifacts.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/host-base.sh
source "${SCRIPT_DIR}/../lib/host-base.sh"
# shellcheck source=../lib/host-autoboot.sh
source "${SCRIPT_DIR}/../lib/host-autoboot.sh"
# shellcheck source=../lib/host-awg-kmod.sh
source "${SCRIPT_DIR}/../lib/host-awg-kmod.sh"

if [[ "${EUID}" -ne 0 ]]; then
  log_error "Run as root: sudo $0"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  log_error "Docker is not installed. Run scripts/setup/install-docker.sh first."
  exit 1
fi

if ! docker compose version &>/dev/null; then
  log_error "Docker Compose plugin is not installed."
  exit 1
fi

log_info "Host bootstrap for IN stack at ${REPO_ROOT}"
echo ""

# ── L0 BASE_HOST (always; no operator flag) ─────────────────────────────────
host_l0_install "${REPO_ROOT}"
log_info "L0 BASE_HOST complete (forward, conntrack, ${HOST_FIREWALL_UNIT})."
echo ""

# ── L2 STACK_AUTOBOOT ───────────────────────────────────────────────────────
if ! _val="$(parse_bool "${ENABLE_STACK_AUTOBOOT:-}" 1)"; then
  log_error "ENABLE_STACK_AUTOBOOT='${ENABLE_STACK_AUTOBOOT:-}' is not a boolean."
  exit 1
fi
ENABLE_STACK_AUTOBOOT="${_val}"
unset _val

log_info "Stack autoboot (${HOST_BOOT_UNIT}): $([[ "${ENABLE_STACK_AUTOBOOT}" == "1" ]] && echo enabled || echo DISABLED)"
echo ""

if [[ "${ENABLE_STACK_AUTOBOOT}" == "0" ]]; then
  host_l2_teardown
  log_info "L2 STACK_AUTOBOOT disabled (L0 unchanged)."
  echo ""
else
  host_l2_install "${REPO_ROOT}" "${SCRIPT_DIR}"
  log_info "L2 STACK_AUTOBOOT complete."
  echo ""
fi

# ── L1 AWG_KMOD_HOST ───────────────────────────────────────────────────────
if [[ -n "${ENABLE_AMNEZIAWG:-}" ]]; then
  log_error "ENABLE_AMNEZIAWG is not a deploy-host flag."
  log_error "Use ENABLE_AWG_KMOD_HOST for L1 kernel module (sudo ENABLE_AWG_KMOD_HOST=0 make deploy-host)."
  log_error "Runtime boot AWG gate in .data/.env is separate — see ensure-boot.sh."
  exit 1
fi

if ! _val="$(parse_bool "${ENABLE_AWG_KMOD_HOST:-}" 1)"; then
  log_error "ENABLE_AWG_KMOD_HOST='${ENABLE_AWG_KMOD_HOST:-}' is not a boolean."
  exit 1
fi
ENABLE_AWG_KMOD_HOST="${_val}"
unset _val

log_info "AWG kernel module (L1): $([[ "${ENABLE_AWG_KMOD_HOST}" == "1" ]] && echo enabled || echo DISABLED)"

if [[ "${ENABLE_STACK_AUTOBOOT}" == "1" && "${ENABLE_AWG_KMOD_HOST}" == "0" ]]; then
  log_warn "L2 autoboot enabled without L1 kmod (ENABLE_AWG_KMOD_HOST=0) — xray-only IN or load kmod manually."
fi
echo ""

if [[ "${ENABLE_AWG_KMOD_HOST}" == "0" ]]; then
  host_l1_teardown || exit 1
  log_info "L1 AWG_KMOD_HOST disabled (artifacts removed if present)."
else
  host_l1_install
  log_info "L1 AWG_KMOD_HOST complete."
fi

echo ""
log_info "Host bootstrap complete."
log_info "Next: make create-data [COPY_FROM=…] && make first-start && make check"
