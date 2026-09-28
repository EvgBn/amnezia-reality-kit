#!/usr/bin/env bash
# Phase 3: Docker engine, compose, socket access.

preflight_phase_03_docker() {
  phase_header "Phase 3: Docker"

  if command -v docker >/dev/null 2>&1; then
    emit OK DOCKER cli "$(docker --version 2>/dev/null | head -1)"
  else
    emit FAIL DOCKER cli "docker not in PATH" \
      "sudo ./scripts/setup/install-docker.sh"
    return
  fi

  if docker compose version >/dev/null 2>&1; then
    emit OK DOCKER compose "$(docker compose version 2>/dev/null | head -1)"
  else
    emit FAIL DOCKER compose "docker compose plugin missing" \
      "sudo ./scripts/setup/install-docker.sh"
  fi

  if preflight_docker_accessible; then
    emit OK DOCKER socket "current user can talk to daemon"
  else
    emit FAIL DOCKER socket "docker info failed (permission?)" \
      "sudo usermod -aG docker \$USER && re-login, or use sudo for make"
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    emit SKIP DOCKER group "running as root"
  elif id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    emit OK DOCKER group "user in docker group"
  else
    emit WARN DOCKER group "user not in docker group" \
      "sudo usermod -aG docker \$USER && re-login"
  fi
}
