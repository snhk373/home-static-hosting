#!/usr/bin/env bash
# =============================================================================
# add_user.sh — 静态托管服务：创建站点用户
# 目标路径: /usr/local/bin/add_user.sh
# 依赖: coreutils(id/install/mkdir/chown/chmod) + 系统用户 www-data
# =============================================================================
set -Eeuo pipefail

PROG="$(basename "$0")"
ORIG_ARGS="$*"

# ---- 可配置项（均可用环境变量覆盖）----------------------------------------
SITES_ROOT="${SITES_ROOT:-/home/hosting/sites/u}"      # 用户站点根目录
PUBLIC_BASE="${PUBLIC_BASE:-http://your-frp-domain:PORT}"  # 公网入口
OWNER="${OWNER:-www-data}"                              # 属主用户
GROUP="${GROUP:-www-data}"                              # 属组
DIR_MODE="${DIR_MODE:-755}"
FILE_MODE="${FILE_MODE:-644}"

# ---- 颜色输出 ---------------------------------------------------------------
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
  -f, --file <路径>    使用自定义 index.html 覆盖默认页
  -t, --title <标题>   默认页的站点标题（默认 "用户名 的站点"）
  -h, --help           显示本帮助

用户名规则:
  3~32 位，首字符为小写字母或数字，仅允许 a-z 0-9 - _

示例:
  $PROG alice
  $PROG bob -t "Bob 的作品集"
  $PROG carol -f ./index.html
EOF
}

# ---- 参数解析 ---------------------------------------------------------------
USERNAME=""; CUSTOM_INDEX=""; TITLE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -f|--file)
      [[ $# -ge 2 ]] || die "选项 $1 缺少参数值"
      CUSTOM_INDEX="$2"; shift 2 ;;
    -t|--title)
      [[ $# -ge 2 ]] || die "选项 $1 缺少参数值"
      TITLE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) die "未知选项: $1（使用 -h 查看帮助）" ;;
    *)
      if [[ -z "$USERNAME" ]]; then USERNAME="$1"; else die "存在多余参数: $1"; fi
      shift ;;
  esac
done
[[ $# -eq 0 ]] || die "存在多余参数: $*"

# ---- 校验 -------------------------------------------------------------------
[[ -n "$USERNAME" ]] || { usage; echo; die "必须指定用户名"; }
[[ "$USERNAME" =~ ^[a-z0-9][a-z0-9_-]{2,31}$ ]] \
  || die "用户名不合法：'$USERNAME'（3~32 位，小写字母/数字开头，仅 a-z 0-9 - _）"

case "$USERNAME" in
  admin|root|www|www-data|ftp|mail|nginx|api|static|u|backup)
    die "用户名 '$USERNAME' 为保留字，请更换" ;;
esac

[[ $EUID -eq 0 ]] || die "需要 root 权限：sudo $PROG $ORIG_ARGS"
getent group "$GROUP" >/dev/null 2>&1 || die "系统组 '$GROUP' 不存在，请先执行 secure.sh 或安装 nginx"
id -u "$OWNER" >/dev/null 2>&1        || die "系统用户 '$OWNER' 不存在"

if [[ -n "$CUSTOM_INDEX" ]]; then
  [[ -f "$CUSTOM_INDEX" ]] || die "自定义首页不存在或不是普通文件: $CUSTOM_INDEX"
  [[ -r "$CUSTOM_INDEX" ]] || die "自定义首页不可读: $CUSTOM_INDEX"
fi
[[ -n "$TITLE" ]] || TITLE="${USERNAME} 的站点"

TARGET="$SITES_ROOT/$USERNAME"
[[ ! -e "$TARGET" ]] || die "用户已存在，目录被占用: $TARGET"

# ---- 建目录 -----------------------------------------------------------------
info "创建目录 $TARGET"
mkdir -p -- "$SITES_ROOT"
# 父目录保持 root:www-data 755，与 secure.sh 的策略一致
chown "root:$GROUP" -- "$SITES_ROOT" 2>/dev/null || warn "无法调整 $SITES_ROOT 属主，请检查权限"
chmod 755 -- "$SITES_ROOT"
install -d -m "$DIR_MODE" -o "$OWNER" -g "$GROUP" -- "$TARGET" \
  || die "目录创建失败，请检查 $SITES_ROOT 的权限与磁盘空间"

# ---- 写入默认 / 自定义首页 --------------------------------------------------
INDEX="$TARGET/index.html"
if [[ -n "$CUSTOM_INDEX" ]]; then
  install -m "$FILE_MODE" -o "$OWNER" -g "$GROUP" -- "$CUSTOM_INDEX" "$INDEX" \
    || die "写入自定义首页失败"
  ok "已写入自定义首页（来源: $CUSTOM_INDEX）"
else
  TMP="$(mktemp)"; trap 'rm -f -- "$TMP"' EXIT
  cat >"$TMP" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${TITLE}</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    background: #0f1115; color: #e6e9ef;
    font: 16px/1.7 -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
    padding: 24px;
  }
  .card {
    max-width: 620px; width: 100%; padding: 44px 40px; border-radius: 16px;
    background: #171a21; border: 1px solid #262b36;
    box-shadow: 0 18px 48px rgba(0,0,0,.45);
  }
  h1 { margin: 0 0 8px; font-size: 26px; letter-spacing: .5px; }
  .tag {
    display: inline-block; margin-bottom: 18px; padding: 3px 10px;
    font-size: 12px; border-radius: 999px;
    color: #3ecf8e; background: rgba(62,207,142,.12);
    border: 1px solid rgba(62,207,142,.3);
  }
  p { margin: 10px 0; color: #a9b1c3; }
  code {
    padding: 2px 6px; border-radius: 5px; font-size: 13px;
    background: #0f1115; border: 1px solid #262b36; color: #7fb2ff;
  }
  .foot { margin-top: 26px; padding-top: 18px; border-top: 1px dashed #262b36; font-size: 13px; color: #6b7385; }
</style>
</head>
<body>
  <main class="card">
    <span class="tag">站点已开通</span>
    <h1>${TITLE}</h1>
    <p>这是一个由 <strong>家庭微型静态站托管服务</strong> 托管的静态站点占位页。</p>
    <p>上传你的 <code>index.html</code> 到 <code>/home/hosting/sites/u/${USERNAME}/</code> 即可替换本页内容。</p>
    <p class="foot">Powered by frp + Nginx · ${USERNAME}</p>
  </main>
</body>
</html>
HTML
  install -m "$FILE_MODE" -o "$OWNER" -g "$GROUP" -- "$TMP" "$INDEX" \
    || die "写入默认首页失败"
  ok "已写入默认首页"
fi

# ---- 统一权限 ---------------------------------------------------------------
chown -R "$OWNER:$GROUP" -- "$TARGET"
find "$TARGET" -type d -exec chmod "$DIR_MODE" {} +
find "$TARGET" -type f -exec chmod "$FILE_MODE" {} +

URL="${PUBLIC_BASE%/}/u/${USERNAME}/"
echo
ok "用户创建成功"
printf '    用户名   : %s\n' "$USERNAME"
printf '    站点目录 : %s\n' "$TARGET"
printf '    属主权限 : %s:%s  dir=%s file=%s\n' "$OWNER" "$GROUP" "$DIR_MODE" "$FILE_MODE"
printf '    访问地址 : %s%s%s\n' "$C_GRN" "$URL" "$C_RST"
printf '    %s提示: Nginx 已配置 /u/%s/ → 该目录，无需重载%s\n' "$C_DIM" "$USERNAME" "$C_RST"
exit 0
