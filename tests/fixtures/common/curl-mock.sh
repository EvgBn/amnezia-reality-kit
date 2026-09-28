#!/usr/bin/env bash
# Composable curl mock for unit tests.
#
# contract:
#   curl -sf …  — prints OUT_MOCK_CURL_IP / CURL_MOCK_IP and exits 0
#                 exits 1 when unset
#
# env:
#   OUT_MOCK_CURL_IP — IPv4 to print (preferred)
#   CURL_MOCK_IP     — alias for OUT_MOCK_CURL_IP
#
# consumers: test_preflight_out, test_mtproxy_smoke (inline override still used)
set -euo pipefail

ip="${OUT_MOCK_CURL_IP:-${CURL_MOCK_IP:-}}"
if [[ -z "${ip}" ]]; then
  exit 1
fi
printf '%s\n' "${ip}"
