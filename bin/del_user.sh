#!/usr/bin/env bash
# =============================================================================
# del_user.sh — 静态托管服务：删除站点用户（支持先备份）
# 目标路径: /usr/local/bin/del_user.sh
# 依赖: coreutils(tar/du/install) + docker(可选，用于同步删除 File Browser 账号)
# =============================================================================
set -Eeuo pipefail

PROG="$(basename "$0")"
ORIG_ARGS="$*"

SITES_ROOT="${SITES_ROOT:-/home/hosting/sites/u}"
BACKUP_DIR="${BACKUP_DIR:-/home/hosting/backup}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-0}"   # >0 时顺带清理过期备份
FB_CONTAINER="${FB_CONTAINER:-filebrowser}" # File Browser 容器名，置空则跳过
PUBLIC_BASE="${PUBLIC_BASE:-http://your-frp-domain:PORT}"

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[36m'; C_DIM=$'\e[2m';  C_RST=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_RST=
fi
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
trap 'printf "%s[x]%s 第 %s 行执行失败\n" "$C_RED" "$C_RST" "$LINENO" >&2' ERR

usage() {
  cat <<EOF
用法: $PROG <用户名> [选项]

选项:
  -b, --backup     删除前先打包到 $BACKUP_DIR/<用户名>-<时间戳>.tar.gz
  -y, --yes        跳过交互确认（供脚本/API 调用）
  -h, --help       显示本帮助

示例:
  $PROG alice                 # 交互确认后直接删除
  $PROG alice --backup        # 备份后删除
  $PROG alice --backup -y     # 无人值守：备份 → 删除
EOF
}

# ---- 参数解析 ---------------------------------------------------------------
USERNAME=""; DO_BACKUP=0; ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -b|--backup) DO_BACKUP=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    --) shift; break ;;
    -*) die "未知选项: $1（使用 -h 查看帮助）" ;;
    *)
      if [[ -z "$USERNAME" ]]; then USERNAME="$1"; else die "存在多余参数: $1"; fi
      shift ;;
  esac
done
[[ $# -eq 0 ]] || die "存在多余参数: $*"

[[ -n "$USERNAME" ]] || { usage; echo; die "必须指定用户名"; }
[[ "$USERNAME" =~ ^[a-z0-9][a-z0-9_-]{2,31}$ ]] || die "用户名不合法：'$USERNAME'"
[[ $EUID -eq 0 ]] || die "需要 root 权限：sudo $PROG $ORIG_ARGS"

TARGET="$SITES_ROOT/$USERNAME"

# ---- 安全校验：目标必须真实存在于站点根下，且不是符号链接 ---------------------
[[ -d "$TARGET" ]] || die "用户不存在: $TARGET"
[[ ! -L "$TARGET" ]] || die "拒绝操作：$TARGET 是符号链接"
REAL="$(readlink -f -- "$TARGET")"
ROOT_REAL="$(readlink -f -- "$SITES_ROOT")"
[[ "$REAL" == "$ROOT_REAL"/* ]] || die "拒绝操作：$REAL 不在 $ROOT_REAL 之内"
[[ "$(basename "$REAL")" == "$USERNAME" ]] || die "拒绝操作：路径名与用户名不一致"

SIZE="$(du -sh -- "$TARGET" 2>/dev/null | cut -f1)"
FILES="$(find "$TARGET" -type f 2>/dev/null | wc -l)"

# ---- 确认 -------------------------------------------------------------------
echo
printf '  即将删除的站点\n'
printf '    用户名   : %s\n' "$USERNAME"
printf '    目录     : %s\n' "$TARGET"
printf '    占用     : %s / %s 个文件\n' "$SIZE" "$FILES"
printf '    访问地址 : %s%s/u/%s/%s\n' "$C_DIM" "${PUBLIC_BASE%/}" "$USERNAME" "$C_RST"
printf '    备份     : %s\n' "$([[ $DO_BACKUP -eq 1 ]] && echo "是 → $BACKUP_DIR" || echo "否")"
echo

if [[ $ASSUME_YES -ne 1 ]]; then
  [[ -t 0 ]] || die "非交互环境请显式加 --yes"
  read -r -p "确认删除？此操作不可逆 [y/N] " ans
  case "${ans,,}" in
    y|yes) ;;
    *) warn "已取消"; exit 1 ;;
  esac
fi

# ---- 备份 -------------------------------------------------------------------
ARCHIVE=""
if [[ $DO_BACKUP -eq 1 ]]; then
  mkdir -p -- "$BACKUP_DIR"
  chmod 750 -- "$BACKUP_DIR"
  ARCHIVE="$BACKUP_DIR/${USERNAME}-$(date +%Y%m%d-%H%M%S).tar.gz"
  info "打包备份 → $ARCHIVE"
  tar -czf "$ARCHIVE" -C "$SITES_ROOT" -- "$USERNAME" \
    || die "备份失败，已中止删除（原目录未改动）"
  [[ -s "$ARCHIVE" ]] || die "备份文件为空，已中止删除"
  chmod 640 -- "$ARCHIVE"
  ok "备份完成: $(du -h -- "$ARCHIVE" | cut -f1)"
fi

# ---- 删除目录 ---------------------------------------------------------------
info "删除目录 $TARGET"
rm -rf --one-file-system -- "$TARGET"
[[ ! -e "$TARGET" ]] || die "删除失败，请手动检查 $TARGET"

# ---- 同步删除 File Browser 账号（软失败，不影响主流程）----------------------
if [[ -n "$FB_CONTAINER" ]] && command -v docker >/dev/null 2>&1; then
  if docker inspect -f '{{.State.Running}}' "$FB_CONTAINER" 2>/dev/null | grep -q true; then
    if docker exec "$FB_CONTAINER" filebrowser users rm "$USERNAME" >/dev/null 2>&1; then
      ok "已同步删除 File Browser 账号: $USERNAME"
    else
      warn "File Browser 中未找到该账号或删除失败（可忽略）"
    fi
  fi
fi

# ---- 可选：清理过期备份 -----------------------------------------------------
if [[ "$BACKUP_KEEP_DAYS" =~ ^[0-9]+$ ]] && [[ "$BACKUP_KEEP_DAYS" -gt 0 ]]; then
  info "清理 $BACKUP_KEEP_DAYS 天前的旧备份"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' \
       -mtime "+$BACKUP_KEEP_DAYS" -print -delete 2>/dev/null || true
fi

echo
ok "用户 '$USERNAME' 已删除"
[[ -n "$ARCHIVE" ]] && printf '    备份留存 : %s\n' "$ARCHIVE"
printf '    %sNginx 使用静态 root，无需重载；若配置了独立 server_name 请手动清理%s\n' "$C_DIM" "$C_RST"
exit 0
