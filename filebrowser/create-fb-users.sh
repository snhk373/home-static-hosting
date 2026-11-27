#!/usr/bin/env bash
# =============================================================================
# create-fb-users.sh — 批量为站点用户创建 File Browser 账号
# 目标路径: /home/hosting/filebrowser/create-fb-users.sh（与 docker-compose.yml 同目录）
#
# 用法:
#   ./create-fb-users.sh --all                # 为 /home/hosting/sites/u 下所有站点建号
#   ./create-fb-users.sh alice bob            # 只给指定用户建号
#   ./create-fb-users.sh --all --reset        # 已存在则重置密码
#   ./create-fb-users.sh alice --password 固定密码
#   ./create-fb-users.sh --list               # 查看现有账号
#
# 说明:
#   每个账号的 scope（家目录）锁定为 /u/<用户名>，容器内对应
#   /home/hosting/sites/u/<用户名>，无法越界访问其他用户目录。
#   账号密码写入 /home/hosting/backup/fb-accounts.csv（600 权限）。
# =============================================================================
set -Eeuo pipefail

PROG="$(basename "$0")"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONTAINER="${FB_CONTAINER:-filebrowser}"
SITES_ROOT="${SITES_ROOT:-/home/hosting/sites/u}"
CRED_FILE="${CRED_FILE:-/home/hosting/backup/fb-accounts.csv}"
PUBLIC_FB_URL="${PUBLIC_FB_URL:-http://your-frp-domain:39080/}"  # 后续 frp tcp 映射后的入口（占位）

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[36m'; C_DIM=$'\e[2m';  C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_BLD=; C_RST=
fi
ok()   { printf '  %s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
info() { printf '  %s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
warn() { printf '  %s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '  %s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- 参数 -------------------------------------------------------------------
ALL=0; RESET=0; LIST=0; FIXED_PW=""
declare -a TARGETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)      ALL=1; shift ;;
    --reset)    RESET=1; shift ;;
    --list)     LIST=1; shift ;;
    --password) [[ $# -ge 2 ]] || die "--password 缺少参数"; FIXED_PW="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "未知选项: $1" ;;
    *)          TARGETS+=("$1"); shift ;;
  esac
done

# ---- 环境检查 ---------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "未安装 docker"
docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
  || die "容器 $CONTAINER 未运行，请先在 $COMPOSE_DIR 执行：docker compose up -d"

fb() { docker exec "$CONTAINER" filebrowser "$@"; }

if [[ $LIST -eq 1 ]]; then
  info "现有 File Browser 账号："
  fb users ls 2>/dev/null | sed 's/^/    /'
  exit 0
fi

# ---- 数据集 -----------------------------------------------------------------
if [[ $ALL -eq 1 ]]; then
  [[ -d "$SITES_ROOT" ]] || die "站点根目录不存在: $SITES_ROOT"
  while IFS= read -r -d '' d; do
    TARGETS+=("$(basename "$d")")
  done < <(find "$SITES_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi
[[ ${#TARGETS[@]} -gt 0 ]] || { usage; echo; die "请指定用户名，或使用 --all"; }

gen_password() {
  if [[ -n "$FIXED_PW" ]]; then printf '%s' "$FIXED_PW"; return; fi
  # 16 位字母数字，去掉易混淆字符
  LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 16
}

mkdir -p -- "$(dirname "$CRED_FILE")"
chmod 700 -- "$(dirname "$CRED_FILE")" 2>/dev/null || true
[[ -f "$CRED_FILE" ]] || { echo "username,password,scope,created_at" >"$CRED_FILE"; chmod 600 "$CRED_FILE"; }

printf '\n%s批量为 File Browser 建号%s（容器: %s，站点根: %s）\n\n' \
  "$C_BLD" "$C_RST" "$CONTAINER" "$SITES_ROOT"

created=0; updated=0; skipped=0; failed=0
for name in "${TARGETS[@]}"; do
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]{2,31}$ ]]; then
    warn "跳过非法用户名: $name"; failed=$((failed+1)); continue
  fi
  if [[ ! -d "$SITES_ROOT/$name" ]]; then
    warn "站点目录不存在，跳过: $SITES_ROOT/$name"; failed=$((failed+1)); continue
  fi

  pw="$(gen_password)"
  scope="/u/$name"

  if fb users ls 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    if [[ $RESET -eq 1 ]]; then
      if fb users update "$name" --password "$pw" --scope "$scope" >/dev/null 2>&1; then
        ok "重置密码 $name  (scope=$scope)"
        echo "$name,$pw,$scope,$(date '+%F %T')" >>"$CRED_FILE"
        updated=$((updated+1))
      else
        warn "重置失败: $name"; failed=$((failed+1))
      fi
    else
      warn "账号已存在，跳过（--reset 可重置密码）: $name"
      skipped=$((skipped+1))
    fi
    continue
  fi

  if fb users add "$name" "$pw" \
        --scope "$scope" \
        --locale zh-cn \
        --perm.admin=false \
        --perm.create=true \
        --perm.modify=true \
        --perm.delete=true \
        --perm.execute=false \
        --perm.share=false \
        --perm.download=true >/dev/null 2>&1; then
    ok "创建账号 $name  密码 $pw  scope=$scope"
    echo "$name,$pw,$scope,$(date '+%F %T')" >>"$CRED_FILE"
    created=$((created+1))
  else
    warn "创建失败: $name"; failed=$((failed+1))
  fi
done

chmod 600 -- "$CRED_FILE" 2>/dev/null || true

echo
printf '  新建 %d 个 / 重置 %d 个 / 跳过 %d 个 / 失败 %d 个\n' "$created" "$updated" "$skipped" "$failed"
printf '  凭据文件: %s%s%s（600，请妥善保管并无条件删除历史副本）\n' "$C_DIM" "$CRED_FILE" "$C_RST"
printf '  用户入口: %s（frp tcp 映射 9080 后生效）\n' "$PUBLIC_FB_URL"
echo
printf '  %s提醒：建号后请在面板/工单中把密码单独发给用户，不要群发%s\n' "$C_YEL" "$C_RST"
exit 0
