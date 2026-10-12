#!/usr/bin/env bash
# Local images required before docker compose build (not on a registry).
# Keep in sync with: make images-ipt2socks (Makefile).

COMPOSE_IPT2SOCKS_IMAGE="${COMPOSE_IPT2SOCKS_IMAGE:-zfl9/ipt2socks:latest}"

compose_ipt2socks_image_ref() {
  printf '%s' "${COMPOSE_IPT2SOCKS_IMAGE}"
}

compose_ipt2socks_image_present() {
  docker image inspect "$(compose_ipt2socks_image_ref)" >/dev/null 2>&1
}

compose_docker_usable() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Hint when stack is down but .data/ exists (daily start vs first image build).
compose_stack_start_hint() {
  if compose_docker_usable && ! compose_ipt2socks_image_present; then
    printf '%s' 'make images && make start'
  else
    printf '%s' 'make start'
  fi
}

compose_require_local_images() {
  if compose_ipt2socks_image_present; then
    return 0
  fi
  local img
  img="$(compose_ipt2socks_image_ref)"
  echo "[up] ERROR: local image ${img} missing — run: make images (new host: make first-start)" >&2
  return 1
}
