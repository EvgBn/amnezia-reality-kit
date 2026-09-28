#!/usr/bin/env bash
# Composable docker CLI mock for unit tests.
#
# contract:
#   docker ps [--format TEMPLATE]
#   docker inspect … (Health.Status, Config.Env)
#   docker image inspect <ref>
#   docker logs <container>
#   docker exec … ping … (when DOCKER_MOCK_PING_RC or OUT_MOCK_PING_RC set)
#
# env:
#   DOCKER_MOCK_PS          — container name(s), newline-separated (ps output)
#   DOCKER_MOCK_HEALTH      — inspect Health.Status (default: healthy)
#   DOCKER_MOCK_EXTERNAL_PORT — EXTERNAL_PORT=… line for Config.Env inspect
#   DOCKER_MOCK_CONFIG_ENV  — full Config.Env inspect body (overrides EXTERNAL_PORT)
#   DOCKER_MOCK_LOGS        — literal logs body
#   DOCKER_MOCK_LOGS_FILE  — path to logs file (preferred over DOCKER_MOCK_LOGS)
#   DOCKER_MOCK_IMAGE_INSPECT_RC — exit code for image inspect (default: 0)
#   DOCKER_MOCK_PING_RC     — exit code for exec ping probes
#   OUT_MOCK_PING_RC        — alias for DOCKER_MOCK_PING_RC (preflight OUT)
#   DOCKER_MOCK_COMMAND_LOG_FILE — append "docker …" lines (trace mode)
#   DOCKER_MOCK_TRACE_ONLY — 1 → log and exit 0 for any command
#
# consumers: test_mtproxy_smoke, test_mtproxy_export, test_preflight_mtproxy_port,
#            test_preflight_mtproxy_phase, test_preflight_out, test_images_pull_upstream (via wrapper)
set -euo pipefail

if [[ -n "${DOCKER_MOCK_COMMAND_LOG_FILE:-}" ]]; then
  printf 'docker %s\n' "$*" >> "${DOCKER_MOCK_COMMAND_LOG_FILE}"
fi
if [[ "${DOCKER_MOCK_TRACE_ONLY:-0}" == "1" ]]; then
  exit 0
fi

cmd="${1:-}"
shift || true

case "${cmd}" in
  ps)
    if [[ "${1:-}" == "--format" ]]; then
      shift 2 || true
    fi
    if [[ -n "${DOCKER_MOCK_PS:-}" ]]; then
      printf '%s\n' "${DOCKER_MOCK_PS}"
    fi
    exit 0
    ;;
  inspect)
    if [[ "$*" == *Health.Status* ]]; then
      printf '%s\n' "${DOCKER_MOCK_HEALTH:-healthy}"
      exit 0
    fi
    if [[ "$*" == *Config.Env* ]]; then
      if [[ -n "${DOCKER_MOCK_CONFIG_ENV:-}" ]]; then
        printf '%s\n' "${DOCKER_MOCK_CONFIG_ENV}"
      else
        printf 'EXTERNAL_PORT=%s\n' "${DOCKER_MOCK_EXTERNAL_PORT:-8444}"
      fi
      exit 0
    fi
    ;;
  image)
    if [[ "${1:-}" == "inspect" ]]; then
      exit "${DOCKER_MOCK_IMAGE_INSPECT_RC:-0}"
    fi
    ;;
  logs)
    container="${1:-}"
    if [[ -n "${DOCKER_MOCK_LOGS_FILE:-}" && -f "${DOCKER_MOCK_LOGS_FILE}" ]]; then
      cat "${DOCKER_MOCK_LOGS_FILE}"
      exit 0
    fi
    if [[ -n "${DOCKER_MOCK_LOGS:-}" ]]; then
      printf '%s\n' "${DOCKER_MOCK_LOGS}"
      exit 0
    fi
    echo "docker-mock: logs not configured for ${container}" >&2
    exit 1
    ;;
  exec)
    if [[ "$*" == *ping* ]]; then
      exit "${DOCKER_MOCK_PING_RC:-${OUT_MOCK_PING_RC:-0}}"
    fi
    echo "docker-mock: unsupported exec: $*" >&2
    exit 1
    ;;
esac

echo "docker-mock: unsupported: ${cmd} $*" >&2
exit 1
