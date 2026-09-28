#!/usr/bin/env bash
# Phase 1: repository layout (clone integrity).

preflight_phase_01_repo() {
  phase_header "Phase 1: Repository"

  local f
  for f in \
    "scripts/preflight/run.sh" \
    "scripts/deployment/up.sh" \
    "scripts/setup/bootstrap-data.sh" \
    "scripts/setup/render-config.sh" \
    "scripts/clients/awg/add.sh" \
    "config/README.md" \
    "config/templates/Corefile.tmpl" \
    "config/examples/.env.example" \
    "config/templates/awg0.conf.tmpl" \
    "config/templates/config.json.tmpl" \
    "config/templates/docker-compose.yml.tmpl" \
    "config/templates/ipt2socks-amneziawg-v4.sh.tmpl" \
    "config/templates/ipt2socks-amneziawg-v6.sh.tmpl" \
    "config/templates/ipt2socks-coredns.sh.tmpl" \
    "config/templates/ipt2socks-ports.env.tmpl" \
    "config/templates/udp-relay-run.sh.tmpl" \
    "Makefile"; do
    if [[ -f "${REPO_ROOT}/${f}" ]]; then
      emit OK REPO "${f}" "present"
    else
      emit FAIL REPO "${f}" "missing" "re-clone repository"
    fi
  done
}
