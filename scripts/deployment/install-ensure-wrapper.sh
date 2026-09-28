#!/usr/bin/env bash
# Install HOST_ENSURE_WRAPPER from repo template (called by deploy-host.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../lib/host-artifacts.sh
source "${SCRIPT_DIR}/../lib/host-artifacts.sh"

if [[ "${EUID}" -ne 0 ]]; then
  echo "install-ensure-wrapper: run as root" >&2
  exit 1
fi

SRC="${SCRIPT_DIR}/vpn-stack-ensure.sh"
DST="${HOST_ENSURE_WRAPPER}"

if [[ ! -f "${SRC}" ]]; then
  echo "install-ensure-wrapper: missing ${SRC}" >&2
  exit 1
fi

mkdir -p "$(dirname "${DST}")"
install -m 0755 "${SRC}" "${DST}"
