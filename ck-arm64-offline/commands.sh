(
  set -eu
  set -o pipefail
  umask 077
  mkdir -p -m 700 "$HOME/ck-offline"
  cd "$HOME/ck-offline"
  tmp=$(mktemp ./devbox-ck-sql-arm64.XXXXXX)
  tty_mode=
  cleanup() {
    if [[ -n $tty_mode ]]; then stty "$tty_mode"; fi
    rm -f -- "$tmp" "$tmp.b64"
  }
  trap cleanup EXIT
  if [[ -t 0 ]]; then
    tty_mode=$(stty -g)
    stty -echo
  fi
  echo '粘贴 Base64 全文（或依次粘贴各分段），完成后按回车，再按 Ctrl+D。'
  cat > "$tmp.b64"
  if [[ -n $tty_mode ]]; then stty "$tty_mode"; tty_mode=; fi
  base64 -d "$tmp.b64" | gzip -dc > "$tmp"
  echo "80e56f0c1dc730b1f7f0bdc93a9ed809cbca6550171c552988cd0f82e3377d8f  $tmp" | sha256sum -c -
  chmod 700 "$tmp"
  mv -f -- "$tmp" ./devbox-ck-sql-arm64
  ./devbox-ck-sql-arm64 "SELECT execution_id, groupUniqArray(tenant_id) AS tenant_ids, count() AS versions
FROM devbox.sandbox_logs
WHERE sandbox_id = '81ea8f68-ad1a-41ad-b21d-5732268076eb'
GROUP BY execution_id ORDER BY execution_id"
)
