#!/usr/bin/env bash
# =============================================================================
# watchdog.sh — 静态托管服务：进程自愈 + 容量告警
# 目标路径: /usr/local/bin/watchdog.sh
#
# crontab（root）：
#   */5 * * * * . /etc/default/hosting-watchdog; export SC_KEY; /usr/local/bin/watchdog.sh >/dev/null 2>&1
#   注：脚本自身写 /var/log/hosting-watchdog.log，故 cron 侧丢弃 stdout，避免重复记录
#
# 依赖: systemctl / du / df / curl；告警依赖 Server 酱 SendKey（环境变量 SC_KEY）
# 环境变量（可在 /etc/default/hosting-watchdog 中定义，cron 源引入）：
#   SC_KEY         Server 酱 SendKey（必填，缺省则跳过推送，只写本地日志）
#   DISK_PATH      磁盘检查路径，默认 /home/hosting
#   MIN_FREE_GB    剩余空间下限，默认 5
#   SITES_ROOT     站点根目录，默认 /home/hosting/sites/u
#   USER_MAX_MB    单用户目录上限，默认 500
#   NGINX_UNIT     nginx 服务名，默认 nginx
#   FRPC_UNIT      frpc  服务名，默认 frpc
#   ALERT_INTERVAL 同类告警最小间隔秒数，默认 1800（防轰炸）
#   DRY_RUN=1      只打印不执行（调试用）
# =============================================================================
set -uo pipefail   # 注意：不用 -e，单个检查失败不应中断后续检查

PROG="$(basename "$0")"
LOG_FILE="${LOG_FILE:-/var/log/hosting-watchdog.log}"
STATE_DIR="${STATE_DIR:-/var/lib/hosting-watchdog}"

DISK_PATH="${DISK_PATH:-/home/hosting}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"
SITES_ROOT="${SITES_ROOT:-/home/hosting/sites/u}"
USER_MAX_MB="${USER_MAX_MB:-500}"
NGINX_UNIT="${NGINX_UNIT:-nginx}"
FRPC_UNIT="${FRPC_UNIT:-frpc}"
ALERT_INTERVAL="${ALERT_INTERVAL:-1800}"
SC_KEY="${SC_KEY:-}"

# ---- 日志 -------------------------------------------------------------------
# 脚本自己写日志文件（同时输出到 stdout），因此 cron 条目用 >/dev/null 丢弃输出，
# 避免同一行被写入两次。这样手动执行 / systemd timer 也能留下完整日志。
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p -- "$LOG_DIR" 2>/dev/null || true

log() {
  local level="$1"; shift
  local line
  line="$(printf '[%s] [%-5s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*")"
  printf '%s\n' "$line"
  if [[ -w "$LOG_FILE" ]] || [[ -w "$LOG_DIR" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}
say() { log INFO "$@"; }
warnlog() { log WARN "$@"; }

mkdir -p -- "$STATE_DIR" 2>/dev/null || true

# ---- 告警节流 ---------------------------------------------------------------
# 同一 key 在 ALERT_INTERVAL 内只推送一次，避免 cron 每 5 分钟刷屏
should_alert() {
  local key="$1" f="$STATE_DIR/$1.last" now last
  now="$(date +%s)"
  if [[ -f "$f" ]]; then
    last="$(cat "$f" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last < ALERT_INTERVAL )); then
      return 1
    fi
  fi
  echo "$now" >"$f" 2>/dev/null || true
  return 0
}

# ---- Server 酱推送 ----------------------------------------------------------
notify() {
  local title="$1" body="$2"
  if [[ -z "$SC_KEY" ]]; then
    warnlog "SC_KEY 未配置，跳过推送：$title"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    say "DRY_RUN 推送：$title | $body"
    return 0
  fi
  local code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
      "https://sctapi.ftqq.com/${SC_KEY}.send" \
      --data-urlencode "title=${title}" \
      --data-urlencode "desp=${body}" 2>&1)" || code="000"
  if [[ "$code" == "200" ]]; then
    say "推送成功：$title"
  else
    warnlog "推送失败（HTTP ${code}）：$title"
  fi
}

alert() {
  local key="$1" title="$2" body="$3"
  warnlog "$title — $(echo "$body" | tr '\n' ' ')"
  if should_alert "$key"; then
    notify "$title" "$body"
  else
    say "告警节流中（${ALERT_INTERVAL}s 内已推送过 $key），本次仅记录"
  fi
}

