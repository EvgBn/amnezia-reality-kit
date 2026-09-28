#!/usr/bin/env bash
# List saved MTProxy links in .data/clients_mtproxy/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/mtproxy-common.sh
source "${SCRIPT_DIR}/../../lib/mtproxy-common.sh"

if [[ -n "${MTPROXY_TEST_ROOT:-}" ]]; then
  MTPROXY_CLIENTS_DIR="${MTPROXY_TEST_ROOT}/clients_mtproxy"
fi

mtproxy_load_env

if [[ ! -d "${MTPROXY_CLIENTS_DIR}" ]] || ! compgen -G "${MTPROXY_CLIENTS_DIR}/*.txt" >/dev/null; then
  echo "No saved MTProxy links in ${MTPROXY_CLIENTS_DIR}"
  echo "Export one: make mtproxy-export NAME=<name>"
  exit 0
fi

printf '%-4s %-20s %-24s %-8s %s\n' '#' 'NAME' 'SERVER' 'PORT' 'SECRET'
n=0
for f in "${MTPROXY_CLIENTS_DIR}"/*.txt; do
  [[ -f "${f}" ]] || continue
  n=$((n + 1))
  base="$(basename "${f}" .txt)"
  server="$(sed -n 's/^SERVER=//p' "${f}" | tail -1)"
  port="$(sed -n 's/^PORT=//p' "${f}" | tail -1)"
  secret="$(sed -n 's/^SECRET=//p' "${f}" | tail -1)"
  printf '%-4s %-20s %-24s %-8s %s\n' "${n}" "${base}" "${server:-?}" "${port:-?}" "$(mtproxy_mask_secret "${secret}")"
done
