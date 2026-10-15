# shellcheck shell=bash
# Markdown RCA report from metrics CSV v2 + events.jsonl (schema stats via channel-lib).

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=incident-channel-lib.sh
source "${_lib_dir}/incident-channel-lib.sh"
unset _lib_dir

incident_channel_report_markdown() {
  local day="$1" metrics_dir="$2" events_dir="$3"
  local csv="${metrics_dir}/${day}.csv"
  local ev="${events_dir}/${day}.jsonl"

  echo "# Incident channel report — ${day} (UTC)"
  echo
  echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo

  if [[ -f "${ev}" ]]; then
    echo "## Events"
    echo
    echo '```json'
    cat "${ev}"
    echo '```'
    echo
  else
    echo "## Events"
    echo
    echo "(no ${ev})"
    echo
  fi

  if [[ ! -f "${csv}" ]]; then
    echo "## Metrics CSV"
    echo
    echo "(no ${csv} — enable cron: \`*/2 * * * * .../metrics-tick.sh\`)"
    return 0
  fi

  echo "## Metrics CSV (last 40 rows)"
  echo
  echo '```csv'
  tail -n 40 "${csv}"
  echo '```'
  echo

  echo "## Quick stats (today)"
  echo
  local n_fail n_ok max_conn max_inject
  read -r n_fail n_ok max_conn max_inject <<<"$(incident_metrics_csv_v2_quick_stats "${csv}")"
  echo "- ticks with socks_ok=0: **${n_fail}**"
  echo "- ticks with socks_ok=1: **${n_ok}**"
  echo "- max awg_socks_conn: **${max_conn}**"
  echo "- max inject_fail_delta (2.5m window): **${max_inject}**"
  echo
  echo "Run \`make incident-snapshot\` while symptoms are visible; compare event times with this CSV."
}
