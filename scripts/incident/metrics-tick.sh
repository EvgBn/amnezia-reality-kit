#!/usr/bin/env bash
# Append one CSV row for incident RCA time-series (run from cron every 1–5 min).
#
#   */1 * * * * /home/evg/pub/amnezia-reality-kit/scripts/incident/metrics-tick.sh
#
# Output: ~/log/metrics/YYYY-MM-DD.csv (created with header on first write).
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_dir}/../lib/paths.sh"
# shellcheck source=../lib/incident-snapshot-lib.sh
source "${REPO_ROOT}/scripts/lib/incident-snapshot-lib.sh"
unset _script_dir

METRICS_DIR="${INCIDENT_METRICS_DIR:-${HOME}/log/metrics}"
AWG_CONTAINER="${VPN_AWG_CONTAINER:-vpn-amneziawg}"
COREDNS_CONTAINER="${VPN_COREDNS_CONTAINER:-vpn-coredns}"
XRAY_CONTAINER="${VPN_XRAY_CONTAINER:-vpn-xray}"
NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-100}"

ENV_FILE="${ENV_FILE:-${DATA_DIR}/.env}"
SOCKS_PORT="1080"
XRAY_IP="${XRAY_IP:-10.200.97.4}"
SOCKS_USER=""
SOCKS_PASSWORD=""

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}" 2>/dev/null || true
  set +a
  SOCKS_PORT="${SOCKS_PORT:-1080}"
  XRAY_IP="${XRAY_IP:-10.200.97.4}"
  NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-${NFQUEUE_NUM}}"
fi

mkdir -p "${METRICS_DIR}"
_day="$(date -u '+%Y-%m-%d')"
_csv="${METRICS_DIR}/${_day}.csv"

_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
_coredns_health="$(docker inspect "${COREDNS_CONTAINER}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null || echo n/a)"
_streak="$(docker inspect "${COREDNS_CONTAINER}" --format '{{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}0{{end}}' 2>/dev/null || echo 0)"
_swap="$(incident_swap_used_mb)"
_load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo n/a)"
_socks_conn="$(incident_awg_socks_conn_count "${AWG_CONTAINER}" "${XRAY_IP}" "${SOCKS_PORT}")"
_fd_awg="$(incident_ipt2socks_max_fd "${AWG_CONTAINER}")"
_fd_cd="$(incident_ipt2socks_max_fd "${COREDNS_CONTAINER}")"
_nfq="$(incident_iptables_pkts_field "$(incident_awg_nfqueue_pkts "${AWG_CONTAINER}" "${NFQUEUE_NUM}")")"

_cold_ms="n/a"
if docker inspect "${COREDNS_CONTAINER}" >/dev/null 2>&1; then
  _probe="probe-$(date +%s).invalid.example.com"
  _cold_ms="$(docker exec "${COREDNS_CONTAINER}" dig @127.0.0.1 +norecurse +time=5 +tries=1 "${_probe}" A +stats 2>/dev/null \
    | awk '/Query time:/ {print $4; exit}' || echo n/a)"
fi

_socks_ms="n/a"
if [[ -n "${SOCKS_USER:-}" && -n "${SOCKS_PASSWORD:-}" ]]; then
  _socks_ms="$(curl -4 -sS -m 10 -x "socks5h://127.0.0.1:${SOCKS_PORT}" \
    --proxy-user "${SOCKS_USER}:${SOCKS_PASSWORD}" \
    -o /dev/null -w '%{time_total}' "${PREFLIGHT_OUT_EGRESS_URL:-https://api.ipify.org}" 2>/dev/null || echo fail)"
fi

if [[ ! -f "${_csv}" ]]; then
  echo "ts_utc,coredns_health,coredns_streak,swap_used_mb,load1,awg_socks_conn,fd_awg_max,fd_coredns_max,nfqueue_pkts,cold_dig_ms,socks_curl_s" > "${_csv}"
  chmod 600 "${_csv}" 2>/dev/null || true
fi

echo "${_ts},${_coredns_health},${_streak},${_swap},${_load},${_socks_conn},${_fd_awg},${_fd_cd},${_nfq},${_cold_ms},${_socks_ms}" >> "${_csv}"
