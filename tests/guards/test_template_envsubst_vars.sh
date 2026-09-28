#!/usr/bin/env bash
# Guard: every ${VAR} in config templates is covered by collect-envsubst-vars.py
# (render-config uses auto-collected lists — no manual ENVSUBST_VARS drift).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${REPO_ROOT}/config/templates"
COLLECT="${REPO_ROOT}/scripts/setup/collect-envsubst-vars.py"

fail() { echo "FAIL: $1" >&2; exit 1; }

ENVSUBST_TMPLS=(
  "${CONFIG}/awg0.conf.tmpl"
  "${CONFIG}/ipt2socks-amneziawg-v4.sh.tmpl"
  "${CONFIG}/ipt2socks-amneziawg-v6.sh.tmpl"
  "${CONFIG}/udp-relay-run.sh.tmpl"
  "${CONFIG}/ipt2socks-coredns.sh.tmpl"
  "${CONFIG}/ipt2socks-ports.env.tmpl"
  "${CONFIG}/docker-compose.yml.tmpl"
  "${CONFIG}/Corefile.tmpl"
)

for f in "${ENVSUBST_TMPLS[@]}"; do
  [[ -f "${f}" ]] || fail "missing template ${f}"
done

out="$(python3 "${COLLECT}" "${ENVSUBST_TMPLS[@]}")"
[[ -n "${out}" ]] || fail "collect-envsubst-vars produced empty list"

# Spot-check a few vars that must always be present
for need in AWG_TUNNEL_SUBNET_IPV4 XRAY_IMAGE COREDNS_UPSTREAM COREDNS_IPT2SOCKS_PORT; do
  [[ "${out}" == *"\${${need}}"* ]] || fail "collector missing \${${need}}"
done

json_out="$(python3 "${COLLECT}" "${CONFIG}/config.json.tmpl")"
[[ "${json_out}" == *"\${SOCKS_USER}"* ]] || fail "config.json.tmpl vars not collected"

echo "OK: test_template_envsubst_vars"
