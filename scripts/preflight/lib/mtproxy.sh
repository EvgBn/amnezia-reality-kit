#!/usr/bin/env bash
# MTProxy preflight probes (phase 11).

preflight_stack_containers_expected() {
  local -n _out=$1
  _out=(vpn-xray vpn-amneziawg vpn-coredns)
}

preflight_check_mtproxy_env_group() {
  local label="$1"
  shift
  local -a keys=("$@")
  local k missing=0 val

  for k in "${keys[@]}"; do
    val="${!k:-}"
    if [[ -z "${val}" ]]; then
      emit FAIL MTPROXY "${k}" "empty in .env" "edit .data/.env"
      missing=1
    elif preflight_env_value_is_placeholder "${val}"; then
      emit FAIL MTPROXY "${k}" "placeholder (${val})" "edit .data/.env"
      missing=1
    fi
  done

  if [[ "${missing}" -eq 0 ]]; then
    emit OK MTPROXY "${label}" "${#keys[@]}/${#keys[@]} keys set"
  fi
}

preflight_check_build_mtproxy() {
  if [[ ! -f "${ENV_FILE}" || ! -f "${COMPOSE_FILE}" ]]; then
    emit SKIP MTPROXY mtproxy-sync ".env or build missing"
    return
  fi

  local out rc
  chmod +x "${REPO_ROOT}/scripts/maintenance/verify-mtproxy-config.sh" 2>/dev/null || true
  out="$("${REPO_ROOT}/scripts/maintenance/verify-mtproxy-config.sh" 2>&1)" || rc=$?
  if [[ "${rc:-0}" -eq 0 ]]; then
    local detail="${out#\[verify-mtproxy\] OK — }"
    emit OK MTPROXY mtproxy-sync "${detail:-matches .env}"
  else
    local reason
    reason="$(sed -n 's/^\[verify-mtproxy\] FAIL: //p' <<<"${out}" | head -1)"
    emit FAIL MTPROXY mtproxy-sync "${reason:-mismatch}" "make build && make recreate"
  fi
}

