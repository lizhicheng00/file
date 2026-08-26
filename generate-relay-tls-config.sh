#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  generate-relay-tls-config.sh [certificate-directory] [relay-hostname]

The certificate directory defaults to the current directory and must contain:
  server.crt  PEM bundle: leaf certificate, intermediate CA(s), self-signed root CA
  server.key  PEM private key
  password    Private-key password; use an empty file for an unencrypted key

The script validates and separates the bundle, writes the public root CA to
relay-root-ca.crt, and prints the three Relay Controller TLS configuration
values. The Relay certificate value excludes the self-signed root CA.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

certificate_subject() {
  openssl x509 -in "$1" -noout -subject -nameopt RFC2253 2>/dev/null |
    sed 's/^subject=//'
}

certificate_issuer() {
  openssl x509 -in "$1" -noout -issuer -nameopt RFC2253 2>/dev/null |
    sed 's/^issuer=//'
}

certificate_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null |
    sed 's/^sha256 Fingerprint=//; s/^SHA256 Fingerprint=//'
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

certificate_directory=${1:-.}
relay_hostname=${2:-}
[[ -d "$certificate_directory" ]] || fail "certificate directory not found: $certificate_directory"
certificate_directory=$(cd -- "$certificate_directory" && pwd -P)

certificate_file="$certificate_directory/server.crt"
private_key_file="$certificate_directory/server.key"
password_file="$certificate_directory/password"
ca_output_file="$certificate_directory/relay-root-ca.crt"

for required_file in "$certificate_file" "$private_key_file" "$password_file"; do
  [[ -f "$required_file" ]] || fail "required file not found: $required_file"
  [[ -r "$required_file" ]] || fail "required file is not readable: $required_file"
done

command -v openssl >/dev/null 2>&1 || fail "openssl is required"
command -v base64 >/dev/null 2>&1 || fail "base64 is required"

work_directory=$(mktemp -d)
cleanup() {
  rm -rf -- "$work_directory"
}
trap cleanup EXIT

certificate_count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$certificate_file")
((certificate_count >= 2)) ||
  fail "server.crt must contain a leaf certificate and a self-signed root CA"

awk -v output_directory="$work_directory" '
  /-----BEGIN CERTIFICATE-----/ {
    certificate_count++
    output_file = output_directory "/cert-" certificate_count ".pem"
    in_certificate = 1
  }
  in_certificate { print > output_file }
  /-----END CERTIFICATE-----/ { in_certificate = 0 }
' "$certificate_file"

for ((index = 1; index <= certificate_count; index++)); do
  openssl x509 -in "$work_directory/cert-$index.pem" -noout >/dev/null 2>&1 ||
    fail "certificate block $index in server.crt is invalid"
done

leaf_certificate="$work_directory/cert-1.pem"
if openssl x509 -in "$leaf_certificate" -noout -ext basicConstraints 2>/dev/null |
  grep -q 'CA:TRUE'; then
  fail "the first certificate in server.crt is a CA; the leaf server certificate must be first"
fi

if ! openssl x509 -in "$leaf_certificate" -noout -checkend 0 >/dev/null 2>&1; then
  fail "the leaf server certificate is expired"
fi

certificate_text=$(openssl x509 -in "$leaf_certificate" -noout -text)
if grep -q 'X509v3 Extended Key Usage' <<<"$certificate_text" &&
  ! grep -Eq 'TLS Web Server Authentication|serverAuth' <<<"$certificate_text"; then
  fail "the leaf certificate does not permit TLS server authentication"
fi

root_ca_index=0
for ((index = 2; index <= certificate_count; index++)); do
  candidate="$work_directory/cert-$index.pem"
  subject=$(certificate_subject "$candidate")
  issuer=$(certificate_issuer "$candidate")
  if [[ "$subject" == "$issuer" ]] &&
    openssl x509 -in "$candidate" -noout -ext basicConstraints 2>/dev/null |
      grep -q 'CA:TRUE' &&
    openssl verify -CAfile "$candidate" "$candidate" 2>/dev/null |
      grep -q ': OK$'; then
    ((root_ca_index == 0)) || fail "server.crt contains more than one self-signed root CA"
    root_ca_index=$index
  fi
