#!/usr/bin/env bash
# Mock modprobe for kmod-remove integration tests.
#
# contract:
#   modprobe -r amneziawg  (logs to MODPROBE_MOCK_LOG, updates PROC_MODULES)
#
# env:
#   MODPROBE_MOCK_LOG — append log path
#   PROC_MODULES — optional /proc/modules stub file
#
# consumers: test_host_remove_integration
set -euo pipefail

MODPROBE_MOCK_LOG="${MODPROBE_MOCK_LOG:-/dev/null}"

if [[ "${1:-}" == "-r" && "${2:-}" == "amneziawg" ]]; then
  printf '%s\n' "modprobe -r amneziawg" >> "${MODPROBE_MOCK_LOG}"
  if [[ -n "${PROC_MODULES:-}" && -f "${PROC_MODULES}" ]]; then
    grep -v '^amneziawg ' "${PROC_MODULES}" > "${PROC_MODULES}.tmp" || true
    mv "${PROC_MODULES}.tmp" "${PROC_MODULES}"
  fi
  exit 0
fi

echo "modprobe-mock: unsupported: $*" >&2
exit 1
