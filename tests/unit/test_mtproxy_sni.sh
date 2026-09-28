#!/usr/bin/env bash
# Unit tests for mtproxy-sni.sh (map lint + secret decode; TLS probes mocked).
set -euo pipefail

_LIB="$(cd "$(dirname "$0")/../lib" && pwd)"
# shellcheck source=../lib/sandbox.sh
source "${_LIB}/sandbox.sh"
# shellcheck source=../lib/assert.sh
source "${_LIB}/assert.sh"
# shellcheck source=../lib/fixture-env.sh
source "${_LIB}/fixture-env.sh"

test_repo_root
test_mktemp_sandbox TMP

SNI_SH="${REPO_ROOT}/scripts/lib/mtproxy-sni.sh"
DATA_NGINX="$(fixture_data_dir)/nginx"

# shellcheck source=../../scripts/lib/mtproxy-sni.sh
source "${SNI_SH}"

export MTPROXY_SNI=google.com
export MTPROXY_EE_DOMAIN=www.google.com
export MTPROXY_HOST_PORT=8444
export MTPROXY_SECRET=eea4b4eb0c0f82833cea42ab92979882007777772e676f6f676c652e636f6d

domain="$(mtproxy_sni_secret_domain)"
eq "${domain}" "www.google.com" "secret domain decode"

hosts="$(mtproxy_sni_required_hosts | sort | paste -sd, -)"
eq "${hosts}" "google.com,www.google.com" "required hosts"

bad_map="${TMP}/bad-map.conf"
good_map="${TMP}/good-map.conf"
cp "${DATA_NGINX}/sni-map-bad.conf" "${bad_map}"
cp "${DATA_NGINX}/sni-map-good.conf" "${good_map}"

bad_out="$(mtproxy_sni_nginx_lint "${bad_map}" 2>&1)" && fail "bad map should fail"
contains "${bad_out}" "missing SNI www.google.com" "expected www missing"

good_out="$(mtproxy_sni_nginx_lint "${good_map}" 2>&1)" || fail "good map should pass: ${good_out}"
[[ "${good_out}" != *"FAIL:"* ]] || fail "unexpected fail: ${good_out}"

mtproxy_sni_cert_is_site_backend "example.com" "${good_map}" || fail "example.com should be site"
mtproxy_sni_cert_is_site_backend "*.google.com" "${good_map}" && fail "google should not be site"

fixture_use_openssl_mock
export MTPROXY_SNI_PROBE_SKIP_TCP=1
export OPENSSL_MOCK_CN_MAP=$'www.google.com=www.google.com
google.com=*.google.com
default=example.com'

tls_out="$(mtproxy_sni_tls_probe "${good_map}" 127.0.0.1 2>&1)" || fail "good tls probe: ${tls_out}"

export OPENSSL_MOCK_CN_MAP='default=example.com'
export OPENSSL_MOCK_DEFAULT_CN='example.com'

bad_tls="$(mtproxy_sni_tls_probe "${bad_map}" 127.0.0.1 2>&1)" && fail "misroute tls should fail"
contains "${bad_tls}" "CN=example.com" "expected misroute fail"

fixture_teardown
echo "OK: test_mtproxy_sni"
