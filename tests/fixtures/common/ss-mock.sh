#!/usr/bin/env bash
# Composable ss mock for preflight port probes.
#
# contract:
#   ss -Hltn | -Hlun | -Hltnp | -Hlunp
#
# env:
#   SS_MOCK_PORTS — comma-separated proto:port entries (e.g. tcp:8444,tcp:443)
#   SS_MOCK_PROCESS_<proto>_<port> — process name in users:(("name",…)) for -p mode
#                                    (e.g. SS_MOCK_PROCESS_tcp_8444=vpn-teleproxy)
#
# consumers: test_preflight_mtproxy_port
set -euo pipefail

want_tcp=0
want_udp=0
want_names=0

for arg in "$@"; do
  case "${arg}" in
    -*) 
      [[ "${arg}" == *t* ]] && want_tcp=1
      [[ "${arg}" == *u* ]] && want_udp=1
      [[ "${arg}" == *p* ]] && want_names=1
      ;;
  esac
done

[[ "${want_tcp}" -eq 0 && "${want_udp}" -eq 0 ]] && want_tcp=1

_process_for() {
  local proto="$1" port="$2" var
  var="SS_MOCK_PROCESS_${proto}_${port}"
  var="${var//./_}"
  printf '%s' "${!var:-unknown}"
}

_emit_port() {
  local proto="$1" port="$2" proc
  proc="$(_process_for "${proto}" "${port}")"
  if [[ "${want_names}" -eq 1 ]]; then
    printf 'LISTEN 0 128 *:%s users:(("%s",pid=1,fd=1))\n' "${port}" "${proc}"
  else
    printf 'LISTEN 0 128 *:%s\n' "${port}"
  fi
}

if [[ -z "${SS_MOCK_PORTS:-}" ]]; then
  exit 0
fi

IFS=',' read -r -a entries <<< "${SS_MOCK_PORTS}"
for entry in "${entries[@]}"; do
  entry="${entry// /}"
  [[ -z "${entry}" ]] && continue
  proto="${entry%%:*}"
  port="${entry#*:}"
  case "${proto}" in
    tcp) [[ "${want_tcp}" -eq 1 ]] && _emit_port tcp "${port}" ;;
    udp) [[ "${want_udp}" -eq 1 ]] && _emit_port udp "${port}" ;;
  esac
done

exit 0
