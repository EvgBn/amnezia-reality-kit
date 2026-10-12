#!/usr/bin/env bash
# Unit tests for preflight OS memory thresholds (make images / deploy-host).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck source=../../scripts/preflight/lib/os_memory.sh
source "${REPO_ROOT}/scripts/preflight/lib/os_memory.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1 GiB RAM, no swap — target WARN profile
preflight_os_memory_sufficient 1048576 0 && fail "1G RAM only should be insufficient"

# 1.75 GiB RAM (A)
preflight_os_memory_sufficient "${PREFLIGHT_MEM_RAM_OK_KB}" 0 || fail "1.75G RAM should pass (A)"

# 512M RAM + 900M swap — below combined threshold
preflight_os_memory_sufficient 524288 921600 && fail "512M RAM + 900M swap should fail (below C)"

# 512M RAM + 1 GiB swap (B)
preflight_os_memory_sufficient 524288 "${PREFLIGHT_MEM_SWAP_OK_KB}" || fail "512M + 1G swap should pass (B)"

# ~1.8 GiB + ~900 MiB swap (unkpspb-class) — passes via (C)
preflight_os_memory_sufficient 1887436 920576 || fail "1.8G+900M should pass (C)"

# 1.5G + 1G swap — passes (B) and (C)
preflight_os_memory_sufficient 1572864 1048576 || fail "1.5G+1G should pass (B or C)"
preflight_os_memory_sufficient 1572864 1048575 && fail "1.5G + swap 1G-1KiB should fail (below C, swap below B)"

echo "OK: test_preflight_os_memory"
