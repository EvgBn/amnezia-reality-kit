#!/usr/bin/env bash
# Shared helpers for MTProxy client scripts.

MTPROXY_CONTAINER="${MTPROXY_CONTAINER:-vpn-teleproxy}"

mtproxy_load_env() {
  # shellcheck source=paths.sh
  source "${REPO_ROOT}/scripts/lib/paths.sh"
  # shellcheck source=common.sh
  source "${REPO_ROOT}/scripts/lib/common.sh"
  [[ -f "${ENV_FILE}" ]] || {
    log_error "Missing ${ENV_FILE} — run: make create-data"
    exit 1
  }
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

mtproxy_require_enabled() {
  mtproxy_load_env
  if [[ "$(parse_bool "${ENABLE_MTPROXY:-}" 0)" != "1" ]]; then
    log_error "ENABLE_MTPROXY=0 — set ENABLE_MTPROXY=1, make build && make refresh-full"
    exit 1
  fi
}

mtproxy_client_path() {
  local name="$1"
  echo "${MTPROXY_CLIENTS_DIR}/${name}.txt"
}

mtproxy_mask_secret() {
  local secret="$1"
  local len="${#secret}"
  if [[ "${len}" -le 8 ]]; then
    echo "****"
    return
  fi
  printf '%s****%s' "${secret:0:4}" "${secret: -4}"
}

mtproxy_expected_external_port() {
  mtproxy_load_env
  local mode="${MTPROXY_MODE:-standalone}"
  if [[ "${mode}" == "sni" ]]; then
    printf '%s' "${MTPROXY_EXTERNAL_PORT:-443}"
  else
    printf '%s' "${MTPROXY_EXTERNAL_PORT:-${MTPROXY_HOST_PORT:-8444}}"
  fi
}

mtproxy_normalize_link_port() {
  local link="$1" expected_port="$2"
  [[ -n "${link}" && -n "${expected_port}" ]] || {
    printf '%s' "${link}"
    return
  }
  if [[ "${link}" == *"port=${expected_port}"* ]]; then
    printf '%s' "${link}"
    return
  fi
  # Teleproxy may omit external_port in persisted config.toml — fix client port from kit .env.
  sed -E "s/port=[0-9]+/port=${expected_port}/" <<<"${link}"
}

mtproxy_to_tg_link() {
  local link="$1"
  if [[ "${link}" == https://t.me/proxy?* ]]; then
    printf 'tg://proxy?%s' "${link#https://t.me/proxy?}"
  else
    printf '%s' "${link}"
  fi
}

mtproxy_extract_link_from_stats() {
  local stats_port="${MTPROXY_STATS_PORT:-8888}" html link
  html="$(curl -sf "http://127.0.0.1:${stats_port}/" 2>/dev/null || true)"
  link="$(grep -oE 'href="tg://proxy\?[^"]+"' <<<"${html}" | head -1 | sed 's/^href="//;s/"$//' || true)"
  if [[ -z "${link}" ]]; then
    link="$(grep -oE 'https://t\.me/proxy\?[^"<>[:space:]]+' <<<"${html}" | head -1 || true)"
  fi
  [[ -n "${link}" ]] && mtproxy_to_tg_link "${link}"
}

mtproxy_extract_link_from_logs() {
  local logs link
  logs="$(docker logs "${MTPROXY_CONTAINER}" 2>&1)" || {
    log_error "Cannot read logs from ${MTPROXY_CONTAINER} — is the stack up?"
    exit 1
  }
  link="$(grep -oE 'tg://proxy\?[^[:space:]]+' <<<"${logs}" | tail -1 || true)"
  if [[ -z "${link}" ]]; then
    link="$(grep -oE 'https://t\.me/proxy\?[^[:space:]]+' <<<"${logs}" | tail -1 || true)"
    link="$(mtproxy_to_tg_link "${link}")"
  fi
  [[ -n "${link}" ]] && printf '%s' "${link}"
}

mtproxy_resolve_link() {
  local link expected_port
  expected_port="$(mtproxy_expected_external_port)"
  link="$(mtproxy_extract_link_from_stats || true)"
  if [[ -z "${link}" ]]; then
    link="$(mtproxy_extract_link_from_logs || true)"
  fi
  [[ -n "${link}" ]] || {
    log_error "No MTProxy link in stats or ${MTPROXY_CONTAINER} logs — wait for startup or: make refresh-full"
    exit 1
  }
  link="$(mtproxy_to_tg_link "${link}")"
  link="$(mtproxy_normalize_link_port "${link}" "${expected_port}")"
  printf '%s' "${link}"
}

mtproxy_parse_link_field() {
  local link="$1" field="$2"
  python3 - "$link" "$field" <<'PY'
import sys, urllib.parse
link, field = sys.argv[1], sys.argv[2]
q = urllib.parse.urlparse(link).query
params = urllib.parse.parse_qs(q)
vals = params.get(field, [])
print(vals[0] if vals else "")
PY
}