preflight_check_mtproxy_port() {
  # shellcheck source=../../lib/common.sh
  source "${REPO_ROOT}/scripts/lib/common.sh"
  local mode host_port stats_port holder publish

  mode="${MTPROXY_MODE:-standalone}"
  host_port="${MTPROXY_HOST_PORT:-8444}"
  stats_port="${MTPROXY_STATS_PORT:-8888}"
  publish="${MTPROXY_PUBLISH:-0.0.0.0}"

  if [[ "${mode}" == "sni" ]]; then
    publish="127.0.0.1"
  fi

  if preflight_port_in_use tcp "${host_port}"; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'vpn-teleproxy'; then
      emit OK MTPROXY "tcp/${host_port}" "in use by vpn-teleproxy"
    else
      emit FAIL MTPROXY "tcp/${host_port}" "port busy (not vpn-teleproxy)" \
        "free ${host_port}/tcp or stop conflicting service"
    fi
  else
    emit FAIL MTPROXY "tcp/${host_port}" "not listening" "make refresh-full"
  fi

  if preflight_port_in_use tcp "${stats_port}"; then
    holder="$(preflight_port_holder_name tcp "${stats_port}")"
    if [[ "${holder}" == *127.0.0.1* ]] || [[ "${holder}" == *vpn-teleproxy* ]] || \
       [[ "${holder}" == *docker-proxy* ]]; then
      if [[ "${holder}" == *0.0.0.0* ]] && [[ "${holder}" != *127.0.0.1* ]]; then
        emit FAIL MTPROXY "tcp/${stats_port}" "stats must be loopback-only" \
          "republish 127.0.0.1:${stats_port} in compose"
      else
        emit OK MTPROXY "tcp/${stats_port}" "stats on loopback"
      fi
    else
      emit FAIL MTPROXY "tcp/${stats_port}" "port busy (not teleproxy stats)" \
        "free ${stats_port}/tcp or change MTPROXY_STATS_PORT"
    fi
  else
    emit OK MTPROXY "tcp/${stats_port}" "free (stats only when container up)"
  fi

  if [[ "${mode}" == "standalone" && "${host_port}" == "443" && "${publish}" != "127.0.0.1" ]]; then
    emit FAIL MTPROXY mtproxy/443 "standalone cannot publish :443 publicly" \
      "use MTPROXY_HOST_PORT=8444 or MTPROXY_MODE=sni"
  fi

  if preflight_port_in_use tcp 443; then
    holder="$(preflight_port_holder_name tcp 443)"
    if [[ "${holder}" == *vpn-teleproxy* ]]; then
      emit FAIL MTPROXY tcp/443 "vpn-teleproxy binds :443" \
        "use MTPROXY_HOST_PORT=8444 (standalone) or nginx SNI (sni mode)"
    fi
  fi

  if [[ "${mode}" == "sni" ]]; then
    if [[ -z "${MTPROXY_SNI:-}" ]]; then
      emit FAIL MTPROXY MTPROXY_SNI "empty in sni mode" "set MTPROXY_SNI in .data/.env"
    elif [[ -n "${REALITY_INBOUND_SERVER_NAME:-}" && "${MTPROXY_SNI}" == "${REALITY_INBOUND_SERVER_NAME}" ]]; then
      emit FAIL MTPROXY MTPROXY_SNI "equals REALITY_INBOUND_SERVER_NAME" "use distinct SNIs in nginx map"
    else
      emit OK MTPROXY MTPROXY_SNI "${MTPROXY_SNI}"
    fi

    local nginx_snippet="${NGINX_STREAM_SNIPPET:-/etc/nginx/stream.d/vpn-bridge-443.conf}"
    if [[ -f "${nginx_snippet}" ]]; then
      emit OK MTPROXY nginx-stream "${nginx_snippet} present"
      preflight_check_mtproxy_nginx_sni "${nginx_snippet}"
    else
      emit WARN MTPROXY nginx-stream "snippet missing" \
        "install config/examples/nginx-stream-443.conf.example"
    fi

    if preflight_port_in_use tcp 443; then
      holder="$(preflight_port_holder_name tcp 443)"
      if [[ "${holder}" == *nginx* ]] || [[ "${holder}" != *vpn-* && "${holder}" != *docker-proxy* ]]; then
        emit OK MTPROXY tcp/443 "nginx/front holds :443 (sni mode)"
      elif [[ "${holder}" == *vpn-xray* ]] || [[ "${holder}" == *vpn-teleproxy* ]]; then
        emit FAIL MTPROXY tcp/443 "container holds :443 in sni mode" \
          "nginx stream must own :443; proxies on loopback high ports"
      else
        emit OK MTPROXY tcp/443 "in use (verify nginx stream for sni)"
      fi
    else
      emit FAIL MTPROXY tcp/443 "free but MTPROXY_MODE=sni expects nginx on :443" \
        "configure nginx stream router on host :443"
    fi
  fi
}

preflight_check_mtproxy_container() {
  local name="vpn-teleproxy"
  local status health fix

  if ! preflight_stack_any_running; then
    emit SKIP MTPROXY "${name}" "stack not running"
    return
  fi

  status="$(preflight_container_status "${name}")"
  case "${status}" in
    missing)
      emit FAIL MTPROXY "${name}" "expected but not running" "make refresh-full"
      ;;
    running)
      health="$(preflight_container_health "${name}")"
      case "${health}" in
        healthy)
          emit OK MTPROXY "${name}" "running (healthy)"
          ;;
        unhealthy)
          emit FAIL MTPROXY "${name}" "running (unhealthy)" "make logs; make refresh-full"
          ;;
        starting|no-healthcheck)
          emit OK MTPROXY "${name}" "running (${health})"
          ;;
        *)
          emit WARN MTPROXY "${name}" "running (${health})" "make ps && make logs"
          ;;
      esac
      ;;
    *)
      emit FAIL MTPROXY "${name}" "state=${status}" "make ps && make refresh-full"
      ;;
  esac
}

