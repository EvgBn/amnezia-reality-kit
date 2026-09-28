#!/usr/bin/env bash
# IPv6 addressing checks — reject RFC 3849 documentation prefixes in production paths.

# RFC 3849 — must never appear on live Docker bridge or OUT exit.
preflight_ipv6_is_doc_prefix() {
  local addr="${1,,}"
  [[ "${addr}" == 2001:db8:* ]] || [[ "${addr}" == 2001:0db8:* ]]
}

preflight_check_docker_ipv6_subnets() {
  local sub="${DOCKER_NETWORK_SUBNET_IPV6:-}"
  local gw="${DOCKER_NETWORK_GATEWAY_IPV6:-}"
  local c6="${COREDNS_IPV6:-}"

  if [[ -z "${sub}" ]]; then
    emit WARN DATA DOCKER_NETWORK_SUBNET_IPV6 "empty" "set ULA in .env (e.g. fd87:172:20::/64); make build"
    return
  fi

  if preflight_ipv6_is_doc_prefix "${sub}"; then
    emit FAIL DATA DOCKER_NETWORK_SUBNET_IPV6 \
      "uses RFC3849 docs prefix (${sub})" \
      "use ULA (fd87:172:20::/64) or your own ULA; edit .env && make build && make recreate"
    return
  fi

  emit OK DATA DOCKER_NETWORK_SUBNET_IPV6 "${sub} (not RFC3849)"

  if [[ -n "${gw}" ]] && preflight_ipv6_is_doc_prefix "${gw}"; then
    emit FAIL DATA DOCKER_NETWORK_GATEWAY_IPV6 "RFC3849 docs prefix (${gw})" "match DOCKER_NETWORK_SUBNET_IPV6 ULA"
  elif [[ -n "${gw}" ]]; then
    emit OK DATA DOCKER_NETWORK_GATEWAY_IPV6 "${gw}"
  fi

  if [[ -z "${c6}" ]]; then
    emit WARN DATA COREDNS_IPV6 "empty" "pin coredns v6 (e.g. fd87:172:20::2); must match awg0 DNAT"
  elif preflight_ipv6_is_doc_prefix "${c6}"; then
    emit FAIL DATA COREDNS_IPV6 "RFC3849 docs prefix (${c6})" "use address inside DOCKER_NETWORK_SUBNET_IPV6"
  else
    emit OK DATA COREDNS_IPV6 "${c6} (pinned in compose)"
  fi

  if [[ -n "${OUT_EXIT_ADDRESS:-}" ]] && [[ "${OUT_EXIT_FAMILY:-}" == "6" ]] \
    && preflight_ipv6_is_doc_prefix "${OUT_EXIT_ADDRESS}"; then
    emit WARN DATA OUT_EXIT "RFC3849 placeholder (${OUT_EXIT_ADDRESS})" "set real GUA: OUT_EXIT=6; <addr>"
  elif [[ -n "${OUT_SERVER_IPV6:-}" ]] && preflight_ipv6_is_doc_prefix "${OUT_SERVER_IPV6}"; then
    emit WARN DATA OUT_EXIT "RFC3849 placeholder (${OUT_SERVER_IPV6})" "set OUT_EXIT='6; <real GUA>'"
  fi
}
