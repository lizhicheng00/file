#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  printf '用法: bash %s <CK域名> <查询账号> <沙箱UUID>\n' "$0" >&2
  exit 2
fi

host=$1
user=$2
sandbox_id=$3
if [[ ! $host =~ ^[[:alnum:]][[:alnum:].-]*$ ]] ||
   [[ ! $sandbox_id =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
  printf '请填写 CK 域名（不带协议和端口）及有效的沙箱 UUID。\n' >&2
  exit 2
fi

ca_b64=${CLICKHOUSE_CA_CERT_B64:-}
if [[ -z $ca_b64 ]]; then
  printf '粘贴单行 Base64 CA，然后回车: ' >/dev/tty
  IFS= read -rs ca_b64 </dev/tty
  printf '\n' >/dev/tty
fi

ca_file=$(mktemp)
trap 'rm -f -- "$ca_file"' EXIT
if ! printf '%s' "$ca_b64" | base64 -d > "$ca_file" || [[ ! -s $ca_file ]]; then
  printf 'Base64 CA 无效或为空。\n' >&2
  exit 2
fi

curl --noproxy '*' --silent --show-error --fail \
  --connect-timeout 5 --max-time 25 --cacert "$ca_file" \
  --user "$user" --data-binary @- "https://$host:8443/" <<SQL
SELECT execution_id, groupUniqArray(tenant_id) AS tenant_ids, count() AS versions
FROM devbox.sandbox_logs
WHERE sandbox_id = '$sandbox_id'
GROUP BY execution_id
FORMAT TabSeparatedWithNames
SQL