preflight_check_mtproxy_smoke() {
  # shellcheck source=../../lib/mtproxy-common.sh
  source "${REPO_ROOT}/scripts/lib/mtproxy-common.sh"
  # shellcheck source=../../lib/mtproxy-smoke.sh
  source "${REPO_ROOT}/scripts/lib/mtproxy-smoke.sh"

  if ! preflight_stack_any_running; then
    emit SKIP MTPROXY mtproxy-smoke "stack not running"
    return
  fi

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'vpn-teleproxy'; then
    emit FAIL MTPROXY mtproxy-smoke "vpn-teleproxy not running" "make refresh-full"
    return
  fi

  local out rc warns
  out="$(mtproxy_smoke_run 2>&1)" || rc=$?
  if [[ "${rc:-0}" -eq 0 ]]; then
    if grep -q '\[mtproxy-smoke\] WARN:' <<<"${out}"; then
      warns="$(grep '\[mtproxy-smoke\] WARN:' <<<"${out}" | sed 's/^\[mtproxy-smoke\] WARN: //' | head -1)"
      emit WARN MTPROXY mtproxy-smoke "${warns}"
    else
      if [[ "${MTPROXY_MODE:-standalone}" == "sni" ]]; then
        emit OK MTPROXY mtproxy-smoke "link + TCP + stats + SNI :443"
      else
        emit OK MTPROXY mtproxy-smoke "link + TCP + stats"
      fi
    fi
    return
  fi

  local reason
  reason="$(grep '\[mtproxy-smoke\] FAIL:' <<<"${out}" | sed 's/^\[mtproxy-smoke\] FAIL: //' | head -1)"
  emit FAIL MTPROXY mtproxy-smoke "${reason:-smoke failed}" "make verify-mtproxy-smoke"
}

preflight_check_mtproxy_nginx_sni() {
  local nginx_snippet="${1:-${NGINX_STREAM_SNIPPET:-/etc/nginx/stream.d/vpn-bridge-443.conf}}"
  local out map_rc tls_rc map_warns tls_warns

  # shellcheck source=../../lib/mtproxy-common.sh
  source "${REPO_ROOT}/scripts/lib/mtproxy-common.sh"
  # shellcheck source=../../lib/mtproxy-sni.sh
  source "${REPO_ROOT}/scripts/lib/mtproxy-sni.sh"

  mtproxy_load_env

  out="$(mtproxy_sni_nginx_lint "${nginx_snippet}" 2>&1)" || map_rc=$?
  map_rc="${map_rc:-0}"
  map_warns="$(grep '\[mtproxy-sni\] WARN:' <<<"${out}" | sed 's/^\[mtproxy-sni\] WARN: //' | head -1)"

  if [[ "${map_rc}" -eq 0 ]]; then
    if [[ -n "${map_warns}" ]]; then
      emit WARN MTPROXY nginx-sni-map "${map_warns}"
    else
      local hosts
      hosts="$(mtproxy_sni_required_hosts | paste -sd, -)"
      emit OK MTPROXY nginx-sni-map "${hosts} → 127.0.0.1:${MTPROXY_HOST_PORT:-8444}"
    fi
  else
    local reason
    reason="$(grep '\[mtproxy-sni\] FAIL:' <<<"${out}" | sed 's/^\[mtproxy-sni\] FAIL: //' | head -1)"
    emit FAIL MTPROXY nginx-sni-map "${reason:-map lint failed}" \
      "edit ${nginx_snippet}; see docs/SNI-9-PLUS.md"
  fi

  out="$(mtproxy_sni_tls_probe "${nginx_snippet}" 2>&1)" || tls_rc=$?
  tls_rc="${tls_rc:-0}"
  tls_warns="$(grep '\[mtproxy-sni\] WARN:' <<<"${out}" | sed 's/^\[mtproxy-sni\] WARN: //' | head -1)"

  if [[ "${tls_rc}" -eq 0 ]]; then
    if [[ -n "${tls_warns}" ]]; then
      emit WARN MTPROXY nginx-sni-tls "${tls_warns}"
    else
      emit OK MTPROXY nginx-sni-tls ":443 SNI routes to teleproxy Fake-TLS"
    fi
  else
    local reason
    reason="$(grep '\[mtproxy-sni\] FAIL:' <<<"${out}" | sed 's/^\[mtproxy-sni\] FAIL: //' | head -1)"
    emit FAIL MTPROXY nginx-sni-tls "${reason:-TLS probe failed}" \
      "openssl s_client -connect 127.0.0.1:443 -servername <MTPROXY_EE_DOMAIN>"
  fi
}
