#!/usr/bin/env bash
set -euo pipefail

MANAGED_FILES=(
  "options/laf.xml"
  "options/ui.lnf.xml"
  "options/editor.xml"
  "options/colors.scheme.xml"
  "colors/Ordered Dark.icls"
)

fail() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "用法：bash restore.sh /path/to/backup"
backup_dir="$1"
[[ -d "$backup_dir" ]] || fail "备份目录不存在：$backup_dir"
[[ -f "$backup_dir/.target-dir" ]] || fail "备份目录缺少 .target-dir"

if pgrep -f 'com\.intellij\.idea\.Main|IntelliJ IDEA' >/dev/null 2>&1; then
  fail "检测到 IntelliJ IDEA 正在运行。请完全退出后重试。"
fi

target_dir="$(sed -n '1p' "$backup_dir/.target-dir")"
[[ -d "$target_dir" ]] || fail "原 IDEA 配置目录不存在：$target_dir"

for relative_path in "${MANAGED_FILES[@]}"; do
  target_file="$target_dir/$relative_path"
  backup_file="$backup_dir/$relative_path"
  if [[ -f "$backup_file" ]]; then
    mkdir -p -- "$(dirname -- "$target_file")"
    cp -p -- "$backup_file" "$target_file"
  elif [[ -f "$backup_dir/.created-files" ]] && grep -Fxq "$relative_path" "$backup_dir/.created-files"; then
    rm -f -- "$target_file"
  fi
done

printf '恢复完成：%s\n' "$target_dir"
