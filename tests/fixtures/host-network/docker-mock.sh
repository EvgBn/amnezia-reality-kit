#!/usr/bin/env bash
# Host-remove docker mock — delegates ps to common/docker-mock.sh.
#
# contract:
#   docker ps --format TEMPLATE
#
# env:
#   DOCKER_MOCK_PS — container name(s), newline-separated
#
# consumers: test_host_network_remove, test_host_remove_integration
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/docker-mock.sh" "$@"