hostname_tag="$(hostname 2>/dev/null || echo vps)"

# =============================================================================
# 1. 进程自愈：frpc / nginx
# =============================================================================
check_service() {
  local unit="$1" label="$2"
  if ! systemctl list-unit-files "${unit}.service" 2>/dev/null | grep -q "$unit"; then
    warnlog "$label 服务单元 ${unit}.service 不存在，跳过检查"
    return 0
  fi

  local state
  state="$(systemctl is-active "$unit" 2>/dev/null)"
  if [[ "$state" == "active" ]]; then
    say "$label 运行正常 (active)"
    return 0
  fi

  warnlog "$label 状态异常：${state:-unknown}，尝试重启 ${unit}.service"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    say "DRY_RUN 跳过重启 $unit"
    return 0
  fi

  systemctl restart "$unit" >/dev/null 2>&1
  sleep 2
  state="$(systemctl is-active "$unit" 2>/dev/null)"
  if [[ "$state" == "active" ]]; then
    say "$label 重启成功，已恢复 active"
    alert "svc-${unit}-recovered" "[$hostname_tag] $label 已自动恢复" \
"服务 ${unit} 此前处于非 active 状态，watchdog 已自动重启成功。
时间：$(date '+%F %T')"
  else
    alert "svc-${unit}-down" "[$hostname_tag] $label 重启失败" \
"服务 ${unit} 处于 ${state:-unknown} 状态，自动重启未成功，请立即人工介入。
时间：$(date '+%F %T')
命令：systemctl status ${unit} --no-pager -l
日志：journalctl -u ${unit} -n 80 --no-pager"
  fi
}

check_service "$FRPC_UNIT" "frpc"
check_service "$NGINX_UNIT" "Nginx"

# =============================================================================
# 2. 磁盘剩余空间
# =============================================================================
if [[ -d "$DISK_PATH" ]]; then
  avail_bytes="$(df --output=avail -B1 "$DISK_PATH" 2>/dev/null | tail -1 | tr -d ' ')"
  if [[ "$avail_bytes" =~ ^[0-9]+$ ]]; then
    avail_gb=$(( avail_bytes / 1024 / 1024 / 1024 ))
    min_bytes=$(( MIN_FREE_GB * 1024 * 1024 * 1024 ))
    used_pct="$(df --output=pcent "$DISK_PATH" 2>/dev/null | tail -1 | tr -d ' %')"
    if (( avail_bytes < min_bytes )); then
      alert "disk-low" "[$hostname_tag] 磁盘剩余不足 ${MIN_FREE_GB}GB" \
"挂载点：${DISK_PATH}
剩余空间：${avail_gb}GB（阈值 ${MIN_FREE_GB}GB）
已用比例：${used_pct}%
时间：$(date '+%F %T')

排查建议：
  du -sh /home/hosting/sites/u/* | sort -h | tail -5
  journalctl --vacuum-size=200M
  /usr/local/bin/quota_check.sh ${USER_MAX_MB}"
    else
      say "磁盘正常：剩余 ${avail_gb}GB（已用 ${used_pct}%）"
    fi
  else
    warnlog "无法读取磁盘信息：$DISK_PATH"
  fi
else
  warnlog "磁盘检查路径不存在：$DISK_PATH"
fi

# =============================================================================
# 3. 单用户目录容量
# =============================================================================
if [[ -d "$SITES_ROOT" ]]; then
  max_kb=$(( USER_MAX_MB * 1024 ))
  oversized=""
  while IFS= read -r -d '' dir; do
    name="$(basename "$dir")"
    kb="$(du -sk -- "$dir" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
    if (( kb > max_kb )); then
      oversized+="  ${name}: $(awk -v k="$kb" 'BEGIN{printf "%.1fMB", k/1024}')"$'\n'
    fi
  done < <(find "$SITES_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  if [[ -n "$oversized" ]]; then
    alert "user-oversize" "[$hostname_tag] 存在超过 ${USER_MAX_MB}MB 的用户目录" \
"以下用户目录已超出单站点配额 ${USER_MAX_MB}MB：
${oversized}
时间：$(date '+%F %T')

处理建议：通知用户清理，或执行
  /usr/local/bin/del_user.sh --backup -y <用户名>"
  else
    say "用户目录容量正常（上限 ${USER_MAX_MB}MB）"
  fi
else
  warnlog "站点根目录不存在：$SITES_ROOT"
fi

say "本轮巡检结束"
exit 0
