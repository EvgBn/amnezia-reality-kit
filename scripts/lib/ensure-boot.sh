#!/usr/bin/env bash
# Boot orchestration — testable via ENSURE_DOCKER, ENSURE_COMPOSE, ROUTE_SCRIPT overrides.

# shellcheck source=stack-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stack-state.sh"

_ensure_docker() {
  "${ENSURE_DOCKER:-docker}" "$@"
}

_ensure_compose_cmd() {
  local -a args=(-f "${COMPOSE_FILE}")
  if [[ -f "${ENV_FILE}" ]]; then
    args+=(--env-file "${ENV_FILE}")
  fi
  if [[ -n "${ENSURE_COMPOSE_CMD:-}" ]]; then
    "${ENSURE_COMPOSE_CMD}" "${args[@]}" "$@"
    return
  fi
  _ensure_docker compose "${args[@]}" "$@"
}

ensure_awg_stack_enabled() {
  if [[ -f "${ENV_FILE}" ]]; then
    local val
    if val="$(parse_bool "${ENABLE_AMNEZIAWG:-}" 1)"; then
      [[ "${val}" == "1" ]]
      return
    fi
  fi
  if [[ -f "${COMPOSE_FILE}" ]]; then
    component_enabled "${AWG_SERVICE}" "${COMPOSE_FILE}"
    return
  fi
  return 0
}

ensure_stop_awg_container() {
  local running
  running="$(_ensure_docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
  if ! grep -qx "${AWG_CONTAINER}" <<<"${running}"; then
    return 0
  fi
  if [[ -f "${COMPOSE_FILE}" ]]; then
    _ensure_compose_cmd stop "${AWG_SERVICE}" >/dev/null 2>&1 \
      || _ensure_docker stop "${AWG_CONTAINER}" >/dev/null 2>&1 \
      || true
  else
    _ensure_docker stop "${AWG_CONTAINER}" >/dev/null 2>&1 || true
  fi
}

ensure_wait_for_docker() {
  local i
  for i in $(seq 1 60); do
    if _ensure_docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  log_warn "Docker not ready after 60s — skipping stack orchestration."
  return 1
}

ensure_orchestrate_stack_after_boot() {
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log_info "Compose not found (${COMPOSE_FILE}) — module only; run make create-data && make start for the stack."
    return 0
  fi
  ensure_wait_for_docker || return 1

  log_info "Orchestrating stack (xray first, then awg/coredns with depends_on)…"
  if ! _ensure_compose_cmd up -d --wait "${XRAY_SERVICE}"; then
    log_error "compose up ${XRAY_SERVICE} failed."
    return 1
  fi

  # Docker daemon restart ignores depends_on — stop dependents for a clean compose-ordered start.
  _ensure_compose_cmd stop "${AWG_SERVICE}" coredns 2>/dev/null || true
  if _ensure_compose_cmd up -d --wait "${AWG_SERVICE}" coredns; then
    :
  else
    log_warn "${AWG_CONTAINER} not healthy after compose up — force-recreating…"
    if ! _ensure_compose_cmd up -d --force-recreate "${AWG_SERVICE}"; then
      log_error "compose force-recreate ${AWG_SERVICE} failed."
      return 1
    fi
    if ! _ensure_compose_cmd up -d --wait coredns; then
      log_error "compose up coredns failed after ${AWG_SERVICE} recreate."
      return 1
    fi
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    if ! "${ROUTE_SCRIPT}" apply; then
      log_warn "Host AWG route not applied — run: make route (or make start)"
    fi
  fi
  return 0
}

ensure_amneziawg_module() {
  local proc_modules="${ENSURE_PROC_MODULES:-/proc/modules}"

  if grep -q '^amneziawg ' "${proc_modules}"; then
    log_info "amneziawg module already loaded."
    return 0
  fi
  if "${ENSURE_MODPROBE:-modprobe}" amneziawg 2>/dev/null && grep -q '^amneziawg ' "${proc_modules}"; then
    log_info "amneziawg module loaded from existing install."
    return 0
  fi

  log_warn "amneziawg module missing for kernel $(uname -r) — rebuilding."
  ensure_stop_awg_container

  local attempt rebuilt=0
  for attempt in 1 2 3; do
    if "${REBUILD_SCRIPT}"; then
      rebuilt=1
      break
    fi
    if [[ "${attempt}" -lt 3 ]]; then
      log_warn "rebuild-amneziawg.sh failed (attempt ${attempt}/3); retrying in 15s…"
      sleep 15
    fi
  done

  if [[ "${rebuilt}" -eq 1 ]]; then
    log_info "amneziawg module rebuilt for $(uname -r)."
    return 0
  fi

  log_error "amneziawg module rebuild failed after 3 attempts."
  return 1
}

ensure_boot_run() {
  local module_rc=0 stack_rc=0

  if ! ensure_awg_stack_enabled; then
    return 0
  fi

  ensure_amneziawg_module || module_rc=$?

  if stack_state_is_stopped; then
    log_info "Stack marked stopped (${STACK_STOPPED_FILE}) — skipping compose; run: make start"
    [[ "${module_rc}" -ne 0 ]] && return 1
    return 0
  fi

  ensure_orchestrate_stack_after_boot || stack_rc=$?

  if [[ "${module_rc}" -ne 0 || "${stack_rc}" -ne 0 ]]; then
    return 1
  fi
  return 0
}
