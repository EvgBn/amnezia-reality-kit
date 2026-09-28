#!/usr/bin/env bash
# Shared post-remove report — sourced by remove.sh and unit tests.
show_remove_result() {
  local name="$1"
  local pubkey="$2"
  local ip="$3"
  local export_file="$4"
  local runtime="$5"
  local pubkey_short="${6:-}"

  if [[ -z "${pubkey_short}" && -n "${pubkey}" ]]; then
    if ((${#pubkey} > 13)); then
      pubkey_short="${pubkey:0:8}…${pubkey: -4}"
    else
      pubkey_short="${pubkey}"
    fi
  fi

  echo ""
  if [[ -t 1 ]]; then
    printf '\033[31m=== Removed ===\033[0m\n'
  else
    echo "=== Removed ==="
  fi
  printf '  Name:       %s\n' "${name}"
  printf '  IP:         %s\n' "${ip:-?}"
  printf '  Client key: %s\n' "${pubkey_short:-?}"
  if [[ -n "${pubkey}" && "${pubkey_short}" != "${pubkey}" ]]; then
    printf '              (%s)\n' "${pubkey}"
  fi
  printf '  Export:     %s\n' "${export_file:-?}"
  printf '  Runtime:    %s\n' "${runtime:-?}"
  echo ""
  echo "=== AWG clients (updated) ==="
  echo ""
  peer_env
  python3 "${LIST_PEERS}"
}
