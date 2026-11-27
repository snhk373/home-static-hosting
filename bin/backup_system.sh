#!/usr/bin/env bash
# =============================================================================
# backup_system.sh — 服务器端整系统备份（在托管服务器上以 root 运行）
#
# 打包范围：
#   /home/hosting          站点目录、旧版 hosting.db、filebrowser 数据、历史备份
#   /opt/hosting-admin     管理 API 代码与面板
#   /etc/hosting-admin.env 环境变量（含令牌，产物请妥善保管）
#   /etc/systemd/system/hosting-admin.service
#   /etc/nginx             nginx 全量配置（体积小，宁多勿漏）
#   /usr/local/bin/*.sh    add/del/list/quota/watchdog/secure 六个脚本
#   /etc/default/hosting-watchdog
#   /etc/logrotate.d/hosting  /etc/fail2ban/jail.d/（若存在）
#   root 的 crontab
#   frpc 配置（自动探测常见路径，可用 FRPC_CONF 覆盖）
#
# 用法：
#   sudo backup_system.sh                # 备份到 /home/hosting/system-backup/
#   BACKUP_DST=/mnt/nas sudo -E backup_system.sh
#   BACKUP_KEEP=14 sudo backup_system.sh # 保留 14 份
#
# 产物校验：tar -tzf 全量列名 + sha256 清单，失败即非零退出。
# =============================================================================
set -euo pipefail

BACKUP_DST="${BACKUP_DST:-/home/hosting/system-backup}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
FRPC_CONF="${FRPC_CONF:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DST}/hosting-full-${STAMP}.tar.gz"

[ "$(id -u)" -eq 0 ] || { echo "[!] 请以 root 运行"; exit 1; }
mkdir -p "${BACKUP_DST}"
chmod 700 "${BACKUP_DST}"

# ---- 组装文件清单（存在的才打包） -------------------------------------------
ITEMS=(
  /home/hosting
  /opt/hosting-admin
  /etc/hosting-admin.env
  /etc/systemd/system/hosting-admin.service
  /etc/nginx
  /usr/local/bin/add_user.sh
  /usr/local/bin/del_user.sh
  /usr/local/bin/list_users.sh
  /usr/local/bin/quota_check.sh
  /usr/local/bin/watchdog.sh
  /usr/local/bin/secure.sh
  /etc/default/hosting-watchdog
  /etc/logrotate.d/hosting
  /var/spool/cron/crontabs/root
)
# fail2ban 定制 jail
if compgen -G "/etc/fail2ban/jail.d/*hosting*" >/dev/null; then
  ITEMS+=(/etc/fail2ban/jail.d)
fi
# frpc 配置自动探测
if [ -z "${FRPC_CONF}" ]; then
  for cand in /etc/frp/frpc.toml /etc/frp/frpc.ini /usr/local/frp/frpc.toml \
              /usr/local/frp/frpc.ini /root/frp/frpc.toml /root/frp/frpc.ini; do
    [ -f "${cand}" ] && FRPC_CONF="${cand}" && break
  done
fi
[ -n "${FRPC_CONF}" ] && [ -f "${FRPC_CONF}" ] && ITEMS+=("${FRPC_CONF}")

EXISTING=()
for it in "${ITEMS[@]}"; do
  [ -e "${it}" ] && EXISTING+=("${it}")
done
if [ "${#EXISTING[@]}" -eq 0 ]; then
  echo "[!] 没有任何可备份对象，检查路径是否正确"; exit 1
fi

echo "[*] 备份对象："
printf '      %s\n' "${EXISTING[@]}"

# ---- 打包（排除备份目录自身，防止递归） -------------------------------------
echo "[*] 打包 → ${ARCHIVE}"
tar -czpf "${ARCHIVE}" \
    --exclude="/home/hosting/system-backup" \
    --exclude="/home/hosting/filebrowser/docker-compose.yml.bak" \
    -C / "${EXISTING[@]#/}"

# ---- 校验 -------------------------------------------------------------------
tar -tzf "${ARCHIVE}" >/dev/null || { echo "[!] 归档损坏，已删除"; rm -f "${ARCHIVE}"; exit 1; }
FILE_COUNT="$(tar -tzf "${ARCHIVE}" | wc -l)"
SHA256="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
echo "${SHA256}  $(basename "${ARCHIVE}")" > "${ARCHIVE}.sha256"
chmod 600 "${ARCHIVE}" "${ARCHIVE}.sha256"

# ---- 清理旧备份 --------------------------------------------------------------
ls -1t "${BACKUP_DST}"/hosting-full-*.tar.gz 2>/dev/null \
  | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f --

SIZE="$(du -h "${ARCHIVE}" | awk '{print $1}')"
echo ""
echo "[✓] 备份完成: ${ARCHIVE}"
echo "    大小: ${SIZE}   文件数: ${FILE_COUNT}"
echo "    SHA256: ${SHA256}"
echo "    恢复:  sudo restore_system.sh ${ARCHIVE}"
