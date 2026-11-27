#!/usr/bin/env bash
(
  set -euo pipefail
  umask 077
  src=/tmp/ck-base
  if [[ -d $src ]]; then src="$src/devbox-ck-sql-arm64.gz.b64.txt"; fi
  if [[ ! -f $src || ! -r $src ]]; then
    echo "找不到可读的 Base64 文件：$src" >&2
    exit 1
  fi
  mkdir -p "$HOME/ck-offline"
  cd "$HOME/ck-offline"
  tmp=$(mktemp ./devbox-ck-sql-arm64.XXXXXX)
  trap 'rm -f -- "$tmp"' EXIT
  tr -d '[:space:]' < "$src" | base64 -d | gzip -dc > "$tmp"
  echo "80e56f0c1dc730b1f7f0bdc93a9ed809cbca6550171c552988cd0f82e3377d8f  $tmp" | sha256sum -c -
  chmod 700 "$tmp"
  mv -f -- "$tmp" ./devbox-ck-sql-arm64
  ./devbox-ck-sql-arm64 "SELECT execution_id, groupUniqArray(tenant_id) AS tenant_ids, count() AS versions
FROM devbox.sandbox_logs
WHERE sandbox_id = '81ea8f68-ad1a-41ad-b21d-5732268076eb'
GROUP BY execution_id ORDER BY execution_id"
)
