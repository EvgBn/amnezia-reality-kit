#!/usr/bin/env bash
# Verify SNI profile: loopback proxies + required .env keys (nginx is host-managed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

[[ -f "${ENV_FILE}" ]] || {
  echo "[verify-sni-443] ERROR: ${ENV_FILE} missing — run make create-data" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

MTPROXY_MODE="${MTPROXY_MODE:-standalone}"
ENABLE_MTPROXY="$(parse_bool "${ENABLE_MTPROXY:-}" 0)"
ENABLE_XRAY_INBOUND="$(parse_bool "${ENABLE_XRAY_INBOUND:-}" 1)"

if [[ "${MTPROXY_MODE}" != "sni" ]]; then
  echo "[verify-sni-443] OK — MTPROXY_MODE=${MTPROXY_MODE} (SNI checks skipped)"
  exit 0
fi

errors=0
warn=0

check_fail() {
  echo "[verify-sni-443] FAIL: $1" >&2
  errors=$((errors + 1))
}

check_warn() {
  echo "[verify-sni-443] WARN: $1" >&2
  warn=$((warn + 1))
}

"${SCRIPT_DIR}/verify-inbound-config.sh" || errors=$((errors + 1))
"${SCRIPT_DIR}/verify-mtproxy-config.sh" || errors=$((errors + 1))

if [[ "${ENABLE_MTPROXY}" == "1" ]]; then
  [[ -n "${MTPROXY_SNI:-}" ]] || check_fail "MTPROXY_SNI empty (required for sni profile)"
  [[ "${MTPROXY_EXTERNAL_PORT:-443}" == "443" ]] || \
    check_fail "MTPROXY_EXTERNAL_PORT must be 443 in sni mode (got ${MTPROXY_EXTERNAL_PORT:-})"
fi

if [[ "${ENABLE_XRAY_INBOUND}" == "1" ]]; then
  [[ -n "${REALITY_INBOUND_SERVER_NAME:-}" ]] || \
    check_fail "REALITY_INBOUND_SERVER_NAME empty (nginx SNI map for VLESS)"
fi

NGINX_SNIPPET="${NGINX_STREAM_SNIPPET:-/etc/nginx/stream.d/vpn-bridge-443.conf}"

if [[ "${ENABLE_MTPROXY}" == "1" ]]; then
  # shellcheck source=../lib/mtproxy-sni.sh
  source "${SCRIPT_DIR}/../lib/mtproxy-sni.sh"
  if [[ -f "${NGINX_SNIPPET}" ]]; then
    sni_out="$(mtproxy_sni_run_checks "${NGINX_SNIPPET}" 2>&1)" || true
    while IFS= read -r sni_line; do
      [[ -n "${sni_line}" ]] || continue
      case "${sni_line}" in
        *"[mtproxy-sni] FAIL:"*)
          check_fail "${sni_line#*[mtproxy-sni] FAIL: }"
          ;;
        *"[mtproxy-sni] WARN:"*)
          check_warn "${sni_line#*[mtproxy-sni] WARN: }"
          ;;
      esac
    done <<<"${sni_out}"
  else
    check_warn "nginx stream snippet missing (${NGINX_SNIPPET}) — see config/examples/nginx-stream-443.conf.example"
  fi
elif [[ ! -f "${NGINX_SNIPPET}" ]]; then
  check_warn "nginx stream snippet missing (${NGINX_SNIPPET}) — see config/examples/nginx-stream-443.conf.example"
fi

if [[ "${errors}" -gt 0 ]]; then
  exit 1
fi

if [[ "${warn}" -gt 0 ]]; then
  echo "[verify-sni-443] OK with warnings — sni profile .env/compose sync (configure host nginx stream)"
else
  echo "[verify-sni-443] OK — sni profile: kit loopback proxies + keys set"
fi
