#!/usr/bin/env bash
# IP confirmation helpers for interactive AWG client remove.
# shellcheck disable=SC2034

# normalize_client_ip_base <ip> — print dotted-quad without suffix; return 1 if invalid.
normalize_client_ip_base() {
  local ip="${1// /}"
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?$ ]]; then
    return 1
  fi
  ip="${ip%%/*}"
  printf '%s' "${ip}"
}

# client_ip_matches <expected_ip> <typed_ip>
client_ip_matches() {
  local expected="$1" typed="$2"
  local eb tb
  eb="$(normalize_client_ip_base "${expected}")" || return 1
  tb="$(normalize_client_ip_base "${typed}")" || return 1
  [[ "${eb}" == "${tb}" ]]
}

# print_wrong_ip_error <typed> <expected_full> <expected_base>
print_wrong_ip_error() {
  local typed="$1" expected_full="$2" expected_base="$3"
  local msg="Wrong IP. You entered: ${typed:-<empty>}. Expected: ${expected_base} (or ${expected_full})."
  if [[ -t 2 ]]; then
    printf '\033[31m%s\033[0m\n' "${msg}" >&2
  else
    printf '%s\n' "${msg}" >&2
  fi
}

# remove_read <varname> — TTY by default; REMOVE_USE_STDIN=1 reads stdin (tests only).
remove_read() {
  local __var="$1"
  if [[ -n "${REMOVE_USE_STDIN:-}" ]]; then
    # shellcheck disable=SC2162
    read -r "${__var}"
  else
    # shellcheck disable=SC2162
    read -r "${__var}" </dev/tty
  fi
}

# remove_prompt <format> [args...]
remove_prompt() {
  if [[ -n "${REMOVE_USE_STDIN:-}" ]]; then
    # shellcheck disable=SC2059
    printf "$@"
  else
    # shellcheck disable=SC2059
    printf "$@" >/dev/tty
  fi
}

# remove_prompt_red — interactive remove question (red in TTY).
remove_prompt_red() {
  if [[ -n "${REMOVE_USE_STDIN:-}" ]]; then
    # shellcheck disable=SC2059
    printf "$@"
  elif [[ -e /dev/tty ]]; then
    # shellcheck disable=SC2059
    printf '\033[31m' >/dev/tty
    # shellcheck disable=SC2059
    printf "$@" >/dev/tty
    # shellcheck disable=SC2059
    printf '\033[0m' >/dev/tty
  else
    # shellcheck disable=SC2059
    printf "$@"
  fi
}
