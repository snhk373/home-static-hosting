#!/usr/bin/env bash
# =============================================================================
# secure.sh — 静态托管服务：安全加固（幂等，可重复执行）
# 目标路径: /usr/local/bin/secure.sh
#
# 用法: secure.sh [--dry-run] [--apply-ufw]
#   --dry-run    只打印将要执行的动作，不落盘
#   --apply-ufw  额外尝试写入建议的 ufw 规则（默认只打印建议）
#
# 依赖: coreutils / nginx(www-data) / logrotate / fail2ban / ufw（后两者缺失则跳过）
# =============================================================================
set -Eeuo pipefail

PROG="$(basename "$0")"
SITES_ROOT="${SITES_ROOT:-/home/hosting/sites}"
USERS_ROOT="${SITES_ROOT}/u"
HOSTING_HOME="${HOSTING_HOME:-/home/hosting}"
WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
NGINX_PORT="${NGINX_PORT:-9060}"
FRP_PORT="${FRP_PORT:-36122}"

DRY_RUN=0
APPLY_UFW=0
for a in "$@"; do
  case "$a" in
    --dry-run)   DRY_RUN=1 ;;
    --apply-ufw) APPLY_UFW=1 ;;
    -h|--help)   sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知选项: %s\n' "$a" >&2; exit 64 ;;
  esac
done

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_BLU=$'\e[36m'; C_DIM=$'\e[2m';  C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_BLD=; C_RST=
fi
step() { printf '\n%s▶ %s%s\n' "$C_BLD$C_BLU" "$*" "$C_RST"; }
ok()   { printf '  %s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
skip() { printf '  %s[-]%s %s\n' "$C_DIM" "$C_RST" "$*"; }
warn() { printf '  %s[!]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '  %s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then printf '  %s[dry]%s %s\n' "$C_DIM" "$C_RST" "$*"; else "$@"; fi; }
trap 'printf "%s[x]%s 第 %s 行执行失败\n" "$C_RED" "$C_RST" "$LINENO" >&2' ERR

[[ $EUID -eq 0 ]] || die "需要 root 权限：sudo $PROG"
[[ $DRY_RUN -eq 1 ]] && warn "DRY-RUN 模式：不会修改任何文件"

# =============================================================================
step "1/6 确认 www-data 系统用户"
# =============================================================================
if getent passwd "$WEB_USER" >/dev/null 2>&1; then
  ok "$WEB_USER 已存在（uid=$(id -u "$WEB_USER")）"
else
  warn "$WEB_USER 不存在，创建无登录权限的系统用户"
  run useradd --system --no-create-home --shell /usr/sbin/nologin "$WEB_USER"
  ok "已创建 $WEB_USER"
fi
if ! getent passwd nginx >/dev/null 2>&1 && command -v nginx >/dev/null 2>&1; then
  warn "nginx 已安装但无 nginx 用户，检查 nginx.conf 的 user 指令是否为 $WEB_USER"
fi

# =============================================================================
step "2/6 目录属主与权限"
# =============================================================================
run mkdir -p -- "$SITES_ROOT" "$USERS_ROOT" "$HOSTING_HOME"
run chown "root:$WEB_GROUP" -- "$SITES_ROOT"
run chmod 755 -- "$SITES_ROOT"

# 用户站点根：root 拥有、www-data 可读可进入；不允许组写（防止越权建站）
run chown "root:$WEB_GROUP" -- "$USERS_ROOT"
run chmod 755 -- "$USERS_ROOT"
ok "$SITES_ROOT → root:$WEB_GROUP 755"

# 备份目录：仅 root 可读写
if [[ -d "$HOSTING_HOME/backup" ]] || [[ $DRY_RUN -eq 1 ]]; then
  run mkdir -p -- "$HOSTING_HOME/backup"
  run chown root:root -- "$HOSTING_HOME/backup"
  run chmod 750 -- "$HOSTING_HOME/backup"
  ok "$HOSTING_HOME/backup → root:root 750"
else
  skip "备份目录尚未创建（首次执行 del_user.sh --backup 时自动创建）"
fi

fix_tree() {
  local dir="$1" name; name="$(basename "$dir")"
  run chown -R "$WEB_USER:$WEB_GROUP" -- "$dir"
  run find "$dir" -type d -exec chmod 755 {} +
  run find "$dir" -type f -exec chmod 644 {} +
  # 清掉任何 setuid/setgid 位（静态站点不需要）
  run find "$dir" -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true
  ok "修正 $name 的属主与权限（dir 755 / file 644）"
}

if [[ -d "$USERS_ROOT" ]]; then
  while IFS= read -r -d '' d; do
    fix_tree "$d"
  done < <(find "$USERS_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)
fi

# 兜底：站点根下若出现其他人可写的文件，直接纠正
if [[ -d "$USERS_ROOT" && $DRY_RUN -eq 0 ]]; then
  cnt="$(find "$USERS_ROOT" -type f -perm -o+w 2>/dev/null | wc -l)"
  [[ "$cnt" -gt 0 ]] && warn "发现 $cnt 个 other-writable 文件，已在上一步统一改为 644" || true
fi

# =============================================================================
step "3/6 logrotate 配置"
# =============================================================================
LOGROTATE_HOSTING=/etc/logrotate.d/hosting
if [[ $DRY_RUN -eq 1 ]]; then
  printf '  %s[dry]%s 写入 %s\n' "$C_DIM" "$C_RST" "$LOGROTATE_HOSTING"
else
  {
    cat <<'EOF'
# 静态托管服务：自维护日志（watchdog / quota / backup / secure）
/var/log/hosting-*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 root adm
    dateext
    dateformat -%Y%m%d
}
EOF
    # 仅当发行版自带的 /etc/logrotate.d/nginx 不存在时才补 Nginx 日志规则，
    # 否则会与之产生 "duplicate log entry" 冲突（两者都匹配 /var/log/nginx/*.log）
    if [[ ! -f /etc/logrotate.d/nginx ]]; then
      cat <<'EOF'

# Nginx 日志（本机无发行版规则时兜底）
/var/log/nginx/access.log /var/log/nginx/error.log /var/log/nginx/hosting.access.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -s /run/nginx.pid ] && kill -USR1 "$(cat /run/nginx.pid)" 2>/dev/null || true
    endscript
    create 0640 www-data adm
}
EOF
    fi
  } >"$LOGROTATE_HOSTING"
  chmod 644 "$LOGROTATE_HOSTING"
  chown root:root "$LOGROTATE_HOSTING"
  ok "已写入 $LOGROTATE_HOSTING（hosting-*.log 每周轮转，保留 8 份）"
