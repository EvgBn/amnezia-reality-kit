#!/usr/bin/env bash
# voice-smoke-help.sh — shared UX for live Telegram group voice smoke tests.
# Source from diagnose-udp-path.sh and smoke-voice-chat.sh BEFORE voice-smoke-metrics.sh.
# Peer counters (awg dump) live in voice-smoke-metrics.sh; validate_client_ip sets AWG_CONTAINER temporarily.

VOICE_SMOKE_C_PROMPT=''
VOICE_SMOKE_C_HEAD=''
VOICE_SMOKE_C_GREEN=''
VOICE_SMOKE_C_ORANGE=''
VOICE_SMOKE_C_RESET=''

voice_smoke_init_colors() {
  if [[ -n "${VOICE_SMOKE_COLORS_INIT:-}" ]]; then
    return 0
  fi
  VOICE_SMOKE_COLORS_INIT=1
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    VOICE_SMOKE_C_PROMPT=$'\033[1;36m'
    VOICE_SMOKE_C_HEAD=$'\033[1m'
    VOICE_SMOKE_C_GREEN=$'\033[1;32m'
    VOICE_SMOKE_C_ORANGE=$'\033[1;38;5;208m'
    VOICE_SMOKE_C_RESET=$'\033[0m'
  fi
}

voice_smoke_prompt() {
  voice_smoke_init_colors
  printf '%b%s%b' "${VOICE_SMOKE_C_PROMPT}" "$*" "${VOICE_SMOKE_C_RESET}" >&2
}

voice_smoke_head() {
  voice_smoke_init_colors
  printf '%b%s%b\n' "${VOICE_SMOKE_C_HEAD}" "$*" "${VOICE_SMOKE_C_RESET}" >&2
}

voice_smoke_format_runtime() {
  local runtime="$1"
  voice_smoke_init_colors
  if [[ "${runtime}" == *"active"* ]]; then
    printf '%b%s%b' "${VOICE_SMOKE_C_GREEN}" "${runtime}" "${VOICE_SMOKE_C_RESET}"
  else
    printf '%s' "${runtime}"
  fi
}

voice_smoke_normalize_ip() {
  local ip="${1// /}"
  ip="${ip%%,*}"
  ip="${ip%%/*}"
  echo "${ip}"
}

voice_smoke_print_client_select_header() {
  voice_smoke_init_colors
  echo "" >&2
  printf '  %b%s%b\n' "${VOICE_SMOKE_C_HEAD}" "$(date '+%H:%M:%S')" "${VOICE_SMOKE_C_RESET}" >&2
  echo "  [INFO] Select AWG test client (make awg-client-list)…" >&2
}

voice_smoke_print_purpose() {
  local mode="${1:-gate}"
  local client_ip="${2:-?}"
  [[ "${VOICE_GATE_VERBOSE:-0}" == "1" ]] || return 0
  echo "── What this test checks ──"
  echo "  Path: phone → AWG (${client_ip}) → NFQUEUE → udp-relay → SOCKS → xray → OUT"
  echo "  Proves: VoIP UDP captured, not leaked via FORWARD, bytes move rx/tx, no one-way relay errors"
  echo "  Does NOT prove: Connecting… UI text, audio quality, OUT return (use tcpdump on OUT for that)"
  if [[ "${mode}" == "report" ]]; then
    echo "  Output: metric table + logs in /tmp/smoke-voice-chat.* (for debugging)"
  else
    echo "  Output: PASS/FAIL gate (use before merge/deploy)"
  fi
}

voice_smoke_print_gate_limits() {
  # Legacy — use voice_smoke_print_l5_prep in default mode.
  voice_smoke_print_l5_prep "${CLIENT_IP:-?}" "${WATCH_SEC:-30}"
}

voice_smoke_print_l5_prep() {
  local client_ip="$1" watch_sec="$2"
  printf '  [INFO] %ss voice probe on %s — phone → NFQUEUE → udp-relay → xray → Telegram\n' \
    "${watch_sec}" "${client_ip}"
  printf '  [INFO] Stay in active group voice during the window. Raw counters: VOICE_GATE_VERBOSE=1\n'
}

voice_smoke_print_measurement_line() {
  local watch_sec="$1"
  printf '  Measuring %ss — only VoIP UDP counts (chat/DNS ignored)\n' "${watch_sec}"
}

