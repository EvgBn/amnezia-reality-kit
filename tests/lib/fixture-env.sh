#!/usr/bin/env bash
# Fixture bootstrap helpers for shell tests.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "fixture-env.sh: source this file, do not execute" >&2
  exit 1
fi

FIXTURE_TMP_DIRS=()

fixture_common_dir() {
  if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "fixture_common_dir: REPO_ROOT not set" >&2
    return 1
  fi
  printf '%s/tests/fixtures/common' "${REPO_ROOT}"
}

fixture_data_dir() {
  if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "fixture_data_dir: REPO_ROOT not set" >&2
    return 1
  fi
  printf '%s/tests/fixtures/data' "${REPO_ROOT}"
}

fixture_data_path() {
  printf '%s/%s' "$(fixture_data_dir)" "$1"
}

fixture_copy_data() {
  local rel="$1" dest="$2"
  cp "$(fixture_data_path "${rel}")" "${dest}"
}

fixture_docker_mock_path() {
  printf '%s/docker-mock.sh' "$(fixture_common_dir)"
}

fixture_prep_path_bin() {
  local name="$1" script="$2"
  chmod +x "${script}"
  local bindir
  bindir="$(mktemp -d)"
  FIXTURE_TMP_DIRS+=("${bindir}")
  ln -sf "${script}" "${bindir}/${name}"
  export PATH="${bindir}:${PATH}"
}

fixture_use_docker_mock() {
  export FIXTURE_DOCKER_MOCK
  FIXTURE_DOCKER_MOCK="$(fixture_docker_mock_path)"
  fixture_prep_path_bin docker "${FIXTURE_DOCKER_MOCK}"
  docker() {
    "${FIXTURE_DOCKER_MOCK}" "$@"
  }
  export -f docker
}

fixture_use_docker_trace_mock() {
  local log_file="${1:?log file path}"
  export DOCKER_MOCK_COMMAND_LOG_FILE="${log_file}"
  export DOCKER_MOCK_TRACE_ONLY=1
  fixture_use_docker_mock
}

fixture_load_case() {
  local namespace="$1" case_name="$2" dest_root="${3:-${TMP:-}}"
  local src_base
  if [[ -z "${dest_root}" ]]; then
    echo "fixture_load_case: dest_root/TMP not set" >&2
    return 1
  fi
  src_base="$(fixture_data_path "cases/${namespace}/${case_name}")"
  [[ -d "${src_base}" ]] || {
    echo "fixture_load_case: missing case ${namespace}/${case_name}" >&2
    return 1
  }
  mkdir -p "${dest_root}/build"
  [[ -f "${src_base}/.env" ]] && cp "${src_base}/.env" "${dest_root}/.env"
  [[ -f "${src_base}/config.json" ]] && cp "${src_base}/config.json" "${dest_root}/build/config.json"
  [[ -f "${src_base}/docker-compose.yml" ]] && cp "${src_base}/docker-compose.yml" "${dest_root}/build/docker-compose.yml"
}

fixture_host_network_sandbox() {
  local root="$1"
  mkdir -p "${root}/systemd"
  export IPTABLES_MOCK_STATE="${root}/iptables.rules"
  export IP_MOCK_ROUTES="${root}/ip.routes"
  export SYSTEMCTL_MOCK_LOG="${root}/systemctl.log"
  export HOST_SYSTEMD_DIR="${root}/systemd"
  export VPN_DOCKER_SUBNET_CIDR="${VPN_DOCKER_SUBNET_CIDR:-172.20.0.0/24}"
  fixture_use_host_network_mocks
}

