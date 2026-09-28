#!/usr/bin/env bash
# .env on-disk contract (I1/I2):
#   I1 — files written by the kit must be safe for: set -a; source file; set +a
#   I2 — endpoint tuples (IN_INGRESS, OUT_EXIT, …) on disk: 'FAMILY; ADDRESS' or auto
# All kit writers use env_file_set / env_file_quote_value (not raw sed with unescaped values).

# env_file_quote_value VAL — shell word for .env (matches extract-env.py q() + ';' for tuples).
env_file_quote_value() {
  local val="${1-}"
  if [[ "${val}" =~ [[:space:]\;#\"\'] ]] || [[ "${val}" == *\\* ]]; then
    printf "'%s'" "${val//\'/\'\\\'\'}"
  else
    printf '%s' "${val}"
  fi
}

# env_file_parse_value RAW — strip comment, trim, unwrap quotes (COPY_FROM / quoted .env lines).
env_file_parse_value() {
  local raw="${1-}" val
  val="${raw%%#*}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ "${#val}" -ge 2 && "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "${#val}" -ge 2 && "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "${val}"
}

# env_file_set FILE KEY VAL — replace or append KEY=quoted(VAL).
env_file_set() {
  local file="$1" key="$2" val="${3-}"
  local quoted line tmp found=0
  [[ -n "${file}" && -n "${key}" ]] || return 1
  quoted="$(env_file_quote_value "${val}")"
  line="${key}=${quoted}"
  tmp="$(mktemp "${file}.envset.XXXXXX")"
  if [[ -f "${file}" ]]; then
    while IFS= read -r ln || [[ -n "${ln}" ]]; do
      if [[ "${ln}" == "${key}="* ]]; then
        printf '%s\n' "${line}"
        found=1
      else
        printf '%s\n' "${ln}"
      fi
    done < "${file}" > "${tmp}"
  fi
  if [[ "${found}" -eq 0 ]]; then
    printf '%s\n' "${line}" >> "${tmp}"
  fi
  mv -f "${tmp}" "${file}"
}
