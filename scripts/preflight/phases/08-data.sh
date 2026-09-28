#!/usr/bin/env bash
# Phase 8: DATA — .data/.env (OUT_* / REALITY_* / core), .data/build/

preflight_phase_08_data() {
  phase_header "Phase 8: Data (.data/)"

  if [[ -f "${ENV_FILE}" ]]; then
    if preflight_env_has_out_placeholders; then
      emit WARN DATA .env "bootstrap template (OUT_* still from .env.example)" \
        "make create-data COPY_FROM=/path/to/working/.data/.env FORCE=1"
    else
      emit OK DATA .env "secrets present"
    fi
    preflight_check_env_group "OUT_*" "${PREFLIGHT_ENV_OUT[@]}"
    if [[ -n "${OUT_EXIT:-}" ]]; then
      emit OK DATA OUT_EXIT "${OUT_EXIT}"
    elif [[ -n "${OUT_SERVER_IPV6:-}" ]]; then
      emit WARN DATA OUT_EXIT "legacy OUT_SERVER_IPV6 only" "set OUT_EXIT='6; <gua>' (migrate from deprecated key)"
    else
      emit FAIL DATA OUT_EXIT "missing" "set OUT_EXIT=4; <ip> or OUT_EXIT=6; <ip>"
    fi
    if [[ -z "${OUT_EXPECTED_EGRESS:-}" ]]; then
      emit WARN DATA OUT_EXPECTED_EGRESS "not set" "set OUT_EXPECTED_EGRESS=4; <ip> for curl egress check"
    else
      emit OK DATA OUT_EXPECTED_EGRESS "${OUT_EXPECTED_EGRESS}"
    fi
    if [[ -n "${IN_INGRESS:-}" ]]; then
      emit OK DATA IN_INGRESS "${IN_INGRESS}"
    else
      emit WARN DATA IN_INGRESS "missing" "set IN_INGRESS=4; <public-ip>"
    fi
    # shellcheck source=../lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"
    if [[ "$(parse_bool "${ENABLE_XRAY_INBOUND:-}" 1)" == "1" ]]; then
      preflight_check_env_group "REALITY_*" "${PREFLIGHT_ENV_REALITY[@]}"
    else
      emit OK DATA "REALITY_*" "skipped (ENABLE_XRAY_INBOUND=0)"
    fi
    preflight_check_env_group "core" "${PREFLIGHT_ENV_CORE[@]}"
    # shellcheck source=../lib/ipv6.sh
    source "${REPO_ROOT}/scripts/preflight/lib/ipv6.sh"
    preflight_check_docker_ipv6_subnets
    # shellcheck source=../../lib/docker-network-plan.sh
    source "${REPO_ROOT}/scripts/lib/docker-network-plan.sh"
    docker_network_plan_check_overlap "${ENV_FILE}" || true
  else
    emit WARN DATA .env "missing" "make create-data COPY_FROM=/path/to/working/.data/.env"
  fi

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    if [[ -f "${ENV_FILE}" ]]; then
      emit WARN DATA build/ "docker-compose.yml missing" "make build"
    else
      emit WARN DATA build/ "not initialized" "make create-data COPY_FROM=/path/to/working/.data/.env"
    fi
    return
  fi

  local artifact missing=0
  for artifact in "${PREFLIGHT_BUILD_ARTIFACTS[@]}"; do
    if [[ -f "${BUILD_DIR}/${artifact}" ]]; then
      emit OK DATA "build/${artifact}" "present"
    else
      emit WARN DATA "build/${artifact}" "missing" "make build"
      missing=1
    fi
  done
  if [[ "${missing}" -eq 0 ]]; then
    emit OK DATA build/ "${#PREFLIGHT_BUILD_ARTIFACTS[@]} artifacts present"
  fi

  preflight_check_build_inbound

  local f mode base
  for f in \
    "${BUILD_DIR}/ipt2socks-amneziawg-v4.sh" \
    "${BUILD_DIR}/ipt2socks-amneziawg-v6.sh" \
    "${BUILD_DIR}/udp-relay-run.sh" \
    "${BUILD_DIR}/ipt2socks-coredns.sh"; do
    [[ -f "${f}" ]] || continue
    mode="$(stat -c '%a' "${f}" 2>/dev/null || echo '?')"
    base="$(basename "${f}")"
    if [[ "${mode}" == "755" ]]; then
      emit OK DATA "${base}" "755 (executable mount)"
    else
      emit FAIL DATA "${base}" "mode=${mode}, need 755" "make build && make recreate"
    fi
  done

  local awg_image
  awg_image="$(preflight_awg_image_ref)"
  if docker image inspect "${awg_image}" >/dev/null 2>&1; then
    emit OK DATA awg-image "${awg_image} available"
  elif [[ -f "${ENV_FILE}" ]]; then
    emit WARN DATA awg-image "${awg_image} missing" "make images"
  else
    emit WARN DATA awg-image "${awg_image} missing" "make images (before create-data)"
  fi
}
