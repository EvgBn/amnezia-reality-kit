#!/usr/bin/env bash
# Preflight output: counters, colors, emit(), phase_header(), print_summary().
# Sourced by run.sh — expects VERBOSE, JSON, REPO_ROOT set.

: "${C_OK:=0}" "${C_WARN:=0}" "${C_FAIL:=0}" "${C_SKIP:=0}"
declare -a JSON_ITEMS=()

# ANSI escapes (more reliable than tput sgr0 on some terminals)
C_GREEN=''
C_ORANGE=''
C_RED=''
C_DIM=''
C_RESET=''

preflight_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_GREEN=$'\033[1;32m'
    C_ORANGE=$'\033[38;5;208;1m'  # orange; terminals without 256c may ignore 208
    C_RED=$'\033[1;31m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
  else
    C_GREEN=''
    C_ORANGE=''
    C_RED=''
    C_DIM=''
    C_RESET=''
  fi
}

emit() {
  local status="$1" phase="$2" name="$3" detail="$4" fix="${5:-}"
  local tag hint

  case "${status}" in
    OK)   C_OK=$((C_OK + 1))   ; tag="${C_GREEN}OK${C_RESET}" ;;
    WARN) C_WARN=$((C_WARN + 1)) ; tag="${C_ORANGE}WARN${C_RESET}" ;;
    FAIL) C_FAIL=$((C_FAIL + 1)) ; tag="${C_RED}FAIL${C_RESET}" ;;
    SKIP) C_SKIP=$((C_SKIP + 1)) ; tag="${C_DIM}SKIP${C_RESET}" ;;
    *) log_error "preflight: bad status ${status}"; return 1 ;;
  esac

  if [[ "${JSON}" -eq 1 ]]; then
    JSON_ITEMS+=("$(printf '{"status":"%s","phase":"%s","name":"%s","detail":"%s","fix":"%s"}' \
      "${status}" "${phase}" "${name}" "${detail}" "${fix}")")
    return 0
  fi

  if [[ "${status}" == "OK" || "${status}" == "SKIP" ]] && [[ "${VERBOSE}" -eq 0 ]]; then
    return 0
  fi

  hint=""
  [[ -n "${fix}" ]] && hint="  ${C_DIM}→ ${fix}${C_RESET}"
  printf '[%s] %-8s %-28s %s%s\n' "${tag}" "${phase}" "${name}" "${detail}" "${hint}"
}

# WARN → FAIL when CHECK_STRICT=1 / --strict (CI/staging gate).
preflight_emit() {
  local status="$1"
  if [[ "${PREFLIGHT_STRICT:-0}" == 1 && "${status}" == WARN ]]; then
    status=FAIL
  fi
  emit "${status}" "$2" "$3" "$4" "${5:-}"
}

phase_header() {
  [[ "${JSON}" -eq 1 ]] && return 0
  printf '\n%s── %s ──%s\n' "${C_DIM}" "$1" "${C_RESET}"
}

preflight_print_summary() {
  if [[ "${JSON}" -eq 1 ]]; then
    printf '[%s]\n' "$(IFS=,; echo "${JSON_ITEMS[*]}")"
    printf '{"ok":%s,"warn":%s,"fail":%s,"skip":%s}\n' "${C_OK}" "${C_WARN}" "${C_FAIL}" "${C_SKIP}"
    return
  fi

  printf '\n%s=== Summary ===%s\n' "${C_DIM}" "${C_RESET}"
  printf 'OK: %s  ' "${C_OK}"
  if [[ "${C_WARN}" -gt 0 ]]; then
    printf '%sWARN:%s %s  ' "${C_ORANGE}" "${C_RESET}" "${C_WARN}"
  else
    printf 'WARN: %s  ' "${C_WARN}"
  fi
  if [[ "${C_FAIL}" -gt 0 ]]; then
    printf '%sFAIL:%s %s  ' "${C_RED}" "${C_RESET}" "${C_FAIL}"
  else
    printf 'FAIL: %s  ' "${C_FAIL}"
  fi
  printf 'SKIP: %s\n' "${C_SKIP}"

  if [[ "${C_FAIL}" -gt 0 ]]; then
    printf '\n%sBlocking issues — fix FAIL lines above (see → hints).%s\n' "${C_RED}" "${C_RESET}"
    if [[ ! -f "${ENV_FILE:-}" ]]; then
      printf '  %sFresh clone:%s make create-data COPY_FROM=/path/to/working/.data/.env\n' "${C_DIM}" "${C_RESET}"
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vpn-'; then
      printf '  %sBroken stack:%s make logs && make build && make recreate\n' "${C_DIM}" "${C_RESET}"
    fi
  elif [[ "${C_WARN}" -gt 0 ]]; then
    if preflight_stack_configured 2>/dev/null && \
       type preflight_stack_any_running >/dev/null 2>&1 && \
       ! preflight_stack_any_running; then
      printf '\n%sStack stopped — host/data OK.%s  %sStart:%s make start\n' \
        "${C_ORANGE}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    else
      printf '\n%sNo blocking FAIL%s — address WARN before declaring prod-ready.\n' \
        "${C_GREEN}" "${C_RESET}"
      if preflight_stack_any_running 2>/dev/null && \
         ! ip route show "${AWG_TUNNEL_SUBNET_IPV4:-10.8.0.0/24}" 2>/dev/null | grep -q .; then
        printf '  %sTypical fix:%s make start\n' "${C_DIM}" "${C_RESET}"
      elif [[ ! -f "${ENV_FILE:-}" ]]; then
        printf '  %sTypical fix:%s make create-data COPY_FROM=/path/to/working/.data/.env\n' "${C_DIM}" "${C_RESET}"
      fi
    fi
  elif preflight_stack_any_running 2>/dev/null; then
    printf '\n%sAll checks passed — stack running.%s\n' "${C_GREEN}" "${C_RESET}"
  elif [[ -f "${COMPOSE_FILE:-}" ]]; then
    printf '\n%sHost/data OK — stack not running.%s  %sStart:%s make start\n' \
      "${C_DIM}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
  else
    printf '\n%sHost OK — not deployed.%s  %sNext:%s make create-data && make first-start\n' \
      "${C_DIM}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
  fi
}