voice_smoke_print_timing() {
  local duration="$1"
  local client_ip="$2"
  [[ "${VOICE_GATE_VERBOSE:-0}" == "1" ]] || return 0
  echo ""
  echo "── When to run (either order works) ──"
  echo "  [A] Already in group voice  →  run script  →  stay in call for ${duration}s"
  echo "  [B] Not in voice yet        →  run script  →  join group voice within ${duration}s"
  echo ""
  echo "  Need: VPN on ${client_ip}, ACTIVE voice (speak or listen)."
  echo "  Not enough: VPN only, text chat, Connecting… without media, idle in room."
}

voice_smoke_prep_countdown() {
  local prep="${1:-5}"
  local measure="${2:-30}"
  local i

  if [[ "${VOICE_SMOKE_CALL_STATE:-active}" == "joining" ]]; then
    voice_smoke_init_colors
    echo ""
    if [[ -t 1 && -z "${NO_COLOR:-}" && -n "${VOICE_SMOKE_C_ORANGE}" ]]; then
      printf '── %bJoin group voice NOW%b — %ss measurement starts immediately ──\n' \
        "${VOICE_SMOKE_C_ORANGE}" "${VOICE_SMOKE_C_RESET}" "${measure}"
    else
      echo "── Join group voice NOW — ${measure}s measurement starts immediately ──"
    fi
    voice_smoke_print_measurement_line "${measure}"
    return 0
  fi

  if [[ "${prep}" -le 0 ]]; then
    echo ""
    echo "── Measuring ${measure}s (stay in active call) ──"
    voice_smoke_print_measurement_line "${measure}"
    return 0
  fi

  echo ""
  echo "── Measurement starts in ${prep}s (stay in active call for next ${measure}s) ──"
  for ((i = prep; i >= 1; i--)); do
    printf '\r  starting in %2ds — stay in call…' "${i}"
    sleep 1
  done
  printf '\r  measuring %ss…                                              \n' "${measure}"
  voice_smoke_print_measurement_line "${measure}"
}

voice_smoke_client_list_tsv() {
  local awg_container="$1" root="$2"
  local list_py awg_conf clients_dir
  list_py="${root}/scripts/clients/awg/list-peers.py"
  awg_conf="${AWG_CONF:-${root}/.data/awg0.conf}"
  clients_dir="${AWG_CLIENTS_DIR:-${root}/.data/clients_awg}"
  [[ -f "${list_py}" && -f "${awg_conf}" ]] || return 1
  AWG_CONF="${awg_conf}" AWG_CLIENTS_DIR="${clients_dir}" AWG_CONTAINER="${awg_container}" \
    python3 "${list_py}" --tsv 2>/dev/null
}

voice_smoke_validate_client_ip() {
  local awg_container="$1" ip="$2" max_age="$3"
  local saved_awg_container="${AWG_CONTAINER:-}" age

  if ! declare -F voice_smoke_peer_dump_line >/dev/null 2>&1; then
    echo "  [ERROR] voice-smoke-metrics.sh must be sourced before client validation" >&2
    return 1
  fi

  AWG_CONTAINER="${awg_container}"
  ip="$(voice_smoke_normalize_ip "${ip}")"
  if ! voice_smoke_peer_dump_line "${ip}" | grep -q .; then
    AWG_CONTAINER="${saved_awg_container}"
    echo "  [ERROR] No AWG peer for ${ip} on awg0 — run: make awg-client-list" >&2
    return 1
  fi
  age="$(voice_smoke_peer_handshake_age "${ip}")"
  AWG_CONTAINER="${saved_awg_container}"
  if [[ "${age}" -lt 0 ]]; then
    echo "  [ERROR] Peer ${ip} has no handshake — connect VPN on the test phone first" >&2
    return 1
  fi
  if [[ "${age}" -gt "${max_age}" ]]; then
    echo "  [WARN] Peer ${ip} last handshake ${age}s ago (>${max_age}s) — VPN may be off" >&2
  fi
  return 0
}

