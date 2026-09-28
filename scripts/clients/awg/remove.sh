#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/awg-common.sh
source "${SCRIPT_DIR}/../../lib/awg-common.sh"

if [[ -n "${AWG_TEST_ROOT:-}" ]]; then
  AWG_CONF="${AWG_TEST_ROOT}/awg0.conf"
  AWG_CLIENTS_DIR="${AWG_TEST_ROOT}/clients_awg"
  AWG_LOCK="${AWG_CONF}.lock"
  ENV_FILE="${AWG_TEST_ROOT}/.env"
fi

# shellcheck source=remove-report.sh
source "${SCRIPT_DIR}/remove-report.sh"
# shellcheck source=remove-confirm.sh
source "${SCRIPT_DIR}/remove-confirm.sh"

readonly LIST_PEERS="${SCRIPT_DIR}/list-peers.py"
readonly REMOVE_PEER="${SCRIPT_DIR}/remove-peer.py"

peer_env() {
  export AWG_CONF AWG_CLIENTS_DIR
  if docker ps --format '{{.Names}}' | grep -qx "${AWG_CONTAINER}"; then
    export AWG_CONTAINER
  else
    unset AWG_CONTAINER
  fi
}

fetch_row_detail() {
  local mode="$1"
  local value="$2"
  local detail rc=0

  peer_env
  if [[ "${mode}" == "num" ]]; then
    detail=$(python3 "${LIST_PEERS}" --detail "${value}") || rc=$?
  else
    detail=$(python3 "${LIST_PEERS}" --detail-name "${value}") || rc=$?
  fi
  if (( rc != 0 )); then
    return "${rc}"
  fi
  printf '%s' "${detail}"
}

remove_peer() {
  local client_name="$1"
  local client_pubkey="${2:-}"

  local env_args=(AWG_CONF="${AWG_CONF}")
  if [[ -n "${client_pubkey}" ]]; then
    env_args+=(AWG_CLIENT_PUBKEY="${client_pubkey}")
  fi
  if [[ -n "${client_name}" && "${client_name}" != "<unnamed>" ]]; then
    env_args+=(AWG_CLIENT="${client_name}")
  fi

  env "${env_args[@]}" python3 "${REMOVE_PEER}"
}

do_remove() {
  local client_name="$1"
  local client_pubkey="${2:-}"
  local client_ip="${3:-}"
  local saved_export="${4:-}"
  local saved_runtime="${5:-}"
  local saved_pubkey_short="${6:-}"
  local client_conf=""

  if [[ "${client_name}" != "<unnamed>" ]]; then
    validate_client_name "${client_name}"
    client_conf="$(client_conf_path "${client_name}")"
    [[ -z "${saved_export}" && -n "${client_name}" ]] && saved_export="${client_name}.conf"
  elif [[ -z "${saved_export}" ]]; then
    saved_export="(no export)"
  fi

  load_env
  awg_require_container

  if [[ ! -f "${AWG_CONF}" ]]; then
    log_error "Missing ${AWG_CONF}."
    exit 1
  fi

  if [[ -z "${client_pubkey}" && -n "${client_conf}" && -f "${client_conf}" ]]; then
    local client_priv
    client_priv=$(awk '/^PrivateKey/{print $3; exit}' "${client_conf}")
    if [[ -n "${client_priv}" ]]; then
      client_pubkey=$(awg_client_public_key "${client_priv}")
    fi
  fi

  if [[ -z "${client_pubkey}" && ( -z "${client_conf}" || ! -f "${client_conf}" ) ]]; then
    log_error "Cannot resolve peer for '${client_name}' — use list # or ensure .conf exists."
    exit 1
  fi

  local peers_before rc=0
  peers_before=$(awg_peer_count)

  (
    flock -x 200 || { log_error "Could not acquire lock on ${AWG_CONF}"; exit 1; }
    remove_peer "${client_name}" "${client_pubkey}" || exit
  ) 200>"${AWG_LOCK}" || rc=$?

  if [[ "${rc}" -eq 3 ]]; then
    if [[ -n "${client_conf}" && ! -f "${client_conf}" ]]; then
      log_error "Client '${client_name}' not found (no peer in ${AWG_CONF}, no ${client_conf})."
      exit 1
    fi
    log_warn "No matching [Peer] in ${AWG_CONF} — removing client export only."
  elif [[ "${rc}" -ne 0 ]]; then
    log_error "Failed to update ${AWG_CONF} (exit ${rc})."
    exit "${rc}"
  fi

  if [[ -n "${client_conf}" ]]; then
    rm -f "${client_conf}"
  fi

  if [[ "${rc}" -ne 3 ]]; then
    awg_syncconf
    local peers_after
    peers_after=$(awg_peer_count)
    if (( peers_after != peers_before - 1 )); then
      log_error "Peer count mismatch after remove (before=${peers_before}, after=${peers_after})."
      exit 1
    fi
  fi

  show_remove_result \
    "${client_name}" \
    "${client_pubkey}" \
    "${client_ip}" \
    "${saved_export}" \
    "${saved_runtime}" \
    "${saved_pubkey_short}"
}

