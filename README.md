# 家庭微型静态站托管服务 · 服务端实现

一套可直接部署的多用户静态站点托管后端。基础环境：**Ubuntu 22.04**，已部署 **frp 客户端** 与 **Nginx（:9060）**，公网入口 `http://your-frp-domain:36122`（备用 IP 入口 `http://your-vps-ip:36122`）。

```
                       ┌──────────────── 公网 VPS ────────────────┐
  用户浏览器 ──HTTP──▶ │ frps :36122  ──tcp 隧道──▶ 家庭/机房主机  │
                       └──────────────────────────────────────────┘
                                                          │
                                        ┌─────────────────┴──────────────────┐
                                        │ Nginx :9060                        │
                                        │   /u/<用户名>/ → sites/u/<用户名>/  │
                                        ├────────────────────────────────────┤
                                        │ Flask Admin API  127.0.0.1:9070    │
                                        ├────────────────────────────────────┤
                                        │ FileBrowser      127.0.0.1:9080    │
                                        └────────────────────────────────────┘
```

## 一、目录结构与落点

| 仓库文件 | 服务器落点 | 说明 |
| --- | --- | --- |
| `bin/add_user.sh` | `/usr/local/bin/add_user.sh` | 建号：目录、属主、默认首页、回显 URL |
| `bin/del_user.sh` | `/usr/local/bin/del_user.sh` | 删号：`--backup` 先打包，强制确认 |
| `bin/list_users.sh` | `/usr/local/bin/list_users.sh` | 列表：容量 / 文件数 / 最后更新 / URL |
| `bin/quota_check.sh` | `/usr/local/bin/quota_check.sh` | 容量巡检，`exit 2` 表示有超额 |
| `bin/backup_system.sh` | `/usr/local/bin/backup_system.sh` | 整系统备份：站点+代码+配置+crontab+frpc，SHA256 校验，滚动保留 |
| `bin/restore_system.sh` | `/usr/local/bin/restore_system.sh` | 从备份恢复，默认演练模式，`--apply` 前自动快照回滚包 |
| `legacy/app-legacy.py` | — | 替换前的线上旧版实现存档（SQLite 版），仅作回滚参照，勿部署 |
| `api/app.py` | `/opt/hosting-admin/app.py` | 单文件 Flask 管理 API |
| `panel/admin.html` | `/opt/hosting-admin/admin.html` | 暗色管理面板（与 app.py 同目录，被 API 托管） |
| `api/hosting-admin.service` | `/etc/systemd/system/hosting-admin.service` | systemd 单元 |
| `api/hosting-admin.env.example` | `/etc/hosting-admin.env` | 环境变量（600 权限） |
| `watchdog.sh` | `/usr/local/bin/watchdog.sh` | 每 5 分钟自愈 + 告警 |
| `secure.sh` | `/usr/local/bin/secure.sh` | 权限收敛 / logrotate / fail2ban / ufw |
| `filebrowser/docker-compose.yml` | `/home/hosting/filebrowser/` | FileBrowser 容器（127.0.0.1:9080） |
| `filebrowser/filebrowser.json` | 同上 | 关闭注册、默认 scope `/u` |
| `filebrowser/create-fb-users.sh` | 同上 | 批量建号，输出凭据 CSV |
| `docs/` | — | 入驻协议、定价表、小红书/贴吧文案 |

## 二、依赖

```bash
# 系统包
apt update && apt install -y python3 python3-pip curl tar coreutils \
                          fail2ban ufw logrotate

# Python 依赖（可选 waitress 用于生产 WSGI，缺失时自动回退 Flask 内置服务器）
python3 -m pip install flask waitress

# 可选：FileBrowser 走 Docker
apt install -y docker.io docker-compose-plugin
```

> 说明：`app.py` 只用到 Flask；`waitress` 是推荐项（多线程、无警告、适合 systemd 托管）。
> 磁盘/时间等数据由 Python 直接遍历文件系统实时计算，外部命令仅用 `tar`（删除前备份），**不依赖数据库**。

## 三、部署步骤

### 1. 建目录、放脚本

