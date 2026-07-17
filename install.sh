#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_RAW_URL="https://raw.githubusercontent.com/lizhicheng00/file/main"
MANAGED_FILES=(
  "options/ui.lnf.xml"
  "options/editor.xml"
  "options/colors.scheme.xml"
  "colors/Ordered Dark.icls"
)

target_dir=""
project_dir=""
force="false"
download_dir=""

usage() {
  cat <<'USAGE'
用法：bash install.sh [选项]

选项：
  --target PATH   指定 IntelliJ IDEA 配置目录
  --project PATH  同时把项目 .editorconfig 安装到指定项目
  --force         IDEA 运行时仍执行（不推荐）
  -h, --help      显示帮助
USAGE
}

fail() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || fail "--target 缺少路径"
      target_dir="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || fail "--project 缺少路径"
      project_dir="$2"
      shift 2
      ;;
    --force)
      force="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数：$1"
      ;;
  esac
done

if [[ "$force" != "true" ]] && pgrep -f 'com\.intellij\.idea\.Main|IntelliJ IDEA' >/dev/null 2>&1; then
  fail "检测到 IntelliJ IDEA 正在运行。请完全退出后重试。"
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

detect_target() {
  local current_name
  current_name="$(basename -- "$PWD")"
  if [[ "$current_name" == IntelliJIdea* || "$current_name" == IdeaIC* ]]; then
    printf '%s\n' "$PWD"
    return
  fi

  local roots=()
  roots+=("${XDG_CONFIG_HOME:-$HOME/.config}/JetBrains")
  roots+=("$HOME/Library/Application Support/JetBrains")

  local candidates=()
  local root candidate
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    for candidate in "$root"/IntelliJIdea* "$root"/IdeaIC*; do
      [[ -d "$candidate" ]] && candidates+=("$candidate")
    done
  done

  [[ ${#candidates[@]} -gt 0 ]] || return 1
  printf '%s\n' "${candidates[@]}" | sort | tail -n 1
}

if [[ -z "$target_dir" ]]; then
  target_dir="$(detect_target)" || fail "未找到 IDEA 配置目录，请使用 --target PATH 指定。"
fi

[[ -d "$target_dir" ]] || fail "目标目录不存在：$target_dir"
target_dir="$(cd -- "$target_dir" && pwd)"

cleanup() {
  if [[ -n "$download_dir" && -d "$download_dir" ]]; then
    rm -rf -- "$download_dir"
  fi
}
trap cleanup EXIT

source_root="$script_dir"
if [[ ! -f "$source_root/settings/options/ui.lnf.xml" ]]; then
  command -v curl >/dev/null 2>&1 || fail "脚本不在完整仓库中，且系统没有 curl，无法下载配置。"
  download_dir="$(mktemp -d)"
  source_root="$download_dir"
  for relative_path in "${MANAGED_FILES[@]}"; do
    mkdir -p -- "$source_root/settings/$(dirname -- "$relative_path")"
    curl -fsSL "$REPOSITORY_RAW_URL/settings/$relative_path" \
      -o "$source_root/settings/$relative_path"
  done
  mkdir -p -- "$source_root/project"
  curl -fsSL "$REPOSITORY_RAW_URL/project/.editorconfig" \
    -o "$source_root/project/.editorconfig"
fi

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_dir="$target_dir/ordered-dark-backups/$timestamp"
mkdir -p -- "$backup_dir"
printf '%s\n' "$target_dir" > "$backup_dir/.target-dir"

for relative_path in "${MANAGED_FILES[@]}"; do
  source_file="$source_root/settings/$relative_path"
  target_file="$target_dir/$relative_path"
  [[ -f "$source_file" ]] || fail "缺少配置文件：$source_file"

  if [[ -f "$target_file" ]]; then
    mkdir -p -- "$backup_dir/$(dirname -- "$relative_path")"
    cp -p -- "$target_file" "$backup_dir/$relative_path"
  else
    printf '%s\n' "$relative_path" >> "$backup_dir/.created-files"
  fi

  mkdir -p -- "$(dirname -- "$target_file")"
  cp -- "$source_file" "$target_file"
done

if [[ -n "$project_dir" ]]; then
  [[ -d "$project_dir" ]] || fail "项目目录不存在：$project_dir"
  project_dir="$(cd -- "$project_dir" && pwd)"
  if [[ -f "$project_dir/.editorconfig" ]]; then
    cp -p -- "$project_dir/.editorconfig" "$project_dir/.editorconfig.before-ordered-dark-$timestamp"
  fi
  cp -- "$source_root/project/.editorconfig" "$project_dir/.editorconfig"
  printf '项目配置已写入：%s/.editorconfig\n' "$project_dir"
fi

printf '\n安装完成。\n'
printf 'IDEA 配置目录：%s\n' "$target_dir"
printf '备份目录：%s\n' "$backup_dir"
printf '现在可以启动 IntelliJ IDEA。\n'