remove_by_num() {
  local num="$1"
  local detail name pubkey ip export runtime pubkey_short

  if ! [[ "${num}" =~ ^[0-9]+$ ]]; then
    log_error "Invalid number '${num}' — enter a row # from make awg-client-list."
    return 1
  fi

  if ! detail=$(fetch_row_detail num "${num}"); then
    return 1
  fi

  IFS=$'\t' read -r name pubkey ip export runtime pubkey_short <<< "${detail}"
  if [[ -z "${name}" || -z "${pubkey}" || -z "${ip}" ]]; then
    log_error "Could not resolve client #${num}."
    return 1
  fi

  echo "Removing #${num}: ${name} (${ip})"
  do_remove "${name}" "${pubkey}" "${ip}" "${export}" "${runtime}" "${pubkey_short}"
}

interactive_remove() {
  local choice

  peer_env
  python3 "${LIST_PEERS}"
  echo ""

  if [[ -z "${REMOVE_USE_STDIN:-}" && ! -e /dev/tty ]]; then
    log_error "No TTY available for interactive remove."
    exit 1
  fi

  while true; do
    remove_prompt_red 'Remove which client? Enter # from list (q to cancel): '
    remove_read choice
    choice="${choice// /}"

    case "${choice}" in
      q|Q|"")
        echo "Cancelled."
        exit 0
        ;;
      *[!0-9]*)
        remove_prompt 'Invalid input — enter a number or q.\n'
        ;;
      *)
        local detail name pubkey ip export runtime pubkey_short
        local expected_base typed

        if ! detail=$(fetch_row_detail num "${choice}"); then
          remove_prompt 'Try again (valid: 1–%s) or q to cancel.\n' "$(awg_peer_count)"
          continue
        fi

        IFS=$'\t' read -r name pubkey ip export runtime pubkey_short <<< "${detail}"
        expected_base="$(normalize_client_ip_base "${ip}")" || {
          log_error "Could not parse IP for client #${choice}."
          continue
        }

        remove_prompt 'Confirm IP for #%s (%s): ' "${choice}" "${name}"
        remove_read typed
        typed="${typed// /}"

        if ! client_ip_matches "${ip}" "${typed}"; then
          print_wrong_ip_error "${typed}" "${ip}" "${expected_base}"
          continue
        fi

        echo "Removing #${choice}: ${name} (${ip})"
        do_remove "${name}" "${pubkey}" "${ip}" "${export}" "${runtime}" "${pubkey_short}"
        return 0
        ;;
    esac
  done
}

remove_by_name() {
  local client_name="$1"
  local detail name pubkey ip export runtime pubkey_short

  if detail=$(fetch_row_detail name "${client_name}"); then
    IFS=$'\t' read -r name pubkey ip export runtime pubkey_short <<< "${detail}"
    echo "Removing: ${name} (${ip})"
    do_remove "${name}" "${pubkey}" "${ip}" "${export}" "${runtime}" "${pubkey_short}"
  else
    echo "Removing: ${client_name}"
    do_remove "${client_name}" "" "" "${client_name}.conf" "" ""
  fi
}

case "${1:-}" in
  --interactive)
    interactive_remove
    ;;
  --num)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 --num <#>" >&2
      exit 1
    fi
    remove_by_num "$2" || exit 1
    ;;
  --help|-h)
    cat <<EOF
Usage:
  $0 <client_name>     Remove by name (e.g. M, evg)
  $0 --num <#>         Remove by row # from make awg-client-list
  $0 --interactive     Pick from numbered list (TTY)
EOF
    ;;
  "")
    echo "Usage: $0 <client_name> | --num <#> | --interactive" >&2
    exit 1
    ;;
  *)
    remove_by_name "$1"
    ;;
esac
