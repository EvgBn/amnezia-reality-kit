#!/usr/bin/env bash
# Pull upstream container images not built by compose build (Teleproxy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/paths.sh
source "${SCRIPT_DIR}/../lib/paths.sh"

ENV_FILE="${1:-${ENV_FILE:-${DATA_DIR}/.env}}"
TELEPROXY_VERSION="${TELEPROXY_VERSION:-4.12.0}"
ENABLE_MTPROXY=0

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

ENABLE_MTPROXY="$(parse_bool "${ENABLE_MTPROXY:-}" 0)"
TELEPROXY_VERSION="${TELEPROXY_VERSION:-4.12.0}"

if [[ "${ENABLE_MTPROXY}" != "1" ]]; then
  echo "[images] MTProxy disabled — skip teleproxy pull"
  exit 0
fi

IMAGE="ghcr.io/teleproxy/teleproxy:${TELEPROXY_VERSION}"
echo "[images] pulling ${IMAGE}"
docker pull "${IMAGE}"
