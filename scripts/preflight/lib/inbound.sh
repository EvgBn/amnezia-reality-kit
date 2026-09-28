#!/usr/bin/env bash
# Phase 8: build config vs ENABLE_XRAY_INBOUND / ports in .env

preflight_check_build_inbound() {
  if [[ ! -f "${ENV_FILE}" || ! -f "${COMPOSE_FILE}" || ! -f "${XRAY_CONF}" ]]; then
    emit SKIP DATA inbound-sync ".env or build missing"
    return
  fi

  local out rc
  chmod +x "${REPO_ROOT}/scripts/maintenance/verify-inbound-config.sh" 2>/dev/null || true
  out="$("${REPO_ROOT}/scripts/maintenance/verify-inbound-config.sh" 2>&1)" || rc=$?
  if [[ "${rc:-0}" -eq 0 ]]; then
    local detail="${out#\[verify-inbound\] OK — }"
    emit OK DATA inbound-sync "${detail:-matches .env}"
  else
    local reason
    reason="$(sed -n 's/^\[verify-inbound\] FAIL: //p' <<<"${out}" | head -1)"
    emit FAIL DATA inbound-sync "${reason:-mismatch}" "make build && make recreate"
  fi
}