```bash
sudo mkdir -p /home/hosting/sites/u /home/hosting/backup /opt/hosting-admin

sudo install -m 755 bin/add_user.sh   /usr/local/bin/add_user.sh
sudo install -m 755 bin/del_user.sh   /usr/local/bin/del_user.sh
sudo install -m 755 bin/list_users.sh /usr/local/bin/list_users.sh
sudo install -m 755 bin/quota_check.sh /usr/local/bin/quota_check.sh
sudo install -m 755 watchdog.sh       /usr/local/bin/watchdog.sh
sudo install -m 755 secure.sh         /usr/local/bin/secure.sh

sudo install -m 755 api/app.py      /opt/hosting-admin/app.py
sudo install -m 644 panel/admin.html  /opt/hosting-admin/admin.html
```

### 2. 安全基线（先跑一次）

```bash
sudo /usr/local/bin/secure.sh --dry-run   # 先看会改什么
sudo /usr/local/bin/secure.sh             # 正式执行
# 确认 ufw 建议规则无误后：
sudo /usr/local/bin/secure.sh --apply-ufw
```

### 3. 管理 API

```bash
# 生成强随机令牌
TOKEN=$(openssl rand -hex 24)

sudo install -m 600 api/hosting-admin.env.example /etc/hosting-admin.env
sudo sed -i "s#^ADMIN_TOKEN=.*#ADMIN_TOKEN=${TOKEN}#" /etc/hosting-admin.env

sudo install -m 644 api/hosting-admin.service /etc/systemd/system/hosting-admin.service
sudo systemctl daemon-reload
sudo systemctl enable --now hosting-admin
sudo systemctl status hosting-admin --no-pager
echo "面板令牌：$TOKEN"    # 妥善保存
```

> **从旧版升级**：首次启动时若检测到旧版 `/home/hosting/hosting.db`，会自动把用户表
> （创建时间/备注/额度/启用状态）迁移到 `meta/` 目录的 JSON 文件，旧库保留不动，确认无误后可删除。

### 4. 巡检与自愈

```bash
sudo tee /etc/default/hosting-watchdog >/dev/null <<'EOF'
SC_KEY=你的Server酱SendKey
MIN_FREE_GB=5
USER_MAX_MB=500
EOF
sudo chmod 600 /etc/default/hosting-watchdog

sudo crontab -e
```

```cron
# ---- 静态托管服务 ----
# watchdog.sh 自己写 /var/log/hosting-watchdog.log，故丢弃 stdout 避免重复记录
*/5 * * * * . /etc/default/hosting-watchdog; export SC_KEY MIN_FREE_GB USER_MAX_MB; /usr/local/bin/watchdog.sh >/dev/null 2>&1
30 3 * * *  /usr/local/bin/quota_check.sh 500 -q >> /var/log/hosting-quota.log 2>&1
```

### 5. 首次建号验证

```bash
sudo /usr/local/bin/add_user.sh demo -t "演示站点"
# → http://your-frp-domain:36122/u/demo/
curl -sS -o /dev/null -w '%{http_code}\n' http://your-frp-domain:36122/u/demo/
```

### 6. 打开管理面板

面板只监听 `127.0.0.1:9070`，**不要对公网开放**。用 SSH 本地转发访问：

```bash
ssh -L 9070:127.0.0.1:9070 user@your-vps-ip
# 浏览器打开 http://127.0.0.1:9070 ，粘贴上一步的令牌
```

## 四、关键配置项

### `app.py` 环境变量（写入 `/etc/hosting-admin.env`）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ADMIN_TOKEN` | 空 | **必填**。为空时所有受保护接口返回 503（fail-closed，无默认口令） |
| `HOSTING_BASE` | `/home/hosting` | 基础目录 |
| `SITES_DIR` | `/home/hosting/sites/u` | 用户站点根目录 |
| `META_DIR` | `/home/hosting/meta` | 用户元数据 JSON（created_at/note/quota/enabled） |
| `SETTINGS_PATH` | `/home/hosting/settings.json` | 定价表/公告等设置 |
| `BACKUP_DIR` | `/home/hosting/backup` | 删除前备份落点 |
| `LEGACY_DB` | `/home/hosting/hosting.db` | 旧版 SQLite；启动时自动迁移到 meta 后不再使用 |
| `FRP_URL` | `http://your-frp-domain:36122` | 拼接访问 URL 的前缀 |
| `NGINX_PORT` | `9060` | 仅用于面板展示 |
| `QUOTA_MB` | `200` | 新用户默认额度（与旧版数据库默认值一致） |
| `WEB_USER` / `WEB_GROUP` | `www-data` | 站点目录属主/属组 |
| `LISTEN_HOST` / `LISTEN_PORT` | `127.0.0.1` / `9070` | 监听地址，**不要改 0.0.0.0** |

