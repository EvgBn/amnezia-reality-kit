#!/usr/bin/env bash
# MTProxy SNI profile helpers — nginx stream map lint + TLS :443 probes (prod 9+).

# mtproxy_sni_secret_domain [secret]
# Decode Fake-TLS domain hex tail from ee-secret (after 16-byte key).
mtproxy_sni_secret_domain() {
  local secret="${1:-${MTPROXY_SECRET:-}}"
  python3 - "${secret}" <<'PY'
import sys
secret = sys.argv[1].strip().lower()
if not secret.startswith("ee") or len(secret) <= 34:
    sys.exit(0)
hex_tail = secret[34:]
if not hex_tail or len(hex_tail) % 2:
    sys.exit(0)
try:
    print(bytes.fromhex(hex_tail).decode("ascii"))
except (ValueError, UnicodeDecodeError):
    pass
PY
}

# mtproxy_sni_required_hosts
# Print deduplicated SNI hostnames that nginx map must route to MTProxy backend.
mtproxy_sni_required_hosts() {
  local -A seen=()
  local h secret_domain

  for h in "${MTPROXY_SNI:-}" "${MTPROXY_EE_DOMAIN:-}"; do
    [[ -n "${h}" ]] || continue
    h="${h%%:*}"
    if [[ -z "${seen[$h]:-}" ]]; then
      seen["$h"]=1
      printf '%s\n' "${h}"
    fi
  done

  secret_domain="$(mtproxy_sni_secret_domain)"
  if [[ -n "${secret_domain}" && -z "${seen[$secret_domain]:-}" ]]; then
    printf '%s\n' "${secret_domain}"
  fi
}

# mtproxy_nginx_map_entries <snippet>
# Print "sni<TAB>upstream" per map line (excludes default).
mtproxy_nginx_map_entries() {
  local snippet="$1"
  [[ -f "${snippet}" ]] || return 1
  python3 - "${snippet}" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.split("#", 1)[0].strip()
        if not line or line.endswith("{") or line.startswith("map "):
            continue
        if line.startswith("server ") or line == "}":
            continue
        if not line.endswith(";"):
            continue
        line = line[:-1].strip()
        parts = line.split()
        if len(parts) < 2 or parts[0] == "default":
            continue
        print(f"{parts[0]}\t{parts[1]}")
PY
}

# mtproxy_sni_backend_port — loopback port teleproxy publishes on host.
mtproxy_sni_backend_port() {
  printf '%s' "${MTPROXY_HOST_PORT:-8444}"
}

# mtproxy_sni_nginx_upstream_for <snippet> <sni>
mtproxy_sni_nginx_upstream_for() {
  local snippet="$1" sni="$2"
  mtproxy_nginx_map_entries "${snippet}" | awk -F '\t' -v sni="${sni}" '$1 == sni { print $2; exit }'
}

# mtproxy_sni_nginx_site_hosts <snippet>
# SNIs routed to site TLS backend (typically :8080).
mtproxy_sni_nginx_site_hosts() {
  local snippet="$1"
  mtproxy_nginx_map_entries "${snippet}" | awk -F '\t' '$2 ~ /:8080$/ { print $1 }'
}

