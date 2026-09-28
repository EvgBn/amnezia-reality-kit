#!/usr/bin/env bash
# Phase 11: MTProxy (Telegram) — optional; skipped when ENABLE_MTPROXY=0.

preflight_phase_11_mtproxy() {
  phase_header "Phase 11: MTProxy (Telegram)"

  # shellcheck source=../lib/common.sh
  source "${REPO_ROOT}/scripts/lib/common.sh"

  if [[ "$(parse_bool "${ENABLE_MTPROXY:-}" 0)" != "1" ]]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'vpn-teleproxy'; then
      emit WARN MTPROXY stale "vpn-teleproxy running but ENABLE_MTPROXY=0" \
        "ENABLE_MTPROXY=0, make refresh-full"
    else
      emit SKIP MTPROXY phase "ENABLE_MTPROXY=0 (optional)"
    fi
    return
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    if [[ "${MTPROXY_MODE:-standalone}" == "sni" ]]; then
      preflight_check_mtproxy_env_group "MTPROXY_*" "${PREFLIGHT_ENV_MTPROXY[@]}" MTPROXY_SNI
    else
      preflight_check_mtproxy_env_group "MTPROXY_*" "${PREFLIGHT_ENV_MTPROXY[@]}"
    fi
  else
    emit WARN MTPROXY .env "missing" "make create-data"
  fi

  preflight_check_build_mtproxy

  if [[ -f "${COMPOSE_FILE}" ]]; then
    local tp_image
    tp_image="$(preflight_teleproxy_image_ref)"
    if docker image inspect "${tp_image}" >/dev/null 2>&1; then
      emit OK MTPROXY teleproxy-image "${tp_image} available"
    elif [[ -f "${ENV_FILE}" ]]; then
      emit WARN MTPROXY teleproxy-image "${tp_image} missing" "make images-pull-upstream"
    else
      emit WARN MTPROXY teleproxy-image "${tp_image} missing" "make images-pull-upstream"
    fi
  fi

  preflight_check_mtproxy_port
  preflight_check_mtproxy_container
  preflight_check_mtproxy_smoke
}
