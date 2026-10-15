#!/usr/bin/env bash
# Append one CSV v2 row + optional events.jsonl (run from cron every 2 min).
#
#   */2 * * * * /home/evg/pub/amnezia-reality-kit/scripts/incident/metrics-tick.sh
#
# Output: ~/log/metrics/YYYY-MM-DD.csv, ~/log/events/YYYY-MM-DD.jsonl
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_dir}/../lib/paths.sh"
# shellcheck source=../lib/incident-udp-log-patterns.sh
source "${REPO_ROOT}/scripts/lib/incident-udp-log-patterns.sh"
# shellcheck source=../lib/incident-snapshot-lib.sh
source "${REPO_ROOT}/scripts/lib/incident-snapshot-lib.sh"
# shellcheck source=../lib/incident-channel-lib.sh
source "${REPO_ROOT}/scripts/lib/incident-channel-lib.sh"
# shellcheck source=../lib/incident-metrics-collect-lib.sh
source "${REPO_ROOT}/scripts/lib/incident-metrics-collect-lib.sh"
unset _script_dir

METRICS_DIR="${INCIDENT_METRICS_DIR:-${HOME}/log/metrics}"
EVENTS_DIR="${INCIDENT_EVENTS_DIR:-${HOME}/log/events}"
AWG_CONTAINER="${VPN_AWG_CONTAINER:-vpn-amneziawg}"
COREDNS_CONTAINER="${VPN_COREDNS_CONTAINER:-vpn-coredns}"
XRAY_CONTAINER="${VPN_XRAY_CONTAINER:-vpn-xray}"
TELEPROXY_CONTAINER="${VPN_TELEPROXY_CONTAINER:-vpn-teleproxy}"
NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-100}"
CLIENT_IP="${CLIENT_IP:-10.8.0.7}"
MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT:-8888}"

ENV_FILE="${ENV_FILE:-${DATA_DIR}/.env}"
SOCKS_PORT="1080"
XRAY_IP="${XRAY_IP:-10.200.97.4}"
TELEPROXY_IP="${TELEPROXY_IP:-10.200.97.5}"
COREDNS_IP="${COREDNS_IP:-10.200.97.2}"
SOCKS_USER=""
SOCKS_PASSWORD=""
OUT_EXIT_ADDRESS=""
OUT_REALITY_PORT="443"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}" 2>/dev/null || true
  set +a
  SOCKS_PORT="${SOCKS_PORT:-1080}"
  XRAY_IP="${XRAY_IP:-10.200.97.4}"
  TELEPROXY_IP="${TELEPROXY_IP:-10.200.97.5}"
  COREDNS_IP="${COREDNS_IP:-10.200.97.2}"
  NFQUEUE_NUM="${AWG_NFQUEUE_NUM:-${NFQUEUE_NUM}}"
  MTPROXY_STATS_PORT="${MTPROXY_STATS_PORT:-8888}"
  if [[ -f "${REPO_ROOT}/scripts/lib/endpoint.sh" ]]; then
    # shellcheck source=../lib/endpoint.sh
    source "${REPO_ROOT}/scripts/lib/endpoint.sh"
    ENDPOINT_RESOLVE_QUIET=1 endpoint_resolve_env 2>/dev/null || true
  fi
  OUT_REALITY_PORT="${OUT_REALITY_PORT:-443}"
fi

mkdir -p "${METRICS_DIR}" "${EVENTS_DIR}"
_lock="${METRICS_DIR}/.tick.lock"
exec 9>"${_lock}"
if ! flock -n 9; then
  echo "metrics-tick: lock busy (${_lock}), skipping tick" >&2
  exit 0
fi

_day="$(date -u '+%Y-%m-%d')"
_csv="${METRICS_DIR}/${_day}.csv"
_events="${EVENTS_DIR}/${_day}.jsonl"
_state_path="$(incident_tick_state_path "${METRICS_DIR}")"
_eval_state="${METRICS_DIR}/.tick-eval-state"

incident_metrics_ensure_v2_csv "${_csv}"

incident_metrics_tick_collect "${_state_path}"

incident_channel_eval_events "${_events}" "${INC_METRICS_TS}" "${INC_METRICS_SOCKS_OK}" \
  "${INC_METRICS_COLD_INT}" "${INC_METRICS_STREAK}" "${INC_METRICS_INJECT_D}" \
  "${INC_METRICS_P2P_D}" "${INC_METRICS_ONE_WAY_D}" "${_eval_state}"

incident_tick_state_save "${_state_path}" "${INC_METRICS_TS}" \
  "${INC_METRICS_NFQ_NOW}" "${INC_METRICS_PEER_RX_NOW}" "${INC_METRICS_PEER_TX_NOW}" \
  "${INC_METRICS_MT_NOW}"

echo "${INC_METRICS_ROW}" >> "${_csv}"
incident_metrics_collect_clear
