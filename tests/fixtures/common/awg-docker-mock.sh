#!/usr/bin/env bash
# AWG-aware docker CLI mock — extends common/docker-mock.sh for client scripts.
#
# contract:
#   docker ps [--format TEMPLATE]
#   docker exec vpn-amneziawg awg pubkey  (reads private key from stdin)
#   docker exec vpn-amneziawg sh -c '…syncconf…' | '…genkey…'
#
# env:
#   DOCKER_MOCK_PS              — ps output (default: vpn-amneziawg)
#   DOCKER_MOCK_AWG_PUBKEY_MAP  — newline "PRIVKEY=PUBKEY" map for awg pubkey
#   DOCKER_MOCK_AWG_DEFAULT_PUB — fallback pubkey (default: PUB_DROP)
#   DOCKER_MOCK_AWG_GENKEY_PRIV — genkey private output (default: NEW_PRIV)
#   DOCKER_MOCK_AWG_GENKEY_PUB  — genkey public output (default: NEW_PUB)
#
# consumers: test_awg_add_report, test_awg_remove_confirm, test_awg_remove_report
set -euo pipefail

_common="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker-mock.sh"

_awg_pubkey_for() {
  local priv="$1" line key pub
  if [[ -n "${DOCKER_MOCK_AWG_PUBKEY_MAP:-}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      key="${line%%=*}"
      pub="${line#*=}"
      if [[ "${priv}" == "${key}" ]]; then
        printf '%s' "${pub}"
        return 0
      fi
    done <<< "${DOCKER_MOCK_AWG_PUBKEY_MAP}"
  fi
  if [[ -f "${DOCKER_MOCK_AWG_PUBKEY_MAP_FILE:-}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      key="${line%%=*}"
      pub="${line#*=}"
      if [[ "${priv}" == "${key}" ]]; then
        printf '%s' "${pub}"
        return 0
      fi
    done < "${DOCKER_MOCK_AWG_PUBKEY_MAP_FILE}"
  fi
  printf '%s' "${DOCKER_MOCK_AWG_DEFAULT_PUB:-PUB_DROP}"
}

cmd="${1:-}"
shift || true

case "${cmd}" in
  ps)
    export DOCKER_MOCK_PS="${DOCKER_MOCK_PS:-vpn-amneziawg}"
    exec "${_common}" ps "$@"
    ;;
  exec)
    while [[ "${1:-}" == -* ]]; do
      shift || true
    done
    container="${1:-}"
    shift || true
    [[ "${container}" == "vpn-amneziawg" ]] || {
      echo "awg-docker-mock: unexpected container: ${container}" >&2
      exit 1
    }
    if [[ "${1:-}" == "awg" && "${2:-}" == "pubkey" ]]; then
      priv="$(cat || true)"
      _awg_pubkey_for "${priv}"
      exit 0
    fi
    if [[ "${1:-}" == "sh" ]]; then
      if [[ "${2:-}" == "-c" ]]; then
        local_cmd="${3:-}"
        if [[ "${local_cmd}" == *syncconf* ]]; then
          exit 0
        fi
        if [[ "${local_cmd}" == *genkey* ]]; then
          printf '%s\n%s\n' \
            "${DOCKER_MOCK_AWG_GENKEY_PRIV:-NEW_PRIV}" \
            "${DOCKER_MOCK_AWG_GENKEY_PUB:-NEW_PUB}"
          exit 0
        fi
      fi
      exit 0
    fi
    echo "awg-docker-mock: unsupported exec: ${container} $*" >&2
    exit 1
    ;;
  *)
    exec "${_common}" "${cmd}" "$@"
    ;;
esac
