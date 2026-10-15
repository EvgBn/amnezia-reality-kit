#!/usr/bin/env bash
# Idempotent: add metrics-tick to user crontab (every 2 minutes).
set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_dir}/../lib/paths.sh"

_tick="${REPO_ROOT}/scripts/incident/metrics-tick.sh"
_line="*/2 * * * * ${_tick}"
_mark="amnezia-reality-kit metrics-tick"

chmod +x "${_tick}"

_tmp="$(mktemp)"
crontab -l 2>/dev/null | grep -v "${_mark}" > "${_tmp}" || true
printf '%s # %s\n' "${_line}" "${_mark}" >> "${_tmp}"
crontab "${_tmp}"
rm -f "${_tmp}"
echo "Installed: ${_line}"