fixture_host_network_sandbox_integration() {
  local root="$1"
  local hn_dir="${REPO_ROOT}/tests/fixtures/host-network"

  fixture_host_network_sandbox "${root}"

  export FIXTURE_HN_ETC="${root}/etc"
  export FIXTURE_HN_PROC_MODULES="${root}/proc-modules"
  export FIXTURE_HN_MODULE_PATH="${root}/lib/modules/$(uname -r)/extra/amneziawg.ko"
  export FIXTURE_HN_HOST_ENV="${FIXTURE_HN_ETC}/vpn-bridge/env"
  export FIXTURE_HN_HOST_ENSURE="${root}/usr/local/sbin/vpn-stack-ensure"
  export FIXTURE_HN_AMNEZIAWG_CONF="${FIXTURE_HN_ETC}/modules-load.d/amneziawg.conf"
  export MODPROBE_MOCK_LOG="${root}/modprobe.log"

  mkdir -p "${HOST_SYSTEMD_DIR}" "${FIXTURE_HN_ETC}/vpn-bridge" "${FIXTURE_HN_ETC}/sysctl.d" \
    "${FIXTURE_HN_ETC}/modprobe.d" "${FIXTURE_HN_ETC}/modules-load.d" \
    "$(dirname "${FIXTURE_HN_MODULE_PATH}")" "$(dirname "${FIXTURE_HN_HOST_ENSURE}")"

  export MODPROBE="${hn_dir}/modprobe-mock.sh"
  export DEPMOD="${hn_dir}/depmod-mock.sh"
  export HOST_ENV_FILE="${FIXTURE_HN_HOST_ENV}"
  export HOST_ENSURE_WRAPPER="${FIXTURE_HN_HOST_ENSURE}"
  export PROC_MODULES="${FIXTURE_HN_PROC_MODULES}"
  export MODULE_PATH="${FIXTURE_HN_MODULE_PATH}"
  export AMNEZIAWG_MODULES_LOAD_CONF="${FIXTURE_HN_AMNEZIAWG_CONF}"
  export DOCKER_MOCK_PS=""
  chmod +x "${MODPROBE}" "${DEPMOD}"
}

fixture_use_awg_docker_mock() {
  export FIXTURE_DOCKER_MOCK
  FIXTURE_DOCKER_MOCK="$(fixture_common_dir)/awg-docker-mock.sh"
  fixture_prep_path_bin docker "${FIXTURE_DOCKER_MOCK}"
  docker() {
    "${FIXTURE_DOCKER_MOCK}" "$@"
  }
  export -f docker
}

fixture_use_ss_mock() {
  local mock
  mock="$(fixture_common_dir)/ss-mock.sh"
  fixture_prep_path_bin ss "${mock}"
}

fixture_use_curl_mock() {
  local mock
  mock="$(fixture_common_dir)/curl-mock.sh"
  fixture_prep_path_bin curl "${mock}"
}

fixture_use_openssl_mock() {
  local mock state
  mock="$(fixture_common_dir)/openssl-mock.sh"
  state="$(mktemp -d)"
  FIXTURE_TMP_DIRS+=("${state}")
  export OPENSSL_MOCK_STATE_DIR="${state}"
  fixture_prep_path_bin openssl "${mock}"
}

fixture_use_out_mocks() {
  local out_dir="${REPO_ROOT}/tests/fixtures/preflight-out"
  chmod +x "${out_dir}/docker-mock.sh" "${out_dir}/curl-mock.sh"
  export PREFLIGHT_OUT_DOCKER="${out_dir}/docker-mock.sh"
  export PREFLIGHT_OUT_CURL="${out_dir}/curl-mock.sh"
}

fixture_use_host_network_mocks() {
  local hn_dir="${REPO_ROOT}/tests/fixtures/host-network"
  export IPTABLES="${hn_dir}/iptables-mock.sh"
  export IP="${hn_dir}/ip-mock.sh"
  export SYSTEMCTL="${hn_dir}/systemctl-mock.sh"
  export DOCKER="${hn_dir}/docker-mock.sh"
  chmod +x "${IPTABLES}" "${IP}" "${SYSTEMCTL}" "${DOCKER}"
}

fixture_teardown() {
  local d
  for d in "${FIXTURE_TMP_DIRS[@]}"; do
    rm -rf "${d}"
  done
  FIXTURE_TMP_DIRS=()
}
