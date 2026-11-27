#!/usr/bin/env bash
# =============================================================================
# restore_system.sh — 从 backup_system.sh 的产物恢复整系统（服务器上 root 运行）
#
# 用法：
#   sudo restore_system.sh <archive.tar.gz>            # 演练：只列内容，不改系统
#   sudo restore_system.sh <archive.tar.gz> --apply    # 实际恢复（先快照当前状态）
#
# 安全机制：
#   1. 校验 SHA256（同目录 .sha256 文件或手动输入）
#   2. --apply 前把 /home/hosting 与 /opt/hosting-admin 现状快照为回滚包
#   3. 恢复后重载 systemd 并提示需要手动确认的服务状态
# =============================================================================
set -euo pipefail

ARCHIVE="${1:-}"
APPLY="${2:-}"

[ "$(id -u)" -eq 0 ] || { echo "[!] 请以 root 运行"; exit 1; }
[ -n "${ARCHIVE}" ] && [ -f "${ARCHIVE}" ] || {
  echo "用法: sudo restore_system.sh <hosting-full-*.tar.gz> [--apply]"; exit 1; }

# ---- SHA256 校验 -------------------------------------------------------------
SUM_FILE="${ARCHIVE}.sha256"
if [ -f "${SUM_FILE}" ]; then
  echo "[*] 校验 SHA256 ..."
  (cd "$(dirname "${ARCHIVE}")" && sha256sum -c "$(basename "${SUM_FILE}")") \
    || { echo "[!] 校验失败，拒绝恢复"; exit 1; }
else
  echo "[!] 未找到 ${SUM_FILE}，跳过校验（建议手动核对）"
fi

# ---- 演练模式 ----------------------------------------------------------------
if [ "${APPLY}" != "--apply" ]; then
  echo "[*] 演练模式（不修改系统）。归档内容："
  tar -tzf "${ARCHIVE}" | sed 's/^/      /'
  echo ""
  echo "[*] 确认无误后执行:  sudo restore_system.sh ${ARCHIVE} --apply"
  exit 0
fi

# ---- 恢复前快照当前状态（回滚保险） ------------------------------------------
ROLLBACK="/home/hosting/system-backup/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p "$(dirname "${ROLLBACK}")"
echo "[*] 快照当前状态 → ${ROLLBACK}"
tar -czpf "${ROLLBACK}" \
    --exclude="/home/hosting/system-backup" \
    -C / \
    $( [ -d /home/hosting ] && echo home/hosting ) \
    $( [ -d /opt/hosting-admin ] && echo opt/hosting-admin ) 2>/dev/null || true

# ---- 实际恢复 ----------------------------------------------------------------
echo "[*] 解包到 / ..."
tar -xzpf "${ARCHIVE}" -C / --numeric-owner

echo "[*] 重载 systemd 并刷新服务状态 ..."
systemctl daemon-reload || true
if [ -f /etc/systemd/system/hosting-admin.service ]; then
  systemctl enable hosting-admin >/dev/null 2>&1 || true
  systemctl restart hosting-admin || echo "[!] hosting-admin 启动失败，查看: journalctl -u hosting-admin -n 50"
fi
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null \
  || echo "[!] nginx 未恢复，手动检查: nginx -t"

echo ""
echo "[✓] 恢复完成。回滚快照: ${ROLLBACK}"
echo "    请人工确认:"
echo "      systemctl status hosting-admin nginx"
echo "      curl -s http://127.0.0.1:9070/api/health"
echo "      curl -s -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:9060/u/任一用户/"
