#!/usr/bin/env bash
# Unit tests for compose local image hints (ipt2socks before make start).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=../../scripts/lib/compose-images.sh
source "${REPO_ROOT}/scripts/lib/compose-images.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

compose_ipt2socks_image_present() { return 1; }
compose_docker_usable() { return 0; }
[[ "$(compose_stack_start_hint)" == "make images && make start" ]] \
  || fail "missing ipt2socks should suggest images && start"

compose_ipt2socks_image_present() { return 0; }
[[ "$(compose_stack_start_hint)" == "make start" ]] \
  || fail "present ipt2socks should suggest make start only"

compose_ipt2socks_image_present() { return 1; }
compose_docker_usable() { return 1; }
[[ "$(compose_stack_start_hint)" == "make start" ]] \
  || fail "no docker should fall back to make start"

[[ "$(compose_ipt2socks_image_ref)" == "zfl9/ipt2socks:latest" ]] \
  || fail "default ipt2socks ref"

echo "OK: test_compose_images"