### 脚本通用变量

四个用户脚本都支持 `SITES_ROOT`、`PUBLIC_BASE` 覆盖，默认值即上表；`del_user.sh` 另有 `BACKUP_DIR`、`BACKUP_KEEP_DAYS`、`FB_CONTAINER`。

### watchdog 变量

`SC_KEY`、`DISK_PATH`、`MIN_FREE_GB`、`SITES_ROOT`、`USER_MAX_MB`、`NGINX_UNIT`、`FRPC_UNIT`、`ALERT_INTERVAL`（同类告警最小间隔，默认 1800s，防轰炸）、`DRY_RUN=1`（只打印不执行）。

## 五、API 一览

与线上旧版**接口完全兼容**（同路径、同字段、同错误格式 `{"error": "..."}`），旧面板/脚本无需改动即可工作。

请求头统一携带 `X-Admin-Token: <ADMIN_TOKEN>`。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/health` | 存活探测（唯一免鉴权接口，新增） |
| `GET` | `/api/status` | 系统状态：用户数/总磁盘/负载/内存/磁盘/uptime/frp_url/nginx_port |
| `GET` | `/api/users` | 用户列表：容量、创建/更新时间、quota、enabled、note、URL |
| `POST` | `/api/users` | 创建用户，body: `{"username":"alice","custom_html":"可选自定义首页"}` |
| `DELETE` | `/api/users/<name>?backup=true` | 删除用户（删前 tar 备份并校验非空） |
| `GET` | `/api/users/<name>/disk` | 单用户实时磁盘占用 |
| `GET` | `/api/settings` | 定价表/公告（site_name、price_basic/pro/max、notice） |
| `POST` | `/api/settings` | 更新设置（新增，白名单键，值限字符串） |
| `GET` | `/admin` | 管理面板（panel/admin.html） |

```bash
TOKEN=你的令牌
BASE=http://127.0.0.1:9070

curl -sS -H "X-Admin-Token: $TOKEN" $BASE/api/status
curl -sS -H "X-Admin-Token: $TOKEN" $BASE/api/users
curl -sS -H "X-Admin-Token: $TOKEN" -H 'Content-Type: application/json' \
     -d '{"username":"alice"}' $BASE/api/users
curl -sS -X DELETE -H "X-Admin-Token: $TOKEN" "$BASE/api/users/alice?backup=true"
curl -sS -H "X-Admin-Token: $TOKEN" "$BASE/api/users/alice/disk"
curl -sS -X POST -H "X-Admin-Token: $TOKEN" -H 'Content-Type: application/json' \
     -d '{"notice":"春节暂停开放"}' $BASE/api/settings
```

**设计要点（相对旧版 SQLite 实现的改进）**

- **接口兼容、内部重写**：去掉了 SQLite 双数据源——用户 = `SITES_DIR` 下的目录，
  磁盘/最后更新时间实时从文件系统计算，FileBrowser 直传、手工删目录都不会再造成数据失真；
  仅 `created_at/note/quota_mb/enabled` 存轻量 JSON 元数据（`meta/<name>.json`）。
- **自动迁移**：启动时若检测到旧版 `hosting.db`，把 users 表一次性导入 meta，之后不再碰库。
- 鉴权 fail-closed：`ADMIN_TOKEN` 无默认值，未配置直接 503；比对用 `hmac.compare_digest`。
- 用户名白名单 `^[a-z0-9][a-z0-9_-]{2,31}$`（自动转小写）+ 保留字 + `Path.resolve()`
  父目录校验，杜绝 `../` 穿越与符号链接逃逸。
- 删除前 `tar -czf` 备份并校验产物非空才继续；建号/删号 `flock` 互斥。
- 全程 `subprocess` + 参数数组调用，不使用 `shell=True`；显式 UTF-8 解码。
- 面板独立为 `panel/admin.html`（与 app.py 同目录部署），令牌存 localStorage，不再内嵌 Python 字符串。

## 六、FileBrowser 集成

```bash
sudo mkdir -p /home/hosting/filebrowser/data
cd /home/hosting/filebrowser
sudo cp docker-compose.yml filebrowser.json create-fb-users.sh .
sudo chown -R 33:33 data          # 与容器内 www-data 对齐
sudo chmod 755 create-fb-users.sh
sudo docker compose up -d

