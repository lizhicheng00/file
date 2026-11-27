#!/usr/bin/env bash
set -eu

usage() {
  echo "用法: bash $0 [-k] <沙箱UUID> 或 bash $0 --orch <已安装的devbox-ck-sql绝对路径> <沙箱UUID>" >&2
  exit 2
}

tls=()
orch_client=
case ${1:-} in
  -k) tls=(-k); shift ;;
  --orch) (( $# == 3 )) || usage; orch_client=$2; shift 2
    [[ $orch_client == /* && -f $orch_client && -x $orch_client ]] || usage ;;
esac
(( $# == 1 )) || usage
[[ $1 =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]] || usage

sql="SELECT execution_id, groupUniqArray(tenant_id) AS tenant_ids, count() AS versions
FROM devbox.sandbox_logs WHERE sandbox_id = '$1'
GROUP BY execution_id ORDER BY execution_id"
if [[ -n $orch_client ]]; then
  exec "$orch_client" "$sql"
fi

read -rp 'CK 内网域名或 IPv4（不带端口）: ' host
read -rp 'CK 只读账号: ' ck_user
[[ $host =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && -n $ck_user && $ck_user != *:* ]] || usage
curl -q "${tls[@]}" -fsS --noproxy '*' --connect-timeout 5 --max-time 30 \
  --user "$ck_user" --data-binary "$sql FORMAT TabSeparatedWithNames" "https://$host:8443/"