voice_smoke_resolve_client_ip() {
  local awg_container="$1" max_age="${2:-180}" root="${3:-}"
  local answer ip n
  local -a menu_nums menu_names menu_ips menu_runtime

  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ -z "${SMOKE_CLIENT_IP:-}" ]]; then
      echo "  [ERROR] NONINTERACTIVE requires SMOKE_CLIENT_IP=<tunnel-ip>" >&2
      return 1
    fi
    ip="$(voice_smoke_normalize_ip "${SMOKE_CLIENT_IP}")"
    voice_smoke_validate_client_ip "${awg_container}" "${ip}" "${max_age}" || return 1
    echo "${ip}"
    return 0
  fi

  if [[ -z "${root}" ]]; then
    echo "  [ERROR] internal: repo root not passed to voice_smoke_resolve_client_ip" >&2
    return 1
  fi

  voice_smoke_print_client_select_header
  voice_smoke_head "── Test client (same list as make awg-client-list) ──"
  echo "  Pick the phone/user whose VPN is connected for this voice test." >&2
  echo "  Tunnel IP only — NOT Wi‑Fi IP. Connect VPN before measuring." >&2

  if ! voice_smoke_client_list_tsv "${awg_container}" "${root}" | grep -q .; then
    echo "  [ERROR] Cannot load client list — run: make awg-client-list" >&2
    return 1
  fi

  n=0
  voice_smoke_init_colors
  printf '  %-3s %-14s %-15s %s\n' "#" "NAME" "IP" "RUNTIME" >&2
  while IFS=$'\t' read -r num name ip runtime; do
    [[ -z "${num}" ]] && continue
    ip="$(voice_smoke_normalize_ip "${ip}")"
    n=$((n + 1))
    menu_nums+=("${num}")
    menu_names+=("${name}")
    menu_ips+=("${ip}")
    menu_runtime+=("${runtime}")
    printf '  %-3s %-14s %-15s ' "${num}" "${name}" "${ip}" >&2
    voice_smoke_format_runtime "${runtime}" >&2
    printf '\n' >&2
  done < <(voice_smoke_client_list_tsv "${awg_container}" "${root}")

  if [[ "${n}" -eq 0 ]]; then
    echo "  [ERROR] No AWG clients configured — make awg-client-add NAME=..." >&2
    return 1
  fi

  echo "  m) Enter tunnel IP manually" >&2
  echo "  q) Abort" >&2

  while true; do
    voice_smoke_prompt '  Choose client [# or m/q]: '
    read -r answer

    if [[ "${answer}" == "q" || "${answer}" == "Q" ]]; then
      echo "  Aborted." >&2
      exit 0
    elif [[ "${answer}" == "m" || "${answer}" == "M" ]]; then
      voice_smoke_prompt '  Tunnel IP (e.g. 10.8.0.9): '
      read -r ip
      ip="$(voice_smoke_normalize_ip "${ip}")"
    elif [[ "${answer}" =~ ^[0-9]+$ ]]; then
      ip=""
      for i in "${!menu_nums[@]}"; do
        if [[ "${menu_nums[$i]}" == "${answer}" ]]; then
          ip="${menu_ips[$i]}"
          printf '  → %s (%s) — ' "${menu_names[$i]}" "${ip}" >&2
          voice_smoke_format_runtime "${menu_runtime[$i]}" >&2
          printf '\n\n\n' >&2
          break
        fi
      done
      if [[ -z "${ip}" ]]; then
        echo "  Invalid # (see list above)." >&2
        continue
      fi
    else
      echo "  Enter row # from the list, m, or q." >&2
      continue
    fi

    if voice_smoke_validate_client_ip "${awg_container}" "${ip}" "${max_age}"; then
      echo "${ip}"
      return 0
    fi
  done
}

voice_smoke_prompt_call_state() {
  local duration="$1"
  local answer
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    VOICE_SMOKE_CALL_STATE="${VOICE_SMOKE_CALL_STATE:-active}"
    echo "  [INFO] NONINTERACTIVE=1 — call state=${VOICE_SMOKE_CALL_STATE} (joining = join during watch; gate fails without session first inject)"
    return 0
  fi
  printf '\n\n' >&2
  voice_smoke_head "── Call state ──"
  echo "  1) Already in ACTIVE group voice (hearing or speaking)"
  echo "  2) Not yet — will join during the ${duration}s measurement window"
  echo "  3) Abort"
  voice_smoke_prompt '  Choose call state [1/2/3]: '
  read -r answer
  case "${answer}" in
    1)
      VOICE_SMOKE_CALL_STATE=active
      echo "  → Stay in the call. Do not hang up during measurement."
      ;;
    2)
      VOICE_SMOKE_CALL_STATE=joining
      echo "  → Join group voice when countdown starts. Speak or listen once connected."
      echo "  → No prep delay — measurement starts right after this prompt."
      ;;
    3|q|Q)
      echo "  Aborted."
      exit 0
      ;;
    *)
      VOICE_SMOKE_CALL_STATE=joining
      echo "  → Assuming [2]: join during measurement window."
      ;;
  esac
}
