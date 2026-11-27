#!/usr/bin/env bash
set -euo pipefail

verify_args=()
if [[ ${1:-} == -k ]]; then
  verify_args=(-k)
  shift
fi
if (( $# != 3 )); then
  printf '用法: bash %s [-k] <CK域名或IPv4> <查询账号> <沙箱UUID>\n' "$0" >&2
  exit 2
fi

host=$1
user=$2
sandbox_id=$3
if [[ ! $host =~ ^[[:alnum:]][[:alnum:].-]*$ ]] ||
   [[ ! $sandbox_id =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
  printf '填写 CK 域名或 IPv4（不带端口）及沙箱 UUID。\n' >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
bundle=devbox-ck-query-9440-arm64.gz
sha=7c802d900f3e80bfd0e3ef1acddf2b8c90ce187c6ca08b45d3b156ad3ef1342a
if [[ -f $bundle ]]; then
  cp -- "$bundle" "$tmp/$bundle"
else
  curl -fsSL --connect-timeout 5 --max-time 45 \
    "https://raw.githubusercontent.com/lizhicheng00/file/master/$bundle" -o "$tmp/$bundle"
fi
printf '%s  %s\n' "$sha" "$tmp/$bundle" | sha256sum -c --status
gzip -dc "$tmp/$bundle" > "$tmp/devbox-ck-query"
chmod 700 "$tmp/devbox-ck-query"

ca_b64=${CLICKHOUSE_CA_CERT_B64:-}
if (( ${#verify_args[@]} == 0 )); then
  if [[ -z $ca_b64 ]]; then
    printf '粘贴单行 Base64 CA，然后回车: ' >/dev/tty
    IFS= read -rs ca_b64 </dev/tty
    printf '\n' >/dev/tty
  fi
else
  printf '本次查询已跳过 CK 服务端证书校验。\n' >&2
fi
printf 'ClickHouse 密码: ' >/dev/tty
IFS= read -rs password </dev/tty
printf '\n' >/dev/tty
{
  if (( ${#verify_args[@]} == 0 )); then
    printf '%s\n' "$ca_b64"
  fi
  printf '%s\n' "$password"
} | "$tmp/devbox-ck-query" "${verify_args[@]}" -- "$host" "$user" "$sandbox_id"
