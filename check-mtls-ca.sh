#!/usr/bin/env bash
# Usage: ./check-mtls-ca.sh /path/to/mtls
# Expected layout: server/{*.crt,*.key,password} and client/{*.crt,*.key,password}.

set -u

root=${1:-.}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

find_file() {
    local dir=$1
    local kind=$2
    local file=''

    case "$kind" in
        cert)
            file=$(find "$dir" -maxdepth 1 \( -type f -o -type l \) \( -iname '*.crt' -o -iname '*cert.pem' -o -iname '*crt' \) -print -quit)
            ;;
        key)
            file=$(find "$dir" -maxdepth 1 \( -type f -o -type l \) \( -iname '*.key' -o -iname '*key.pem' -o -iname '*key' \) -print -quit)
            ;;
        password)
            file=$(find "$dir" -maxdepth 1 \( -type f -o -type l \) \( -iname 'password' -o -iname 'password.txt' -o -iname '*password*' \) -print -quit)
            ;;
    esac

    [ -n "$file" ] || fail "cannot find $kind file under $dir"
    printf '%s' "$file"
}

split_certificates() {
    local bundle=$1
    local output_dir=$2

    mkdir -p "$output_dir"
    awk -v dir="$output_dir" '
        /-----BEGIN CERTIFICATE-----/ { count++ }
        count > 0 { print > (dir "/cert-" count ".pem") }
    ' "$bundle"
}

certificate_field() {
    local cert=$1
    local field=$2
    openssl x509 -in "$cert" -noout "-$field" 2>/dev/null | sed "s/^$field=//"
}

authority_key_id() {
    openssl x509 -in "$1" -noout -ext authorityKeyIdentifier 2>/dev/null |
        awk 'NR > 1 { gsub(/[[:space:]]/, "", $0); printf "%s", $0 }'
}

public_key_hash_from_cert() {
    openssl x509 -in "$1" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        openssl dgst -sha256 | awk '{print $2}'
}

public_key_hash_from_key() {
    openssl pkey -in "$1" -passin "file:$2" -pubout -outform DER 2>/dev/null |
        openssl dgst -sha256 | awk '{print $2}'
}

inspect_side() {
    local role=$1
    local purpose=$2
    local dir="$root/$role"
    local cert key password cert_dir count cert_hash key_hash chain_file verify_output

    [ -d "$dir" ] || fail "directory does not exist: $dir"
    cert=$(find_file "$dir" cert) || exit 1
    key=$(find_file "$dir" key) || exit 1
    password=$(find_file "$dir" password) || exit 1
    cert_dir="$work_dir/$role"
    split_certificates "$cert" "$cert_dir"
    count=$(find "$cert_dir" -type f -name 'cert-*.pem' | wc -l)
    [ "$count" -gt 0 ] || fail "$cert is not a PEM certificate"

    printf '\n[%s]\n' "${role^^}"
    printf 'certificate: %s\n' "$cert"
    printf 'private key: %s\n' "$key"
    printf 'certificates in bundle: %s\n' "$count"
    openssl x509 -in "$cert_dir/cert-1.pem" -noout \
        -subject -issuer -serial -dates -fingerprint -sha256
    openssl x509 -in "$cert_dir/cert-1.pem" -noout -text |
        sed -n '/Public-Key:/p;/Signature Algorithm:/p;/Extended Key Usage/,+1p;/Subject Alternative Name/,+1p'

    cert_hash=$(public_key_hash_from_cert "$cert_dir/cert-1.pem")
    key_hash=$(public_key_hash_from_key "$key" "$password")
    if [ -n "$cert_hash" ] && [ "$cert_hash" = "$key_hash" ]; then
        printf 'certificate/private-key match: YES\n'
    else
        printf 'certificate/private-key match: NO\n'
        failures=$((failures + 1))
    fi

    if openssl x509 -in "$cert_dir/cert-1.pem" -purpose -noout 2>/dev/null |
        grep -q "SSL $purpose : Yes"; then
        printf 'TLS purpose (%s): YES\n' "$purpose"
    else
        printf 'TLS purpose (%s): NO\n' "$purpose"
        failures=$((failures + 1))
    fi

    if [ "$count" -gt 1 ]; then
        printf 'embedded issuer certificates:\n'
        local index=2
        while [ "$index" -le "$count" ]; do
            printf '  %s. subject=%s\n' "$index" "$(certificate_field "$cert_dir/cert-$index.pem" subject)"
            printf '     issuer=%s\n' "$(certificate_field "$cert_dir/cert-$index.pem" issuer)"
            index=$((index + 1))
        done
    else
        printf 'embedded issuer certificates: NONE\n'
    fi

    chain_file="$work_dir/$role-chain.pem"
    if [ "$count" -gt 1 ]; then
        awk 'BEGIN { count=0 } /-----BEGIN CERTIFICATE-----/ { count++ } count >= 2 { print }' \
            "$cert" > "$chain_file"
        verify_output=$(openssl verify -purpose "ssl$purpose" -untrusted "$chain_file" \
            "$cert_dir/cert-1.pem" 2>&1) || true
    else
        verify_output=$(openssl verify -purpose "ssl$purpose" "$cert_dir/cert-1.pem" 2>&1) || true
    fi
    if printf '%s' "$verify_output" | grep -q ': OK$'; then
        printf 'trusted by this machine: YES\n'
    else
        printf 'trusted by this machine: NO\n'
    fi

    if [ "$role" = server ]; then
        server_issuer=$(certificate_field "$cert_dir/cert-1.pem" issuer)
        server_aki=$(authority_key_id "$cert_dir/cert-1.pem")
        server_count=$count
        server_last="$cert_dir/cert-$count.pem"
    else
        client_issuer=$(certificate_field "$cert_dir/cert-1.pem" issuer)
        client_aki=$(authority_key_id "$cert_dir/cert-1.pem")
        client_count=$count
        client_last="$cert_dir/cert-$count.pem"
    fi
}

