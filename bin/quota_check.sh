#!/usr/bin/env bash
# =============================================================================
# quota_check.sh — 静态托管服务：单用户容量巡检（供 cron 调用）
# 目标路径: /usr/local/bin/quota_check.sh
#
# 用法:  quota_check.sh [上限MB] [--verbose] [--quiet] [--json]
# 退出码: 0 = 全部正常 | 2 = 存在超额用户（便于 cron 报警/告警联动）
# =============================================================================
set -Eeuo pipefail

PROG="$(basename "$0")"
SITES_ROOT="${SITES_ROOT:-/home/hosting/sites/u}"
LIMIT_MB="${1:-500}"
shift $(( $# > 0 ? 1 : 0 ))

VERBOSE=0; QUIET=0; JSON=0
for a in "$@"; do
  case "$a" in
    -v|--verbose) VERBOSE=1 ;;
    -q|--quiet)   QUIET=1 ;;
    --json)       JSON=1 ;;
    -h|--help)    sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知选项: %s\n' "$a" >&2; exit 64 ;;
  esac
done

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[36m'; C_DIM=$'\e[2m';  C_RST=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_RST=
fi
[[ $JSON -eq 1 ]] && { C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_RST=; }

die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 64; }
ts()   { date '+%Y-%m-%d %H:%M:%S'; }

# ---- 参数校验 ---------------------------------------------------------------
[[ "$LIMIT_MB" =~ ^[1-9][0-9]*$ ]] || die "上限必须为正整数（单位 MB），收到: '$LIMIT_MB'"
[[ -d "$SITES_ROOT" ]] || die "站点根目录不存在: $SITES_ROOT"

# ---- 巡检 -------------------------------------------------------------------
LIMIT_KB=$(( LIMIT_MB * 1024 ))
declare -a OVER_NAME=() OVER_KB=() OVER_PCT=()
scanned=0; total_kb=0

while IFS= read -r -d '' dir; do
  name="$(basename "$dir")"
  kb="$(du -sk -- "$dir" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  scanned=$(( scanned + 1 ))
  total_kb=$(( total_kb + kb ))
  if [[ "$kb" -gt "$LIMIT_KB" ]]; then
    OVER_NAME+=("$name"); OVER_KB+=("$kb")
    OVER_PCT+=("$(( kb * 100 / LIMIT_KB ))")
  elif [[ $VERBOSE -eq 1 && $QUIET -eq 0 ]]; then
    printf '%s[ok]%s %-16s %8s / %s\n' "$C_GRN" "$C_RST" "$name" \
      "$(awk -v k="$kb" 'BEGIN{printf "%.1fMB", k/1024}')" "${LIMIT_MB}MB"
  fi
done < <(find "$SITES_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

over="${#OVER_NAME[@]}"
total_str="$(awk -v k="$total_kb" 'BEGIN{printf "%.1fMB", k/1024}')"

# ---- JSON 输出 --------------------------------------------------------------
if [[ $JSON -eq 1 ]]; then
  printf '{"time":"%s","limit_mb":%d,"scanned":%d,"total_kb":%d,"over":%d,"users":[' \
    "$(ts)" "$LIMIT_MB" "$scanned" "$total_kb" "$over"
  for i in "${!OVER_NAME[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    printf '{"name":"%s","size_kb":%d,"usage_pct":%d}' \
      "${OVER_NAME[$i]}" "${OVER_KB[$i]}" "${OVER_PCT[$i]}"
  done
  printf ']}\n'
  [[ $over -eq 0 ]] && exit 0 || exit 2
fi

# ---- 文本输出 ---------------------------------------------------------------
if [[ $over -eq 0 ]]; then
  if [[ $QUIET -eq 0 ]]; then
    printf '%s[%s]%s 容量巡检通过：%d 个站点，合计 %s，上限 %s/站\n' \
      "$C_GRN" "$(ts)" "$C_RST" "$scanned" "$total_str" "${LIMIT_MB}MB"
  fi
  exit 0
fi

printf '%s[%s]%s 容量告警：%d 个站点超出上限 %s\n' \
  "$C_RED" "$(ts)" "$C_RST" "$over" "${LIMIT_MB}MB" >&2
for i in "${!OVER_NAME[@]}"; do
  printf '  %s%s%s  %s（占额度 %d%%）\n' \
    "$C_YEL" "${OVER_NAME[$i]}" "$C_RST" \
    "$(awk -v k="${OVER_KB[$i]}" 'BEGIN{printf "%.1fMB", k/1024}')" "${OVER_PCT[$i]}" >&2
  printf '    目录: %s/%s\n' "$SITES_ROOT" "${OVER_NAME[$i]}" >&2
done
printf '  %s处理建议: 通知用户清理，或 del_user.sh --backup -y <用户名> 归档下线%s\n' "$C_DIM" "$C_RST" >&2

exit 2