fi

if [[ -f /etc/logrotate.d/nginx ]]; then
  skip "检测到 /etc/logrotate.d/nginx，access.log 由其负责轮转，本次未写入 Nginx 规则（避免重复）"
else
  warn "未发现 /etc/logrotate.d/nginx，已在 hosting 配置中补上 access.log 的轮转规则"
fi

if command -v logrotate >/dev/null 2>&1; then
  run logrotate -d "$LOGROTATE_HOSTING" >/dev/null 2>&1 || warn "logrotate 配置自检有告警，请手动执行 logrotate -d $LOGROTATE_HOSTING 查看"
  ok "logrotate 已安装，配置自检完成"
else
  warn "logrotate 未安装：apt install logrotate"
fi

# =============================================================================
step "4/6 fail2ban（SSH 防爆破）"
# =============================================================================
if command -v fail2ban-client >/dev/null 2>&1; then
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '  %s[dry]%s 写入 /etc/fail2ban/jail.d/sshd-hosting.local\n' "$C_DIM" "$C_RST"
  else
    mkdir -p /etc/fail2ban/jail.d
    cat >/etc/fail2ban/jail.d/sshd-hosting.local <<'EOF'
# 静态托管服务器：SSH 防爆破（maxretry=3）
[DEFAULT]
# 局域网/跳板机可加入白名单，例如：ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24
ignoreip = 127.0.0.1/8 ::1
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 3
findtime = 600
bantime  = 3600
EOF
    chmod 644 /etc/fail2ban/jail.d/sshd-hosting.local
    ok "已写入 /etc/fail2ban/jail.d/sshd-hosting.local（maxretry=3, bantime=3600s）"
  fi

  if systemctl is-active --quiet fail2ban; then
    run systemctl reload fail2ban 2>/dev/null || run systemctl restart fail2ban
    ok "fail2ban 已重载"
    if [[ $DRY_RUN -eq 0 ]]; then
      printf '  %s当前封禁情况：%s\n' "$C_DIM" "$C_RST"
      fail2ban-client status sshd 2>/dev/null | sed 's/^/    /' || warn "sshd jail 尚未生效，请检查 /var/log/fail2ban.log"
    fi
  else
    warn "fail2ban 未运行：systemctl enable --now fail2ban"
  fi
