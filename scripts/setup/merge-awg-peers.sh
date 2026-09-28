#!/usr/bin/env bash
# Append [Peer] blocks from existing awg0.conf to rendered header.
set -euo pipefail

header="${1:?header file}"
existing="${2:-}"
output="${3:?output file}"

if [[ -n "$existing" && -f "$existing" ]] && grep -q '^\[Peer\]' "$existing"; then
  {
    cat "$header"
    echo
    awk '/^\[Peer\]/{found=1} found' "$existing"
  } > "$output"
else
  cp "$header" "$output"
fi

chmod 600 "$output"
