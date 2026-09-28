#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../../lib/paths.sh
source "${SCRIPT_DIR}/../../lib/paths.sh"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/awg-common.sh
source "${SCRIPT_DIR}/../../lib/awg-common.sh"

if [[ -n "${AWG_TEST_ROOT:-}" ]]; then
  AWG_CONF="${AWG_TEST_ROOT}/awg0.conf"
  AWG_CLIENTS_DIR="${AWG_TEST_ROOT}/clients_awg"
  AWG_LOCK="${AWG_CONF}.lock"
  ENV_FILE="${AWG_TEST_ROOT}/.env"
fi

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <client_name>" >&2
  exit 1
fi

readonly CLIENT_NAME="$1"
validate_client_name "${CLIENT_NAME}"

CLIENT_CONF="$(client_conf_path "${CLIENT_NAME}")"
readonly CLIENT_CONF

load_env
awg_require_container

if [[ ! -f "${AWG_CONF}" ]]; then
  log_error "Missing ${AWG_CONF} — run 'make up' or restore build config first."
  exit 1
fi

if [[ -f "${CLIENT_CONF}" ]]; then
  log_error "Client '${CLIENT_NAME}' already exists (${CLIENT_CONF})."
  exit 1
fi

mkdir -p "${AWG_CLIENTS_DIR}"

KEY_OUTPUT=$(docker exec "${AWG_CONTAINER}" sh -c '
  PRIV=$(awg genkey)
  PUB=$(printf "%s" "$PRIV" | awg pubkey)
  printf "%s\n%s\n" "$PRIV" "$PUB"
')
CLIENT_PRIVATE_KEY=$(sed -n '1p' <<< "${KEY_OUTPUT}")
CLIENT_PUBLIC_KEY=$(sed -n '2p' <<< "${KEY_OUTPUT}")

[[ -n "${CLIENT_PRIVATE_KEY}" && -n "${CLIENT_PUBLIC_KEY}" ]] \
  || { log_error "Failed to generate client keypair."; exit 1; }

SERVER_PUBLIC_KEY=$(awg_server_public_key)
ENDPOINT=$(awg_endpoint)
awg_read_obfuscation

PEERS_BEFORE=$(awg_peer_count)

(
  flock -x 200 || { log_error "Could not acquire lock on ${AWG_CONF}"; exit 1; }

  NEXT_IP=$(awg_allocate_ipv4)
  IPV6_ALLOWED=""
  if IPV6_ALLOWED=$(awg_ipv6_allowed "${NEXT_IP##*.}"); then
    :
  else
    IPV6_ALLOWED=""
  fi

  if [[ -n "${IPV6_ALLOWED}" ]]; then
    cat >> "${AWG_CONF}" <<PEER_EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${NEXT_IP}/32, ${IPV6_ALLOWED}
PEER_EOF
  else
    cat >> "${AWG_CONF}" <<PEER_EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${NEXT_IP}/32
PEER_EOF
  fi

  printf '%s' "${NEXT_IP}" > "${AWG_CONF}.next_ip_${CLIENT_NAME}"
) 200>"${AWG_LOCK}"

NEXT_IP=$(cat "${AWG_CONF}.next_ip_${CLIENT_NAME}")
rm -f "${AWG_CONF}.next_ip_${CLIENT_NAME}"

cat > "${CLIENT_CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${NEXT_IP}/32
DNS = 10.8.0.1
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "${CLIENT_CONF}"

awg_syncconf

PEERS_AFTER=$(awg_peer_count)
if (( PEERS_AFTER != PEERS_BEFORE + 1 )); then
  log_error "Peer count mismatch after add (before=${PEERS_BEFORE}, after=${PEERS_AFTER})."
  exit 1
fi

log_info "Client '${CLIENT_NAME}' added — IP ${NEXT_IP}/32"
echo ""
export AWG_HIGHLIGHT_NAME="${CLIENT_NAME}"
[[ -n "${AWG_TEST_ROOT:-}" ]] && export AWG_TEST_ROOT
"${SCRIPT_DIR}/list.sh"