# 为所有已有站点批量建号，凭据写入 /home/hosting/backup/fb-accounts.csv
sudo ./create-fb-users.sh --all
```

要点：

- 端口映射写死 `127.0.0.1:9080:80`，容器内看不到 `/home/hosting` 以外的任何路径。
- 每个账号的 `scope` 是 `/u/<用户名>`，用户登录后只能看到自己那一个目录，`perm.execute=false`、`perm.share=false`。
- 容器以 `user: "33:33"` 运行，上传的文件天然是 `www-data` 属主，Nginx 可直接读取，无需再 chown。
- `filebrowser.json` 里 `auth.signup=false`，禁止自助注册，账号只能由管理员脚本创建。

**后续开放公网上传**：再在 frp 客户端加一条 **tcp** 映射，把本地 `9080` 映射到服务端另一个端口（例如 `39080`），即得到 `http://your-frp-domain:PORT/`。届时需要：

1. 服务端 frps 配置放行该端口段，`ufw` 放行隧道端口；
2. 若走公网明文 HTTP，务必在 FileBrowser 侧限制上传大小并加限速（Nginx 反代更稳妥）；
3. 强烈建议改为 HTTPS 后再对外，否则账号密码为明文传输。

## 七、安全与运维要点

- **`/home/hosting/sites/` 归 `root:www-data` 755**：用户进程（www-data）无法在根下新建目录，只能在自己目录内写。
- **用户目录 755 / 文件 644**：Nginx 可读、他人不可写；`secure.sh` 会清理 setuid 位与 other-writable 文件。
- **三个端口的分工**：9060 对外（经 frp）、9070 仅本机、9080 仅本机。任何把 9070/9080 改成 `0.0.0.0` 的行为都等于把后台交出去。
- **fail2ban**：`jail.d/sshd-hosting.local` 中 `maxretry=3 / findtime=600 / bantime=3600`，可按需把跳板机加入 `ignoreip`。
- **logrotate**：`/etc/logrotate.d/hosting` 负责 `hosting-*.log` 与可选的 `hosting.access.log`，避免与发行版自带的 `/etc/logrotate.d/nginx` 重复轮转。
- **watchdog 告警节流**：同一告警 30 分钟内只推一次，状态落在 `/var/lib/hosting-watchdog/`，不会每 5 分钟刷微信。

## 八、备份与恢复

```bash
# 服务器上整系统备份（含 /home/hosting 全部站点数据、旧版 hosting.db、
# /opt/hosting-admin、nginx 配置、crontab、frpc 配置），滚动保留 7 份
sudo /usr/local/bin/backup_system.sh

# 恢复：先演练看内容，确认后再 --apply（apply 前自动快照当前状态）
sudo restore_system.sh /home/hosting/system-backup/hosting-full-*.tar.gz
sudo restore_system.sh /home/hosting/system-backup/hosting-full-*.tar.gz --apply
```

建议把备份再同步一份到服务器之外（rclone/SCP 拉回本地均可），避免单点。

## 九、验收清单

```bash
sudo /usr/local/bin/add_user.sh test1                 # 建号
sudo /usr/local/bin/list_users.sh                     # 出现在列表里
sudo /usr/local/bin/quota_check.sh 500 -v             # 容量正常
sudo /usr/local/bin/del_user.sh test1 --backup -y     # 备份后删除
sudo ls -lh /home/hosting/backup/                     # 有 tar.gz
curl -sS -H "X-Admin-Token: $TOKEN" http://127.0.0.1:9070/api/system | jq .data.services
sudo /usr/local/bin/watchdog.sh; tail -20 /var/log/hosting-watchdog.log
```
