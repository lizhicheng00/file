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
Requires OpenSSL and Java 11 or newer. keytool is not required.
EOF
}

if [[ "${1:-}" == '-h' || "${1:-}" == '--help' ]]; then
    usage
    exit 0
fi

readonly CLIENT_DIR="${1:-./client}"
readonly SERVER_DIR="${2:-./server}"
readonly OUTPUT_DIR="${3:-./mtls}"

for command_name in openssl java; do
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

readonly TRUST_STORE_HELPER="${WORK_DIR}/CreateTrustStore.java"

cat > "${TRUST_STORE_HELPER}" <<'JAVA'
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.util.Collection;

public class CreateTrustStore {
    public static void main(String[] args) throws Exception {
        Path certificateFile = Path.of(args[0]);
        Path outputFile = Path.of(args[1]);
        String aliasPrefix = args[2];
        char[] password = args[3].toCharArray();

        Collection<? extends Certificate> certificates;
        CertificateFactory certificateFactory = CertificateFactory.getInstance("X.509");
        try (InputStream input = Files.newInputStream(certificateFile)) {
            certificates = certificateFactory.generateCertificates(input);
        }
        if (certificates.isEmpty()) {
            throw new IllegalArgumentException("No X.509 certificate found: " + certificateFile);
        }

        KeyStore trustStore = KeyStore.getInstance("PKCS12");
        trustStore.load(null, password);
        int index = 0;
        for (Certificate certificate : certificates) {
            String alias = index == 0 ? aliasPrefix : aliasPrefix + "-" + (index + 1);
            trustStore.setCertificateEntry(alias, certificate);
            index++;
        }

        try (OutputStream output = Files.newOutputStream(outputFile)) {
            trustStore.store(output, password);
        }
    }
}
JAVA

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

    java "${TRUST_STORE_HELPER}" \
        "${certificate_file}" \
        "${output_file}" \
        "${alias_name}" \
        "${P12_PASSWORD}"
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
