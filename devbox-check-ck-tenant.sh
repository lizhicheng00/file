#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  printf '用法: bash %s <CK 域名> <查询账号> <沙箱 UUID>\n' "$0" >&2
  exit 2
fi

ck_host=$1
ck_user=$2
sandbox_id=$3
if [[ ! $ck_host =~ ^[[:alnum:]][[:alnum:].-]*$ ]]; then
  printf '只填 CK 域名，例如 ck.example.com。\n' >&2
  exit 2
fi
if [[ ! $sandbox_id =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
  printf '沙箱 ID 必须是 UUID。\n' >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
client="$script_dir/devbox-ck-query-arm64"
if [[ ! -f $client ]]; then
  printf '请将 devbox-ck-query-arm64 和脚本放在同一目录。\n' >&2
  exit 1
fi
if [[ ! -x $client ]]; then
  chmod u+x -- "$client"
fi

ca_b64=${CLICKHOUSE_CA_CERT_B64:-}
if [[ -z $ca_b64 ]]; then
  printf '粘贴单行 Base64 CA，然后回车: ' >/dev/tty
  IFS= read -rs ca_b64 </dev/tty
  printf '\n' >/dev/tty
fi
printf 'ClickHouse 密码: ' >/dev/tty
IFS= read -rs ck_password </dev/tty
printf '\n' >/dev/tty

printf '%s\n%s\n' "$ca_b64" "$ck_password" | "$client" "$ck_host" "$ck_user" "$sandbox_id"