# mtproxy_sni_nginx_lint <snippet>
# Prints [mtproxy-sni] FAIL/WARN lines; returns 0 when no FAIL.
mtproxy_sni_nginx_lint() {
  local snippet="${1:-${NGINX_STREAM_SNIPPET:-/etc/nginx/stream.d/vpn-bridge-443.conf}}"
  local backend_port upstream host
  local -a failures=() warnings=()

  backend_port="$(mtproxy_sni_backend_port)"
  local expected_upstream="127.0.0.1:${backend_port}"

  if [[ ! -f "${snippet}" ]]; then
    echo "[mtproxy-sni] WARN: nginx stream snippet missing (${snippet})" >&2
    return 0
  fi

  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    upstream="$(mtproxy_sni_nginx_upstream_for "${snippet}" "${host}")"
    if [[ -z "${upstream}" ]]; then
      failures+=("nginx map missing SNI ${host} (required by .env/secret)")
    elif [[ "${upstream}" != "${expected_upstream}" ]]; then
      failures+=("nginx map ${host} → ${upstream} (expected ${expected_upstream})")
    fi
  done < <(mtproxy_sni_required_hosts)

  local f w
  for f in "${failures[@]}"; do
    echo "[mtproxy-sni] FAIL: ${f}" >&2
  done
  for w in "${warnings[@]}"; do
    echo "[mtproxy-sni] WARN: ${w}" >&2
  done

  [[ ${#failures[@]} -eq 0 ]]
}

# mtproxy_sni_openssl_peer_cn <host> <sni> [port]
# Returns peer CN via stdout; exit 2 if openssl unavailable.
mtproxy_sni_openssl_peer_cn() {
  local host="$1" sni="$2" port="${3:-443}"
  local subject cn

  if ! command -v openssl >/dev/null 2>&1; then
    return 2
  fi

  subject="$(echo | timeout 5 openssl s_client -connect "${host}:${port}" -servername "${sni}" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null || true)"
  cn="$(sed -n 's/^subject=.*CN[[:space:]]*=[[:space:]]*//p' <<<"${subject}" | head -1 | sed 's/[[:space:]].*//')"
  printf '%s' "${cn}"
}

# mtproxy_sni_cert_is_site_backend <cn> <snippet>
# True when CN looks like a site vhost cert (mis-routed MTProxy SNI).
mtproxy_sni_cert_is_site_backend() {
  local cn="$1" snippet="$2"
  local site base

  [[ -n "${cn}" ]] || return 1

  while IFS= read -r site; do
    [[ -n "${site}" ]] || continue
    if [[ "${cn}" == "${site}" ]]; then
      return 0
    fi
    base="${site#www.}"
    if [[ "${cn}" == "${base}" || "${cn}" == "*.${base}" ]]; then
      return 0
    fi
  done < <(mtproxy_sni_nginx_site_hosts "${snippet}")

  return 1
}

# mtproxy_sni_cert_is_teleproxy_fake_tls <cn>
mtproxy_sni_cert_is_teleproxy_fake_tls() {
  local cn="$1"
  [[ -n "${cn}" ]] || return 1
  case "${cn}" in
    *.google.com|google.com|www.google.com) return 0 ;;
  esac
  [[ "${cn}" == *google* ]]
}

# mtproxy_sni_tls_probe <snippet> [connect_host]
# Active :443 SNI probes; prints [mtproxy-sni] FAIL/WARN; returns 0 when no FAIL.
mtproxy_sni_tls_probe() {
  local snippet="${1:-${NGINX_STREAM_SNIPPET:-/etc/nginx/stream.d/vpn-bridge-443.conf}}"
  local connect_host="${2:-127.0.0.1}"
  local external_port="${MTPROXY_EXTERNAL_PORT:-443}"
  local -a failures=() warnings=()
  local host cn

  if ! command -v openssl >/dev/null 2>&1; then
    echo "[mtproxy-sni] WARN: openssl not installed — skip :443 SNI TLS probes" >&2
    return 0
  fi

  local tcp_ok=0
  if [[ "${MTPROXY_SNI_PROBE_SKIP_TCP:-}" == "1" ]]; then
    tcp_ok=1
  elif timeout 2 bash -c "exec 3<>/dev/tcp/${connect_host}/${external_port}" 2>/dev/null; then
    tcp_ok=1
  else
    failures+=("TCP ${connect_host}:${external_port} unreachable for SNI probe")
  fi

  if [[ "${tcp_ok}" == "1" ]]; then
    while IFS= read -r host; do
      [[ -n "${host}" ]] || continue
      cn="$(mtproxy_sni_openssl_peer_cn "${connect_host}" "${host}" "${external_port}" || true)"
      if [[ -z "${cn}" ]]; then
        warnings+=("SNI ${host} on :${external_port}: no TLS peer CN (timeout or non-TLS backend)")
      elif mtproxy_sni_cert_is_site_backend "${cn}" "${snippet}"; then
        failures+=("SNI ${host} on :${external_port} → site cert CN=${cn} (nginx map misroute)")
      elif ! mtproxy_sni_cert_is_teleproxy_fake_tls "${cn}"; then
        failures+=("SNI ${host} on :${external_port} → CN=${cn} (expected teleproxy Fake-TLS, not site)")
      fi
    done < <(mtproxy_sni_required_hosts)
  fi

  local f w
  for f in "${failures[@]}"; do
    echo "[mtproxy-sni] FAIL: ${f}" >&2
  done
  for w in "${warnings[@]}"; do
    echo "[mtproxy-sni] WARN: ${w}" >&2
  done

  [[ ${#failures[@]} -eq 0 ]]
}

# mtproxy_sni_run_checks [snippet] [connect_host]
# Lint + TLS probe; returns 0 when no FAIL (WARN allowed).
mtproxy_sni_run_checks() {
  local snippet="${1:-${NGINX_STREAM_SNIPPET:-/etc/nginx/stream.d/vpn-bridge-443.conf}}"
  local connect_host="${2:-127.0.0.1}"
  local rc=0

  mtproxy_sni_nginx_lint "${snippet}" || rc=1
  mtproxy_sni_tls_probe "${snippet}" "${connect_host}" || rc=1
  return "${rc}"
}
