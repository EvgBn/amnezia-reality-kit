#!/usr/bin/env bash
# Preflight orchestrator — read-only host + .data/ + stack audit.
set -uo pipefail

PREFLIGHT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${PREFLIGHT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${PREFLIGHT_DIR}/../lib/common.sh"

VERBOSE=0
JSON=0
SCOPE="all"
PREFLIGHT_STRICT="${CHECK_STRICT:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [N]

  Read-only preflight probes. Exit 0 when no blocking FAIL.

  -v              Print OK/SKIP lines (default: WARN/FAIL only)
  --json           Machine-readable output
  --strict         Treat WARN as FAIL (same as CHECK_STRICT=1)
  --host           Phases 1–5 only (repo, OS, docker, kernel, sysctl)
  --deploy         Phases 6–11 only (host svc, network, data, stack, OUT, optional MTProxy)
  N                Single phase only (1–11), e.g. ./run.sh 7
  --phases N[-M]   Phase range (e.g. 1-5, 6-11, 11-11)
  -h, --help       This help

Layout: scripts/preflight/phases/NN-name.sh
EOF
}

preflight_die_phase() {
  local msg="$1"
  if [[ -t 2 ]]; then
    printf '%s%s%s\n' $'\033[1;31m' "${msg}" $'\033[0m' >&2
  else
    printf '%s\n' "${msg}" >&2
  fi
  exit 1
}

preflight_validate_phase_num() {
  local n="$1"
  [[ "${n}" =~ ^[0-9]+$ ]] || preflight_die_phase "[check] phase must be 1–11 (got: ${n})"
  if (( n < 1 || n > 11 )); then
    preflight_die_phase "[check] phase must be 1–11 (got: ${n})"
  fi
}

parse_phase_range() {
  local spec="$1"
  local from to
  if [[ "${spec}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    from="${BASH_REMATCH[1]}"
    to="${BASH_REMATCH[2]}"
  elif [[ "${spec}" =~ ^([0-9]+)$ ]]; then
    from="${BASH_REMATCH[1]}"
    to="${from}"
  else
    preflight_die_phase "[check] invalid phase '${spec}' (use N or N-M, each 1–11)"
  fi
  preflight_validate_phase_num "${from}"
  preflight_validate_phase_num "${to}"
  if [[ "${from}" -gt "${to}" ]]; then
    preflight_die_phase "[check] invalid phase range ${from}-${to} (start > end)"
  fi
  PREFLIGHT_FROM="${from}"
  PREFLIGHT_TO="${to}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v) VERBOSE=1; shift ;;
    --json) JSON=1; VERBOSE=1; shift ;;
    --strict) PREFLIGHT_STRICT=1; shift ;;
    --host) SCOPE="host"; shift ;;
    --deploy) SCOPE="deploy"; shift ;;
    --phases)
      [[ -n "${2:-}" ]] || { log_error "--phases requires argument"; exit 1; }
      SCOPE="range"
      parse_phase_range "$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    [0-9]*)
      SCOPE="range"
      parse_phase_range "$1"
      shift
      ;;
    *) log_error "unknown option: $1"; usage; exit 1 ;;
  esac
done

# shellcheck source=lib/emit.sh
source "${PREFLIGHT_DIR}/lib/emit.sh"
preflight_init_colors
# shellcheck source=../lib/host-artifacts.sh
source "${PREFLIGHT_DIR}/../lib/host-artifacts.sh"
# shellcheck source=../lib/stack-state.sh
source "${PREFLIGHT_DIR}/../lib/stack-state.sh"
# shellcheck source=lib/env.sh
source "${PREFLIGHT_DIR}/lib/env.sh"
# shellcheck source=lib/probes.sh
source "${PREFLIGHT_DIR}/lib/probes.sh"
# shellcheck source=lib/registry.sh
source "${PREFLIGHT_DIR}/lib/registry.sh"
# shellcheck source=lib/network.sh
source "${PREFLIGHT_DIR}/lib/network.sh"
# shellcheck source=lib/stack.sh
source "${PREFLIGHT_DIR}/lib/stack.sh"
# shellcheck source=lib/inbound.sh
source "${PREFLIGHT_DIR}/lib/inbound.sh"
# shellcheck source=lib/mtproxy.sh
source "${PREFLIGHT_DIR}/lib/mtproxy.sh"
# shellcheck source=lib/out.sh
source "${PREFLIGHT_DIR}/lib/out.sh"

# Phase registry: id → function name (order matters)
declare -a PREFLIGHT_PHASE_IDS=(
  01 02 03 04 05 06 07 08 09 10 11
)
declare -A PREFLIGHT_PHASE_FN=(
  [01]=preflight_phase_01_repo
  [02]=preflight_phase_02_os
  [03]=preflight_phase_03_docker
  [04]=preflight_phase_04_kernel
  [05]=preflight_phase_05_host_sysctl
  [06]=preflight_phase_06_host_svc
  [07]=preflight_phase_07_network
  [08]=preflight_phase_08_data
  [09]=preflight_phase_09_stack
  [10]=preflight_phase_10_out
  [11]=preflight_phase_11_mtproxy
)

preflight_source_phases() {
  local id f
  for id in "${PREFLIGHT_PHASE_IDS[@]}"; do
    f="${PREFLIGHT_DIR}/phases/${id}-*.sh"
    # shellcheck disable=SC1090
    source ${f}
  done
}

preflight_should_run() {
  local id="$1"
  local num="${id#0}"
  num="${num#0}"  # 01 → 1
  [[ "${num}" =~ ^[0-9]+$ ]] || num="${id}"

  case "${SCOPE}" in
    host) [[ "${num}" -ge 1 && "${num}" -le 5 ]] ;;
    deploy) [[ "${num}" -ge 6 && "${num}" -le 11 ]] ;;
    range) [[ "${num}" -ge "${PREFLIGHT_FROM}" && "${num}" -le "${PREFLIGHT_TO}" ]] ;;
    all) return 0 ;;
    *) return 1 ;;
  esac
}

preflight_run() {
  preflight_load_env || true

  if [[ "${JSON}" -eq 0 ]]; then
    local scope_label="all phases"
    [[ "${SCOPE}" == "host" ]] && scope_label="host bootstrap (phases 1–5)"
    [[ "${SCOPE}" == "deploy" ]] && scope_label="deploy readiness (phases 6–11)"
    [[ "${SCOPE}" == "range" ]] && scope_label="phase ${PREFLIGHT_FROM}"
    [[ "${SCOPE}" == "range" && "${PREFLIGHT_FROM}" != "${PREFLIGHT_TO}" ]] && \
      scope_label="phases ${PREFLIGHT_FROM}–${PREFLIGHT_TO}"
    printf '%sVPN preflight (make check)%s  repo=%s  scope=%s\n' \
      "${C_DIM}" "${C_RESET}" "${REPO_ROOT}" "${scope_label}"
  fi

  preflight_source_phases

  local id fn
  for id in "${PREFLIGHT_PHASE_IDS[@]}"; do
    preflight_should_run "${id}" || continue
    fn="${PREFLIGHT_PHASE_FN[${id}]}"
    "${fn}"
  done

  preflight_print_summary

  if [[ "${C_FAIL}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

preflight_run "$@"
