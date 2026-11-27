#!/usr/bin/env bash
set -euo pipefail

if (( $# < 3 || $# > 4 )); then
  printf '用法: bash %s <CK 域名> <CK 用户名> <沙箱 UUID> [CA PEM 路径]\n' "$0" >&2
  exit 2
fi

ck_host=$1
ck_user=$2
sandbox_id=$3

if [[ ! $sandbox_id =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
  printf '沙箱 ID 必须是 UUID。\n' >&2
  exit 2
fi

tls_args=()
if (( $# == 4 )); then
  tls_args=(--cacert "$4")
fi

curl --noproxy '*' --fail --silent --show-error \
  --connect-timeout 5 --max-time 25 \
  --user "$ck_user" "${tls_args[@]}" \
  --data-binary @- "https://${ck_host}:8443/" <<SQL
SELECT execution_id, groupUniqArray(tenant_id) AS tenant_ids, count() AS versions
FROM devbox.sandbox_logs
WHERE sandbox_id = '${sandbox_id}'
GROUP BY execution_id
FORMAT TabSeparatedWithNames
SQL
