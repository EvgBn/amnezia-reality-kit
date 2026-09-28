#!/usr/bin/env bash
# Legacy wrapper — delegates to common/curl-mock.sh.
#
# contract: curl -sf … (OUT_MOCK_CURL_IP)
# env: OUT_MOCK_CURL_IP
# consumers: test_preflight_out
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/curl-mock.sh" "$@"