done

((root_ca_index > 0)) || fail "cannot find a valid self-signed root CA in server.crt"
root_ca="$work_directory/cert-$root_ca_index.pem"

server_chain="$work_directory/relay-fullchain.pem"
intermediate_chain="$work_directory/intermediate-chain.pem"
: >"$server_chain"
: >"$intermediate_chain"
for ((index = 1; index <= certificate_count; index++)); do
  if ((index == root_ca_index)); then
    continue
  fi
  cat "$work_directory/cert-$index.pem" >>"$server_chain"
  if ((index > 1)); then
    cat "$work_directory/cert-$index.pem" >>"$intermediate_chain"
  fi
done

if [[ -s "$intermediate_chain" ]]; then
  openssl verify -purpose sslserver -CAfile "$root_ca" \
    -untrusted "$intermediate_chain" "$leaf_certificate" >/dev/null 2>&1 ||
    fail "the server certificate chain cannot be verified by the embedded root CA"
else
  openssl verify -purpose sslserver -CAfile "$root_ca" \
    "$leaf_certificate" >/dev/null 2>&1 ||
    fail "the server certificate cannot be verified by the embedded root CA"
fi

openssl pkey \
  -in "$private_key_file" \
  -passin "file:$password_file" \
  -noout >/dev/null 2>&1 ||
  fail "server.key cannot be opened with the password from password"

certificate_public_key_sha256=$(
  openssl x509 -in "$leaf_certificate" -pubkey -noout |
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
    -in "$leaf_certificate" \
    -noout -checkhost "$relay_hostname" >/dev/null 2>&1 ||
    fail "server.crt is not valid for relay hostname: $relay_hostname"
fi

if [[ -e "$ca_output_file" ]]; then
  [[ -f "$ca_output_file" ]] || fail "CA output path is not a regular file: $ca_output_file"
  existing_ca_fingerprint=$(certificate_fingerprint "$ca_output_file")
  root_ca_fingerprint=$(certificate_fingerprint "$root_ca")
  [[ -n "$existing_ca_fingerprint" && "$existing_ca_fingerprint" == "$root_ca_fingerprint" ]] ||
    fail "existing relay-root-ca.crt is a different certificate; it was not overwritten"
else
  cp -- "$root_ca" "$ca_output_file"
  chmod 0644 "$ca_output_file"
fi

certificate_base64=$(base64 <"$server_chain" | tr -d '\r\n')
private_key_base64=$(base64 <"$private_key_file" | tr -d '\r\n')
private_key_password=$(<"$password_file")

printf '%s\n' "Certificate bundle accepted:"
printf '  input certificates: %s\n' "$certificate_count"
printf '  Relay certificates: %s (self-signed root excluded)\n' "$((certificate_count - 1))"
openssl x509 -in "$leaf_certificate" -noout -subject -issuer -dates
openssl x509 -in "$leaf_certificate" -noout -ext subjectAltName 2>/dev/null || true

printf '\nPaste these three entries into the Relay Controller environment configuration:\n\n'
printf 'SERVER_SSL_CERT_BASE64=%s\n' "$certificate_base64"
printf 'SERVER_SSL_KEY_BASE64=%s\n' "$private_key_base64"
printf 'SERVER_SSL_KEY_PASSWORD=%s\n' "$private_key_password"

printf '\nGive this public CA certificate to the CLI:\n\n'
printf 'CLI_CA_CERT_FILE=%s\n' "$ca_output_file"
openssl x509 -in "$ca_output_file" -noout -subject -issuer -dates -fingerprint -sha256

printf '\nWARNING: SERVER_SSL_KEY_BASE64 and SERVER_SSL_KEY_PASSWORD are secrets.\n' >&2
