#!/usr/bin/env bash
# Loop make check for a dedicated monitoring terminal.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${ROOT}"

INTERVAL="${CHECK_WATCH_INTERVAL:-30}"
if ! [[ "${INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL}" -lt 1 ]]; then
  echo "[check-watch] CHECK_WATCH_INTERVAL must be a positive integer (got: ${INTERVAL})" >&2
  exit 1
fi

CHECK="${ROOT}/scripts/deployment/check.sh"
chmod +x "${CHECK}" scripts/preflight/run.sh scripts/preflight/phases/*.sh 2>/dev/null || true

trap 'printf "\n[check-watch] stopped\n"; exit 0' INT TERM

printf '[check-watch] repo=%s  interval=%ss' "${ROOT}" "${INTERVAL}"
if (($# > 0)); then
  printf '  phases=%s' "$*"
fi
printf '  (Ctrl+C to stop)\n\n'

while true; do
  if [[ -t 1 ]]; then
    clear
  fi
  date -Is 2>/dev/null || date
  printf '\n--- make check'
  if (($# > 0)); then
  printf ' %s' "$*"
  fi
  printf ' ---\n\n'

  "${CHECK}" "$@" || true

  printf '\n[check-watch] next in %ss' "${INTERVAL}"
  if ts="$(date -Is 2>/dev/null || date)"; then
    printf ' (%s)' "${ts}"
  fi
  printf '\n'
  sleep "${INTERVAL}"
done
