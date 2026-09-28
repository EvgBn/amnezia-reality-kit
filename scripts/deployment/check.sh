#!/usr/bin/env bash
# Back-compat wrapper — implementation lives in scripts/preflight/.
exec "$(cd "$(dirname "$0")/../preflight" && pwd)/run.sh" "$@"
