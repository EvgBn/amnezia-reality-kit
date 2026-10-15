# shellcheck shell=bash
# Test-only helpers for CSV v2. Source after incident-channel-lib.sh.

incident_test_csv_v2_map_defaults() {
  declare -gA INC_CSV_V2_FIELD
  local default="${1:-0}" name
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    INC_CSV_V2_FIELD["${name}"]="${default}"
  done <<<"$(tr ',' '\n' <<<"${INCIDENT_CSV_V2_HEADER}")"
}
