#!/usr/bin/env bash
# MTProxy ingress smoke checks (link sanity + TCP + stats). Sourced by verify/export/preflight.

# mtproxy_smoke_run [link]
# Optional pre-resolved tg:// link; otherwise resolves via mtproxy_resolve_link.
# Prints [mtproxy-smoke] lines; returns 0 when all required checks pass.
mtproxy_smoke_run() {
  local link="${1:-}" expected_port server port secret
  local -a failures=() warnings=()
  local mode host_port container_port publish stats_port teleproxy_version
  local ingress_addr health_status external_port_env

  mtproxy_load_env

  mode="${MTPROXY_MODE:-standalone}"
  host_port="${MTPROXY_HOST_PORT:-8444}"
  container_port="${MTPROXY_CONTAINER_PORT:-443}"
  publish="${MTPROXY_PUBLISH:-0.0.0.0}"
  stats_port="${MTPROXY_STATS_PORT:-8888}"
  teleproxy_version="${TELEPROXY_VERSION:-4.12.0}"
  expected_port="$(mtproxy_expected_external_port)"

  if [[ "${mode}" == "sni" ]]; then
    publish="127.0.0.1"
  fi

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${MTPROXY_CONTAINER}"; then
    failures+=("${MTPROXY_CONTAINER} not running")
    _mtproxy_smoke_report failures warnings
    return 1
  fi

  health_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${MTPROXY_CONTAINER}" 2>/dev/null || echo unknown)"
  case "${health_status}" in
    healthy) ;;
    starting) warnings+=("container health=${health_status} (may pass after warmup)") ;;
    unhealthy) failures+=("container health=${health_status}") ;;
    none) warnings+=("container has no healthcheck status") ;;
    *) warnings+=("container health=${health_status}") ;;
  esac

  if ! curl -sf --max-time 5 "http://127.0.0.1:${stats_port}/stats" >/dev/null 2>&1; then
    failures+=("stats http://127.0.0.1:${stats_port}/stats unreachable")
  fi

  if [[ -z "${link}" ]]; then
    link="$(mtproxy_resolve_link 2>/dev/null || true)"
  fi
  if [[ -z "${link}" ]]; then
    failures+=("cannot resolve tg:// link from stats or logs")
  else
    server="$(mtproxy_parse_link_field "${link}" server)"
    port="$(mtproxy_parse_link_field "${link}" port)"
    secret="$(mtproxy_parse_link_field "${link}" secret)"

    [[ -n "${server}" ]] || failures+=("link missing server=")
    [[ -n "${port}" ]] || failures+=("link missing port=")
    [[ -n "${secret}" ]] || failures+=("link missing secret=")

    if [[ -n "${port}" && "${port}" != "${expected_port}" ]]; then
      failures+=("link port=${port} != expected ${expected_port} (check TELEPROXY_VERSION>=4.12 and EXTERNAL_PORT)")
    fi

    ingress_addr="${IN_SERVER_IP:-}"
    if [[ -n "${IN_INGRESS:-}" ]]; then
      ingress_addr="$(python3 - "${IN_INGRESS}" <<'PY'
import sys
raw = sys.argv[1].strip()
if ";" in raw:
    _, addr = raw.split(";", 1)
    print(addr.strip())
else:
    print(raw)
PY
)"
    fi
    if [[ -n "${ingress_addr}" && -n "${server}" && "${server}" != "${ingress_addr}" ]]; then
      warnings+=("link server=${server} != IN ingress ${ingress_addr}")
    fi

    if [[ -n "${MTPROXY_EE_DOMAIN:-}" && -n "${secret}" && "${secret}" != ee* ]]; then
      warnings+=("MTPROXY_EE_DOMAIN set but secret does not use ee fake-TLS prefix")
    fi
  fi

  if [[ "${host_port}" != "${container_port}" ]]; then
    if [[ "$(printf '%s\n%s\n' "4.12.0" "${teleproxy_version}" | sort -V | head -1)" != "4.12.0" ]]; then
      failures+=(
        "TELEPROXY_VERSION=${teleproxy_version} < 4.12.0 with host ${host_port}→container ${container_port} (link port will be wrong)"
      )
    fi
    external_port_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
      "${MTPROXY_CONTAINER}" 2>/dev/null | sed -n 's/^EXTERNAL_PORT=//p' | head -1)"
    if [[ -n "${external_port_env}" && "${external_port_env}" != "${expected_port}" ]]; then
      failures+=("container EXTERNAL_PORT=${external_port_env} != expected ${expected_port}")
    fi
  fi

  if ! _mtproxy_smoke_tcp_probe "127.0.0.1" "${host_port}"; then
    failures+=("TCP connect failed to backend 127.0.0.1:${host_port}")
  fi

  if [[ "${mode}" == "standalone" && "${publish}" == "0.0.0.0" ]]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
      if ! ufw status 2>/dev/null | grep -qE "${host_port}/tcp|[[:space:]]${host_port}[[:space:]]"; then
        warnings+=("ufw active but ${host_port}/tcp not allowed (clients off-host may fail)")
      fi
    fi
  fi

  if [[ "${mode}" == "sni" ]]; then
    if ! _mtproxy_smoke_tcp_probe "127.0.0.1" "${host_port}"; then
      failures+=("sni backend 127.0.0.1:${host_port} unreachable")
    fi
    if _mtproxy_smoke_tcp_probe "127.0.0.1" "443"; then
      : # nginx stream front — OK
    else
      warnings+=("nothing listening on 127.0.0.1:443 (nginx stream expected for sni)")
    fi
    # shellcheck source=mtproxy-sni.sh
    source "${REPO_ROOT}/scripts/lib/mtproxy-sni.sh"
    local sni_out sni_line
    sni_out="$(mtproxy_sni_run_checks 2>&1)" || true
    while IFS= read -r sni_line; do
      [[ -n "${sni_line}" ]] || continue
      case "${sni_line}" in
        *"[mtproxy-sni] FAIL:"*)
          failures+=("${sni_line#*[mtproxy-sni] FAIL: }")
          ;;
        *"[mtproxy-sni] WARN:"*)
          warnings+=("${sni_line#*[mtproxy-sni] WARN: }")
          ;;
      esac
    done <<<"${sni_out}"
  fi

  _mtproxy_smoke_report failures warnings "${link:-}"
  [[ ${#failures[@]} -eq 0 ]]
}

_mtproxy_smoke_tcp_probe() {
  local host="$1" port="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

_mtproxy_smoke_report() {
  local -n _fail=$1
  local -n _warn=$2
  local link="${3:-}"
  local f w

  for f in "${_fail[@]}"; do
    echo "[mtproxy-smoke] FAIL: ${f}" >&2
  done
  for w in "${_warn[@]}"; do
    echo "[mtproxy-smoke] WARN: ${w}" >&2
  done

  if [[ ${#_fail[@]} -eq 0 ]]; then
    local detail="stats OK"
    if [[ -n "${link}" ]]; then
      detail="link port=$(mtproxy_parse_link_field "${link}" port) TCP backend OK"
    fi
    if [[ ${#_warn[@]} -gt 0 ]]; then
      echo "[mtproxy-smoke] OK with warnings — ${detail}"
    else
      echo "[mtproxy-smoke] OK — ${detail}"
    fi
  fi
}
