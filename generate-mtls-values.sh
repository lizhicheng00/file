#!/usr/bin/env bash

set -Eeuo pipefail

readonly P12_PASSWORD='123'

usage() {
    cat <<'EOF'
Usage:
  ./generate-mtls-values.sh [client-dir] [server-dir] [output-dir]

Defaults:
  client-dir  ./client
  server-dir  ./server
  output-dir  ./mtls

Each input directory must contain:
  server.crt    Certificate in PEM format
  server.key    Matching private key in PEM format
  password.txt  Password of server.key (an empty file means no password)

All generated PKCS#12 files use the password: 123
EOF
}

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi

readonly CLIENT_DIR="${1:-./client}"
readonly SERVER_DIR="${2:-./server}"
readonly OUTPUT_DIR="${3:-./mtls}"

for command_name in openssl keytool; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "Error: required command not found: ${command_name}" >&2
        exit 1
    fi
done

for input_dir in "${CLIENT_DIR}" "${SERVER_DIR}"; do
    for file_name in server.crt server.key password.txt; do
        if [[ ! -f "${input_dir}/${file_name}" ]]; then
            echo "Error: missing input file: ${input_dir}/${file_name}" >&2
            exit 1
        fi
    done
done

umask 077
mkdir -p "${OUTPUT_DIR}"
WORK_DIR="$(mktemp -d "${OUTPUT_DIR}/.generate-mtls.XXXXXX")"
readonly WORK_DIR

cleanup() {
    rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

key_password_args() {
    local password_file="$1"
    if [[ -s "${password_file}" ]]; then
        printf '%s\n' '-passin' "file:${password_file}"
    fi
}

validate_pair() {
    local side="$1"
    local input_dir="$2"
    local cert_public_key="${WORK_DIR}/${side}-cert-public.der"
    local private_public_key="${WORK_DIR}/${side}-key-public.der"
    local -a password_args=()

    mapfile -t password_args < <(key_password_args "${input_dir}/password.txt")

    openssl x509 -in "${input_dir}/server.crt" -checkend 0 -noout >/dev/null
    openssl x509 -in "${input_dir}/server.crt" -pubkey -noout \
        | openssl pkey -pubin -outform DER -out "${cert_public_key}"
    openssl pkey -in "${input_dir}/server.key" "${password_args[@]}" \
        -pubout -outform DER -out "${private_public_key}"

    if ! cmp -s "${cert_public_key}" "${private_public_key}"; then
        echo "Error: ${side} certificate and private key do not match" >&2
        exit 1
    fi
}

create_key_store() {
    local side="$1"
    local input_dir="$2"
    local output_file="$3"
    local -a password_args=()

    mapfile -t password_args < <(key_password_args "${input_dir}/password.txt")

    openssl pkcs12 -export \
        -in "${input_dir}/server.crt" \
        -inkey "${input_dir}/server.key" \
        "${password_args[@]}" \
        -name "relay-${side}" \
        -out "${output_file}" \
        -passout "pass:${P12_PASSWORD}"
}

create_trust_store() {
    local alias_name="$1"
    local certificate_file="$2"
    local output_file="$3"

    # keytool refuses to create a new keystore with a three-character password.
    # OpenSSL creates the container first, after which keytool can safely add a
    # Java trustedCertEntry while retaining the requested password "123".
    openssl pkcs12 -export -nokeys \
        -in "${certificate_file}" \
        -name placeholder \
        -out "${output_file}" \
        -passout "pass:${P12_PASSWORD}"
    keytool -importcert -noprompt \
        -alias "${alias_name}" \
        -file "${certificate_file}" \
        -keystore "${output_file}" \
        -storetype PKCS12 \
        -storepass "${P12_PASSWORD}" >/dev/null
}

validate_pair client "${CLIENT_DIR}"
validate_pair server "${SERVER_DIR}"

create_key_store client "${CLIENT_DIR}" "${WORK_DIR}/client-keystore.p12"
create_key_store server "${SERVER_DIR}" "${WORK_DIR}/server-keystore.p12"

# The server trusts the client certificate; the client trusts the server certificate.
create_trust_store relay-client "${CLIENT_DIR}/server.crt" \
    "${WORK_DIR}/server-truststore.p12"
create_trust_store relay-server "${SERVER_DIR}/server.crt" \
    "${WORK_DIR}/client-truststore.p12"

server_key_store_base64="$(openssl base64 -A -in "${WORK_DIR}/server-keystore.p12")"
server_trust_store_base64="$(openssl base64 -A -in "${WORK_DIR}/server-truststore.p12")"

{
    printf 'SERVER_SSL_KEY_STORE_BASE64=%s\n' "${server_key_store_base64}"
    printf 'SERVER_SSL_KEY_STORE_PASSWORD=%s\n' "${P12_PASSWORD}"
    printf 'SERVER_SSL_TRUST_STORE_BASE64=%s\n' "${server_trust_store_base64}"
    printf 'SERVER_SSL_TRUST_STORE_PASSWORD=%s\n' "${P12_PASSWORD}"
} > "${WORK_DIR}/server-mtls.env"

for output_name in \
    client-keystore.p12 \
    client-truststore.p12 \
    server-keystore.p12 \
    server-truststore.p12 \
    server-mtls.env; do
    mv -f -- "${WORK_DIR}/${output_name}" "${OUTPUT_DIR}/${output_name}"
done

echo "mTLS files generated in: ${OUTPUT_DIR}"
echo "Server environment values: ${OUTPUT_DIR}/server-mtls.env"
echo "PKCS#12 password: ${P12_PASSWORD}"
