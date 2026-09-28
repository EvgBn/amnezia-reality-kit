#!/usr/bin/env bash
# OpenSSL mock for mtproxy SNI TLS probe tests.
#
# contract:
#   openssl s_client -connect … -servername <sni>
#   openssl x509 -noout -subject  (reads stdin; CN from last s_client -servername)
#
# env:
#   OPENSSL_MOCK_CN_MAP — newline "sni=CN" (e.g. google.com=*.google.com)
#   OPENSSL_MOCK_DEFAULT_CN — fallback CN (default: example.com)
#   OPENSSL_MOCK_CERT_FILE — PEM for s_client stdout (default: fixtures/data/openssl/dummy.pem)
#
# consumers: test_mtproxy_sni
set -euo pipefail

_mock_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_state_dir="${OPENSSL_MOCK_STATE_DIR:-${TMPDIR:-/tmp}/openssl-mock.$$}"
mkdir -p "${_state_dir}"

_cn_for_sni() {
  local sni="$1" line key cn
  if [[ -n "${OPENSSL_MOCK_CN_MAP:-}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      key="${line%%=*}"
      cn="${line#*=}"
      if [[ "${sni}" == "${key}" ]]; then
        printf '%s' "${cn}"
        return 0
      fi
    done <<< "${OPENSSL_MOCK_CN_MAP}"
  fi
  printf '%s' "${OPENSSL_MOCK_DEFAULT_CN:-example.com}"
}

case "${1:-}" in
  s_client)
    sni=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -servername) sni="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "${sni}" > "${_state_dir}/last-sni"
    cert="${OPENSSL_MOCK_CERT_FILE:-${_mock_dir}/data/openssl/dummy.pem}"
    cat "${cert}"
    exit 0
    ;;
  x509)
    if [[ "${2:-}" == "-noout" && "${3:-}" == "-subject" ]]; then
      sni="$(cat "${_state_dir}/last-sni" 2>/dev/null || true)"
      cn="$(_cn_for_sni "${sni}")"
      printf 'subject=CN = %s\n' "${cn}"
      exit 0
    fi
    ;;
esac

echo "openssl-mock: unsupported: $*" >&2
exit 1
