#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  generate-relay-tls-config.sh [certificate-directory] [relay-hostname]

The certificate directory defaults to the current directory and must contain:
  server.crt  PEM server certificate (leaf certificate first, followed by its chain)
  server.key  PEM private key
  password    Private-key password; use an empty file for an unencrypted key

The optional relay-hostname is checked against the certificate SAN before the
three Relay Controller environment variables are printed.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

certificate_directory=${1:-.}
relay_hostname=${2:-}
certificate_file="$certificate_directory/server.crt"
private_key_file="$certificate_directory/server.key"
password_file="$certificate_directory/password"

for required_file in "$certificate_file" "$private_key_file" "$password_file"; do
  [[ -f "$required_file" ]] || fail "required file not found: $required_file"
  [[ -r "$required_file" ]] || fail "required file is not readable: $required_file"
done

command -v openssl >/dev/null 2>&1 || fail "openssl is required"
command -v base64 >/dev/null 2>&1 || fail "base64 is required"

openssl x509 -in "$certificate_file" -noout >/dev/null 2>&1 ||
  fail "server.crt is not a readable PEM certificate"

if ! openssl x509 -in "$certificate_file" -noout -checkend 0 >/dev/null 2>&1; then
  fail "server.crt is expired"
fi

certificate_text=$(openssl x509 -in "$certificate_file" -noout -text)
if grep -q 'X509v3 Extended Key Usage' <<<"$certificate_text" &&
  ! grep -Eq 'TLS Web Server Authentication|serverAuth' <<<"$certificate_text"; then
  fail "server.crt has Extended Key Usage but does not permit TLS server authentication"
fi

openssl pkey \
  -in "$private_key_file" \
  -passin "file:$password_file" \
  -noout >/dev/null 2>&1 ||
  fail "server.key cannot be opened with the password from password"

certificate_public_key_sha256=$(
  openssl x509 -in "$certificate_file" -pubkey -noout |
    openssl pkey -pubin -outform DER 2>/dev/null |
    openssl dgst -sha256 -r |
    awk '{print $1}'
)
private_public_key_sha256=$(
  openssl pkey \
    -in "$private_key_file" \
    -passin "file:$password_file" \
    -pubout -outform DER 2>/dev/null |
    openssl dgst -sha256 -r |
    awk '{print $1}'
)

[[ -n "$certificate_public_key_sha256" ]] || fail "cannot read the certificate public key"
[[ "$certificate_public_key_sha256" == "$private_public_key_sha256" ]] ||
  fail "server.crt and server.key do not belong to the same key pair"

if [[ -n "$relay_hostname" ]]; then
  openssl x509 \
    -in "$certificate_file" \
    -noout -checkhost "$relay_hostname" >/dev/null 2>&1 ||
    fail "server.crt is not valid for relay hostname: $relay_hostname"
fi

certificate_base64=$(base64 <"$certificate_file" | tr -d '\r\n')
private_key_base64=$(base64 <"$private_key_file" | tr -d '\r\n')
private_key_password=$(<"$password_file")

printf '%s\n' "Certificate accepted:"
openssl x509 -in "$certificate_file" -noout -subject -issuer -dates
openssl x509 -in "$certificate_file" -noout -ext subjectAltName 2>/dev/null || true
printf '\nPaste these three entries into the Relay Controller environment configuration:\n\n'
printf 'SERVER_SSL_CERT_BASE64=%s\n' "$certificate_base64"
printf 'SERVER_SSL_KEY_BASE64=%s\n' "$private_key_base64"
printf 'SERVER_SSL_KEY_PASSWORD=%s\n' "$private_key_password"
printf '\nWARNING: the last two values are secrets; do not commit or share this output.\n' >&2