else
  warn "fail2ban 未安装：apt install fail2ban && systemctl enable --now fail2ban"
fi

# SSH 基础加固提示（不自动改，避免锁死自己）
if [[ -f /etc/ssh/sshd_config ]]; then
  if grep -qiE '^\s*PermitRootLogin\s+yes' /etc/ssh/sshd_config; then
    warn "sshd 允许 root 直接登录，建议改为 prohibit-password 并仅用密钥"
  fi
  if ! grep -qiE '^\s*PasswordAuthentication\s+no' /etc/ssh/sshd_config; then
    warn "sshd 仍允许密码登录，建议确认密钥登录可用后改为 PasswordAuthentication no"
  fi
fi

# =============================================================================
step "5/6 ufw 状态与建议规则"
# =============================================================================
if command -v ufw >/dev/null 2>&1; then
  printf '  %s当前 ufw 状态：%s\n' "$C_DIM" "$C_RST"
  ufw status verbose 2>/dev/null | sed 's/^/    /' || warn "无法读取 ufw 状态（可能未启用）"

  echo
  printf '  %s建议规则（本机只需保留 22 与 frp 用的出站/入站，Nginx 9060 仅走 frp 本地回环）：%s\n' "$C_BLD" "$C_RST"
  cat <<EOF
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp                 # SSH（建议配合 fail2ban）
    ufw allow ${FRP_PORT}/tcp        # frp 服务端隧道端口（若 frp server 在本机）
    # Nginx ${NGINX_PORT} 与 API 9070、FileBrowser 9080 均只监听 127.0.0.1，
    # 无需对外开放；如需直连调试，请改用 SSH 端口转发：
    #   ssh -L 9070:127.0.0.1:9070 -L 9080:127.0.0.1:9080 root@<server>
    ufw enable
    ufw status numbered
EOF

  if [[ $APPLY_UFW -eq 1 ]]; then
    run ufw --force default deny incoming
    run ufw --force default allow outgoing
    run ufw allow 22/tcp
    run ufw allow "${FRP_PORT}/tcp"
    run ufw --force enable
    ok "已应用基础 ufw 规则"
  else
    skip "未自动修改防火墙（加 --apply-ufw 生效，或手动执行上面的命令）"
  fi
else
  warn "ufw 未安装：apt install ufw"
fi

# =============================================================================
step "6/6 校验摘要"
# =============================================================================
printf '  %-34s %s\n' "站点根目录" "$SITES_ROOT"
ls -ld "$SITES_ROOT" "$USERS_ROOT" 2>/dev/null | sed 's/^/    /' || true
echo
printf '  %-34s %s\n' "用户目录数量" "$(find "$USERS_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)"
printf '  %-34s %s\n' "global-writable 文件（应为 0）" \
  "$(find "$USERS_ROOT" -type f -perm -o+w 2>/dev/null | wc -l || true)"
printf '  %-34s %s\n' "启用的安全服务" \
  "$( { systemctl is-active fail2ban 2>/dev/null || echo inactive; } )"
echo
ok "安全加固完成"
[[ $DRY_RUN -eq 1 ]] && warn "以上为 DRY-RUN 预览，去掉 --dry-run 生效"
exit 0
