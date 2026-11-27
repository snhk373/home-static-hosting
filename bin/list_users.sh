#!/usr/bin/env bash
# =============================================================================
# list_users.sh — 静态托管服务：列出全部站点用户及资源占用
# 目标路径: /usr/local/bin/list_users.sh
# 依赖: coreutils(du/find/date) + GNU find 的 -printf
# =============================================================================
set -Eeuo pipefail

PROG="$(basename "$0")"
SITES_ROOT="${SITES_ROOT:-/home/hosting/sites/u}"
PUBLIC_BASE="${PUBLIC_BASE:-http://your-frp-domain:PORT}"

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[36m'; C_CYN=$'\e[36m'; C_DIM=$'\e[2m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_CYN=; C_DIM=; C_BLD=; C_RST=
fi
die() { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

JSON=0
for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --json) JSON=1 ;;
    *) die "未知选项: $a（支持 --json / -h）" ;;
  esac
done

[[ -d "$SITES_ROOT" ]] || die "站点根目录不存在: $SITES_ROOT"

# ---- 采集 -------------------------------------------------------------------
declare -a NAMES=() SIZES=() SIZE_MB=() SIZE_KB=() FILES=() MTIMES=()
total_kb=0

while IFS= read -r -d '' dir; do
  name="$(basename "$dir")"
  kb="$(du -sk -- "$dir" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  sz="$(du -sh -- "$dir" 2>/dev/null | cut -f1)";  sz="${sz:-0}"
  cnt="$(find "$dir" -type f 2>/dev/null | wc -l)"
  # 站点最后修改时间 = 目录内最新文件的 mtime（无文件时退回目录本身）
  ts="$(find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
  if [[ -z "$ts" ]]; then
    ts="$(stat -c '%Y' -- "$dir" 2>/dev/null || echo 0)"
  fi
  mt="$(date -d "@${ts%.*}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '-')"

  NAMES+=("$name"); SIZES+=("$sz"); SIZE_KB+=("$kb")
  SIZE_MB+=("$(( kb / 1024 ))"); FILES+=("$cnt"); MTIMES+=("$mt")
  total_kb=$(( total_kb + kb ))
done < <(find "$SITES_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

count="${#NAMES[@]}"
# 合计容量，保留 1 位小数（KB → MB）
total_mb_str="$(awk -v k="$total_kb" 'BEGIN{printf "%.1f", k/1024}')"

# ---- JSON 输出（供脚本/前端消费）--------------------------------------------
if [[ $JSON -eq 1 ]]; then
  printf '{"root":"%s","count":%d,"total_kb":%d,"total_mb":%s,"users":[' \
    "$SITES_ROOT" "$count" "$total_kb" "$total_mb_str"
  for i in "${!NAMES[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    printf '{"name":"%s","size":"%s","size_kb":%d,"size_mb":%d,"files":%d,"mtime":"%s","url":"%s/u/%s/"}' \
      "${NAMES[$i]}" "${SIZES[$i]}" "${SIZE_KB[$i]}" "${SIZE_MB[$i]}" "${FILES[$i]}" "${MTIMES[$i]}" \
      "${PUBLIC_BASE%/}" "${NAMES[$i]}"
  done
  printf ']}\n'
  exit 0
fi

# ---- 表格输出 ---------------------------------------------------------------
printf '%s静态托管站点列表%s  %s(%s)%s\n\n' \
  "$C_BLD" "$C_RST" "$C_DIM" "$SITES_ROOT" "$C_RST"

if [[ $count -eq 0 ]]; then
  printf '%s  暂无用户，使用 add_user.sh <用户名> 创建%s\n' "$C_YEL" "$C_RST"
  exit 0
fi

# 表头：中日韩字符在 UTF-8 下为 3 字节、占 2 列，故按"字节宽 = 列宽 + 1/字"补偿，
# 用与数据行相同的 printf 格式即可自动对齐。
printf '%s%-21s %14s %11s  %-22s  %s%s\n' \
  "$C_BLD" "用户名" "磁盘大小" "文件数" "最后修改时间" "访问 URL" "$C_RST"
printf '%s%s%s\n' "$C_DIM" "$(printf '─%.0s' $(seq 1 98))" "$C_RST"

for i in "${!NAMES[@]}"; do
  url="${PUBLIC_BASE%/}/u/${NAMES[$i]}/"
  # 单用户超过 500MB 时高亮提醒
  if [[ "${SIZE_MB[$i]}" -gt 500 ]]; then
    color="$C_YEL"
  else
    color="$C_RST"
  fi
  printf '%s%-18s %10s %8s  %-16s  %s%s%s\n' \
    "$color" "${NAMES[$i]}" "${SIZES[$i]}" "${FILES[$i]}" "${MTIMES[$i]}" "$C_CYN" "$url" "$C_RST"
done

printf '%s%s%s\n' "$C_DIM" "$(printf '─%.0s' $(seq 1 98))" "$C_RST"
printf '  共 %d 个站点，合计 %s MB\n' "$count" "$total_mb_str"
exit 0
