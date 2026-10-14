# shellcheck shell=bash
# Shared helpers for scripts/incident/collect-snapshot.sh (make incident-snapshot).
# No secrets; safe to source from operator scripts.

# Packet count from iptables -L -v -n -x (first field, digits only).
incident_iptables_pkts_field() {
  local field="${1:-0}"
  field="${field//,/}"
  if [[ "${field}" =~ ^[0-9]+$ ]]; then
    echo "${field}"
  else
    echo "0"
  fi
}

# NFQUEUE rule packet count on awg0 (canonical for incident snapshots).
incident_awg_nfqueue_pkts() {
  local container="$1" q="$2"
  docker exec "${container}" iptables -t mangle -L PREROUTING -v -n -x 2>/dev/null \
    | awk -v q="${q}" '/NFQUEUE/ && $0 ~ q {print $1; exit}'
}

incident_container_date_utc() {
  local container="$1"
  docker exec "${container}" date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || echo "(date unavailable in ${container})"
}

# SOCKS TCP connections to xray from inside awg (requires ss in container).
incident_awg_socks_conn_count() {
  local awg="$1" xray_ip="$2" port="${3:-1080}"
  docker exec "${awg}" sh -c "ss -tn 2>/dev/null | grep -c '${xray_ip}:${port}'" 2>/dev/null \
    || echo "n/a"
}

incident_ipt2socks_max_fd() {
  local container="$1"
  docker exec "${container}" sh -c '
    m=0
    for p in $(pgrep -x ipt2socks 2>/dev/null); do
      n=$(ls -1 /proc/$p/fd 2>/dev/null | wc -l | tr -d " ")
      [ "$n" -gt "$m" ] && m=$n
    done
    echo "$m"
  ' 2>/dev/null || echo "n/a"
}

incident_swap_used_mb() {
  free -m 2>/dev/null | awk '/^Swap:/ {print $3}' || echo "n/a"
}

# OUT TCP connect probe from xray netns (best-effort).
incident_xray_tcp_probe() {
  local xray="$1" host="$2" port="${3:-443}"
  docker exec "${xray}" sh -c "
    if command -v nc >/dev/null 2>&1; then
      nc -z -w5 $(printf '%q' "${host}") ${port} && echo ok
    elif command -v wget >/dev/null 2>&1; then
      wget -q --spider --timeout=5 $(printf '%q' "https://${host}:${port}/") 2>/dev/null && echo ok
    else
      echo skip_no_nc_wget
    fi
  " 2>/dev/null || echo "fail"
}
