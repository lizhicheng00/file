#!/usr/bin/env bash
set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required" >&2
    exit 1
fi

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [output-file]" >&2
    exit 1
fi

primary="$(openssl rand -hex 32)"
standby="$(openssl rand -hex 32)"
while [[ "$standby" == "$primary" ]]; do
    standby="$(openssl rand -hex 32)"
done

write_keys() {
    printf 'RELAY_API_KEY_PRIMARY=%s\n' "$primary"
    printf 'RELAY_API_KEY_STANDBY=%s\n' "$standby"
}

if [[ $# -eq 0 ]]; then
    write_keys
    exit 0
fi

output_file="$1"
if [[ -e "$output_file" ]]; then
    echo "Refusing to overwrite existing file: $output_file" >&2
    exit 1
fi

umask 077
write_keys > "$output_file"
echo "Generated Relay API keys: $output_file" >&2