command -v openssl >/dev/null 2>&1 || fail 'openssl is required'
[ -d "$root" ] || fail "root directory does not exist: $root"

failures=0
server_issuer=''
client_issuer=''
server_aki=''
client_aki=''
server_count=0
client_count=0
server_last=''
client_last=''

printf 'mTLS certificate inspection\n'
printf 'root: %s\n' "$(cd "$root" && pwd)"

inspect_side server server
inspect_side client client

printf '\n[CA SUMMARY]\n'
if [ "$server_issuer" = "$client_issuer" ]; then
    printf 'same issuer name: YES\n'
else
    printf 'same issuer name: NO\n'
fi

if [ -n "$server_aki" ] && [ "$server_aki" = "$client_aki" ]; then
    printf 'same authority key identifier: YES\n'
    printf 'issuer assessment: VERY LIKELY the same CA key\n'
elif [ "$server_issuer" = "$client_issuer" ]; then
    printf 'same authority key identifier: UNKNOWN OR DIFFERENT\n'
    printf 'issuer assessment: LIKELY the same CA name, not cryptographically proven\n'
else
    printf 'same authority key identifier: NO\n'
    printf 'issuer assessment: DIFFERENT issuers\n'
fi

if [ "$server_count" -gt 1 ] && [ "$client_count" -gt 1 ]; then
    server_root_hash=$(openssl x509 -in "$server_last" -noout -fingerprint -sha256 2>/dev/null)
    client_root_hash=$(openssl x509 -in "$client_last" -noout -fingerprint -sha256 2>/dev/null)
    if [ "$server_root_hash" = "$client_root_hash" ]; then
        printf 'same last embedded CA certificate: YES\n'
    else
        printf 'same last embedded CA certificate: NO\n'
    fi
else
    printf 'same last embedded CA certificate: UNKNOWN (CA chain is not embedded on both sides)\n'
fi

printf '\n[RESULT]\n'
if [ "$failures" -eq 0 ]; then
    printf 'certificate/key pairs and TLS purposes are valid.\n'
else
    printf '%s essential check(s) failed.\n' "$failures"
fi
printf 'Without an embedded CA certificate or a separate ca.crt, issuer identity can be inferred but not fully verified.\n'
printf '"trusted by this machine" may include a company-installed private CA; it does not prove a public CA.\n'

[ "$failures" -eq 0 ]
