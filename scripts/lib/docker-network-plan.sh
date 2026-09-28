#!/usr/bin/env bash
# Docker bridge network SSOT — derive IPs from DOCKER_NETWORK_SUBNET_* in .data/.env.
# shellcheck disable=SC2034

_DOCKER_NET_PLAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_NETWORK_PLAN_PY="${_DOCKER_NET_PLAN_DIR}/docker-network-plan.py"
unset _DOCKER_NET_PLAN_DIR

# Apply resolved plan to current shell (export all keys).
docker_network_plan_apply() {
  local env_file="$1"
  local line key val
  [[ -f "${env_file}" ]] || return 0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    val="${val#\'}"
    val="${val%\'}"
    export "${key}=${val}"
  done < <(python3 "${DOCKER_NETWORK_PLAN_PY}" resolve --env-file "${env_file}")
}

# Resolve into named vars; returns 1 on validation error.
docker_network_plan_resolve() {
  local env_file="${1:-${ENV_FILE:-}}"
  [[ -n "${env_file}" ]] || {
    echo "docker_network_plan_resolve: ENV_FILE not set" >&2
    return 1
  }
  docker_network_plan_apply "${env_file}"
}

# Preflight: emit via preflight emit helpers when sourced from preflight.
docker_network_plan_check_overlap() {
  local env_file="${1:-${ENV_FILE:-}}"
  local skip_name="${2:-vpn}"
  local networks_file result ok conflicts subnet err hint detail

  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    return 0
  fi

  networks_file="$(mktemp "${TMPDIR:-/tmp}/docker-net-inspect.XXXXXX")"
  if ids="$(docker network ls -q 2>/dev/null)" && [[ -n "${ids}" ]]; then
    # shellcheck disable=SC2086
    docker network inspect ${ids} >"${networks_file}" 2>/dev/null || printf '%s\n' '[]' >"${networks_file}"
  else
    printf '%s\n' '[]' >"${networks_file}"
  fi

  result="$(python3 "${DOCKER_NETWORK_PLAN_PY}" check-overlap \
    --env-file "${env_file}" \
    --networks-file "${networks_file}" \
    --skip-name "${skip_name}" 2>&1)" || true
  rm -f "${networks_file}"

  ok="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok", False))' <<<"${result}" 2>/dev/null || echo False)"
  conflicts="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join(d.get("conflicts") or []))' <<<"${result}" 2>/dev/null || true)"
  subnet="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("subnet",""))' <<<"${result}" 2>/dev/null || true)"
  err="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))' <<<"${result}" 2>/dev/null || true)"

  if [[ "${ok}" == "True" ]]; then
    emit OK DATA DOCKER_NETWORK_SUBNET_IPV4 "${subnet} (no docker pool overlap)"
    return 0
  fi

  hint="set DOCKER_NETWORK_SUBNET_IPV4 to a free /24 (default 10.200.97.0/24); make build && sudo make deploy-host && make refresh-full"
  if [[ -n "${conflicts}" ]]; then
    detail="overlaps ${conflicts}"
  elif [[ -n "${err}" ]]; then
    detail="${err}"
  else
    detail="invalid or unroutable subnet"
  fi
  preflight_emit FAIL DATA DOCKER_NETWORK_SUBNET_IPV4 "${detail}" "${hint}"
  return 1
}
