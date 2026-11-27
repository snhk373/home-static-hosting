#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HomePage Hosting · 管理 API（重构版）
================================================================================
基于线上旧版（legacy/app-legacy.py，SQLite 版）重构，**接口与旧版完全兼容**：

    GET    /api/status                 系统状态（字段与旧版一致）
    GET    /api/users                  用户列表（字段与旧版一致）
    POST   /api/users                  建号  {username, custom_html}
    DELETE /api/users/<name>?backup=   删号（可选备份）
    GET    /api/users/<name>/disk      单用户实时磁盘占用
    GET    /api/settings               设置（定价表 / 公告）
    POST   /api/settings               更新设置（新增，旧版只读）
    GET    /admin                      管理面板
    GET    /api/health                 存活探测（新增，免鉴权）

相对旧版的内部改进（接口不变，实现全换）：
  1. ADMIN_TOKEN 无默认值：未配置时所有受保护接口 503 锁死（fail-closed），
     比对用 hmac.compare_digest；旧版默认口令 "change-me-now" 的裸奔路径已封死。
  2. 去掉 SQLite 双数据源：用户 = SITES_DIR 下的目录，磁盘/时间实时计算，
     永不失真；仅 created_at/note/quota/enabled 存 JSON 元数据（meta/<name>.json）。
  3. 首次启动自动迁移：读取旧 hosting.db 中的 users 表写入 meta，之后不再碰库。
  4. 用户名白名单 ^[a-z0-9][a-z0-9_-]{2,31}$ + 保留字 + resolve() 父目录校验，
     杜绝 ../ 穿越与符号链接（旧版 isidentifier() 放行大写且不防穿越）。
  5. 删号先 tar 备份、校验产物非空才删；建号/删号 flock 互斥。
  6. 面板改为独立 admin.html（与 app.py 同目录），不再内嵌 Python 字符串。
  7. 全部路径/URL/端口走环境变量；subprocess 一律参数数组，无 shell=True。

运行：ADMIN_TOKEN=<token> python3 app.py
依赖：pip3 install flask
"""

from __future__ import annotations

import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from functools import wraps
from pathlib import Path

try:
    from flask import Flask, jsonify, request, send_file
except ImportError:  # pragma: no cover
    sys.exit("缺少依赖：请执行  pip3 install flask")

# =============================================================================
# 配置（全部可用环境变量覆盖）
# =============================================================================
BASE_DIR = Path(os.environ.get("HOSTING_BASE", "/home/hosting"))
SITES_DIR = Path(os.environ.get("SITES_DIR", str(BASE_DIR / "sites" / "u")))
META_DIR = Path(os.environ.get("META_DIR", str(BASE_DIR / "meta")))
SETTINGS_PATH = Path(os.environ.get("SETTINGS_PATH", str(BASE_DIR / "settings.json")))
BACKUP_DIR = Path(os.environ.get("BACKUP_DIR", str(BASE_DIR / "backup")))
LEGACY_DB = Path(os.environ.get("LEGACY_DB", str(BASE_DIR / "hosting.db")))

ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")          # 必填，无默认值
FRP_URL = os.environ.get("FRP_URL", "http://your-frp-domain:PORT").rstrip("/")
NGINX_PORT = int(os.environ.get("NGINX_PORT", "9060"))
QUOTA_MB = int(os.environ.get("QUOTA_MB", "200"))        # 新用户默认额度（与旧库一致）
WEB_USER = os.environ.get("WEB_USER", "www-data")
WEB_GROUP = os.environ.get("WEB_GROUP", "www-data")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9070"))

USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{2,31}$")
RESERVED = {"admin", "root", "www", "www-data", "ftp", "mail", "nginx",
            "api", "static", "u", "backup", "meta"}

DEFAULT_SETTINGS = {
    "site_name": "HomePage Hosting",
    "price_basic": "5",
    "price_pro": "10",
    "price_max": "15",
    "notice": "欢迎使用",
}

app = Flask(__name__)
app.config["JSON_AS_ASCII"] = False
try:
    app.json.ensure_ascii = False
except Exception:  # pragma: no cover
    pass


# =============================================================================
# 小工具
# =============================================================================
def run(cmd: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    """执行外部命令，永不抛异常；显式 UTF-8，防 LANG=C 乱码。"""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace",
                              timeout=timeout, check=False)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def _lock():
    """建号/删号互斥（Linux flock，其他平台自动降级为无锁）。"""
    try:
        import fcntl
        fh = open("/tmp/.hosting-admin.lock", "w")
        fcntl.flock(fh, fcntl.LOCK_EX)
        return fh
    except Exception:
        return None


def _chown_chmod(path: str | Path, mode: int) -> None:
    try:
        shutil.chown(path, WEB_USER, WEB_GROUP)
    except (LookupError, PermissionError, OSError):
        pass
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def validate_username(name: str) -> str | None:
    if not name:
        return "用户名不能为空"
    if not USERNAME_RE.match(name):
        return "用户名需 3~32 位，字母或数字开头，仅允许小写 a-z 0-9 - _"
    if name in RESERVED:
        return f"用户名 '{name}' 为系统保留字"
    return None


def user_path(name: str) -> Path:
    """用户名 → 安全绝对路径；任何越界/符号链接一律拒绝。"""
    err = validate_username(name)
    if err:
        raise ValueError(err)
    target = (SITES_DIR / name).resolve()
    if target.parent != SITES_ROOT_SAFE():
        raise ValueError("非法路径")
    return target


def SITES_ROOT_SAFE() -> Path:
    return Path(SITES_DIR).resolve()


def respond_error(msg: str, code: int = 400):
    return jsonify({"error": msg}), code          # 保持旧版错误格式 {"error": ...}


# =============================================================================
# 元数据（轻量 JSON，取代旧版 SQLite 的 users 表）
# =============================================================================
def _meta_path(name: str) -> Path:
    return META_DIR / f"{name}.json"


def load_meta(name: str) -> dict:
    """读取用户元数据；没有则用目录时间合成（兼容手工建的目录）。"""
    mp = _meta_path(name)
    if mp.is_file():
        try:
            return json.loads(mp.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    d = SITES_DIR / name
    try:
        created = datetime.fromtimestamp(d.stat().st_ctime).isoformat(timespec="seconds")
    except OSError:
        created = datetime.now().isoformat(timespec="seconds")
    return {"username": name, "created_at": created, "note": "",
            "quota_mb": QUOTA_MB, "enabled": True}


def save_meta(name: str, meta: dict) -> None:
    META_DIR.mkdir(parents=True, exist_ok=True)
    mp = _meta_path(name)
    mp.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    _chown_chmod(mp, 0o640)


def migrate_legacy_db() -> None:
    """首次启动：若旧版 hosting.db 存在，把 users 表导入 meta，之后不再使用库。"""
    if not LEGACY_DB.is_file():
        return
    try:
        import sqlite3
        conn = sqlite3.connect(f"file:{LEGACY_DB}?mode=ro", uri=True)
        rows = conn.execute(
            "SELECT username, created_at, note, quota_mb, enabled FROM users"
        ).fetchall()
        conn.close()
    except Exception as exc:
        print(f"[!] 旧库读取失败（跳过迁移）: {exc}", file=sys.stderr)
        return
    migrated = 0
    for name, created, note, quota, enabled in rows:
        if validate_username(name) is None and not _meta_path(name).exists():
            save_meta(name, {"username": name, "created_at": created,
                             "note": note or "", "quota_mb": quota or QUOTA_MB,
                             "enabled": bool(enabled)})
            migrated += 1
    if migrated:
        print(f"[*] 已从 hosting.db 迁移 {migrated} 个用户到 {META_DIR}", file=sys.stderr)


# =============================================================================
# 站点扫描（文件系统 = 唯一数据源）
# =============================================================================
def dir_stats(path: Path) -> tuple[int, int]:
    """返回 (字节数, 最新文件 mtime)。纯 Python 遍历，规模小足够快。"""
    total, newest = 0, 0
    for dirpath, _dirnames, filenames in os.walk(path):
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            try:
                st = os.stat(fp)
                total += st.st_size
                if st.st_mtime > newest:
                    newest = st.st_mtime
            except OSError:
                continue
    return total, newest


def user_record(name: str) -> dict:
    meta = load_meta(name)
    d = SITES_DIR / name
    size, newest = dir_stats(d) if d.is_dir() else (0, 0)
    try:
        dir_mtime = int(d.stat().st_mtime)
    except OSError:
        dir_mtime = 0
    last_modified = max(newest, dir_mtime)
    return {
        "username": name,
        "created_at": meta.get("created_at", "-"),
        "last_modified": datetime.fromtimestamp(last_modified).isoformat(timespec="seconds")
                         if last_modified else "-",
        "disk_usage": size,
        "disk_mb": round(size / 1024 / 1024, 1),
        "quota_mb": meta.get("quota_mb", QUOTA_MB),
        "enabled": bool(meta.get("enabled", True)),
        "note": meta.get("note", ""),
        "url": f"{FRP_URL}/u/{name}/",
    }


def list_usernames() -> list[str]:
    if not SITES_DIR.is_dir():
        return []
    return sorted(p.name for p in SITES_DIR.iterdir()
                  if p.is_dir() and not p.is_symlink())


DEFAULT_INDEX_TPL = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{USERNAME}} 的主页</title>
<style>
body{font-family:'Segoe UI',sans-serif;background:#0f0f1a;color:#e0e0e0;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
.card{text-align:center;padding:2rem 3rem;background:#1a1a2e;border-radius:16px;box-shadow:0 0 40px rgba(100,100,255,.15)}
h1{font-size:2rem;margin-bottom:.5rem;background:linear-gradient(135deg,#7f5fff,#5b8cff);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
p{opacity:.7;margin-bottom:1.5rem}
a{color:#7f5fff;text-decoration:none;border:1px solid #7f5fff;padding:.5rem 1.2rem;border-radius:8px;transition:all .2s}
a:hover{background:#7f5fff;color:#fff}
</style>
</head>
<body>
<div class="card">
<h1>{{USERNAME}}</h1>
<p>这个页面由 HomePage Hosting 自动生成</p>
<p>替换 <code>index.html</code> 即可发布你的内容</p>
</div>
</body>
</html>"""


# =============================================================================
# 鉴权（fail-closed）
# =============================================================================
def check_token() -> bool:
    if not ADMIN_TOKEN:
        return False
    supplied = request.headers.get("X-Admin-Token", "")
    if not supplied:
        auth = request.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            supplied = auth[7:].strip()
    return hmac.compare_digest(supplied, ADMIN_TOKEN)


def require_token(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not check_token():
            if not ADMIN_TOKEN:
                return respond_error("服务端未配置 ADMIN_TOKEN，接口已锁定", 503)
            return respond_error("unauthorized", 401)   # 旧版格式
        return fn(*args, **kwargs)
    return wrapper


# =============================================================================
# 设置（JSON 文件，取代旧版 settings 表）
# =============================================================================
def load_settings() -> dict:
    try:
        stored = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        stored = {}
    merged = dict(DEFAULT_SETTINGS)
    merged.update({k: v for k, v in stored.items() if isinstance(v, str)})
    return merged


# =============================================================================
# API（与旧版同路径、同字段）
# =============================================================================
@app.get("/api/health")
def api_health():
    return jsonify({"ok": True, "ts": int(time.time())})


@app.route("/api/status")
@require_token
def api_status():
    users = list_usernames()
    total_disk = sum(user_record(n)["disk_usage"] for n in users)
    # 负载/内存：/proc 优先，读不到不炸（兼容非 Linux 测试环境）
    load = "-"
    try:
        load = Path("/proc/loadavg").read_text().split()[0]
    except OSError:
        if hasattr(os, "getloadavg"):
            try:
                load = f"{os.getloadavg()[0]:.2f}"
            except OSError:
                pass
    mem_used_percent = 0.0
    try:
        info = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, v = line.split(":", 1)
            info[k] = int(v.strip().split()[0])
        total_kb, free_kb = info.get("MemTotal", 0), info.get("MemFree", 0)
        if total_kb:
            mem_used_percent = round((total_kb - free_kb) / total_kb * 100, 1)
    except (OSError, ValueError):
        pass
    try:
        du = shutil.disk_usage(str(BASE_DIR))
        disk_free_gb = round(du.free / 1024**3, 2)
        disk_total_gb = round(du.total / 1024**3, 2)
    except OSError:
        disk_free_gb = disk_total_gb = 0.0
    uptime = run(["uptime", "-p"]).stdout.strip() or "-"
    return jsonify({
        "users": len(users),
        "total_disk_mb": round(total_disk / 1024 / 1024, 1),
        "loadavg": load,
        "mem_used_percent": mem_used_percent,
        "disk_free_gb": disk_free_gb,
        "disk_total_gb": disk_total_gb,
        "uptime": uptime,
        "frp_url": FRP_URL,
        "nginx_port": NGINX_PORT,
    })


@app.route("/api/users", methods=["GET"])
@require_token
def api_list_users():
    return jsonify([user_record(n) for n in list_usernames()])


@app.route("/api/users", methods=["POST"])
@require_token
def api_add_user():
    data = request.get_json(silent=True) or {}
    username = str(data.get("username", "")).strip().lower()
    custom_html = data.get("custom_html", "")

    err = validate_username(username)
    if err:
        return respond_error(err)
    try:
        path = user_path(username)
    except ValueError as exc:
        return respond_error(str(exc))
    if path.exists():
        return respond_error("用户已存在", 409)

    lock = _lock()
    try:
        SITES_DIR.mkdir(parents=True, exist_ok=True)
        _chown_chmod(SITES_DIR.parent, 0o755)
        _chown_chmod(SITES_DIR, 0o755)
        path.mkdir(mode=0o755, exist_ok=False)
        index = path / "index.html"
        content = custom_html if isinstance(custom_html, str) and custom_html.strip() \
            else DEFAULT_INDEX_TPL.replace("{{USERNAME}}", username)
        index.write_text(content, encoding="utf-8")
        _chown_chmod(index, 0o644)
        # 新用户元数据
        save_meta(username, {"username": username,
                             "created_at": datetime.now().isoformat(timespec="seconds"),
                             "note": "", "quota_mb": QUOTA_MB, "enabled": True})
        # 只修正新建目录本身，不再 chmod -R 全量递归
        _chown_chmod(path, 0o755)
    except PermissionError:
        return respond_error("权限不足：API 需以 root 运行才能创建目录", 500)
    except OSError as exc:
        return respond_error(f"创建失败: {exc}", 500)
    finally:
        if lock:
            lock.close()

    return jsonify({"ok": True, "url": f"{FRP_URL}/u/{username}/"})


@app.route("/api/users/<username>", methods=["DELETE"])
@require_token
def api_del_user(username: str):
    backup = request.args.get("backup", "false").lower() == "true"
    try:
        path = user_path(username)
    except ValueError as exc:
        return respond_error(str(exc))
    if path.is_symlink():
        return respond_error("拒绝操作：目标为符号链接")
    if not path.exists():
        return respond_error("用户不存在", 404)

    backup_file = None
    lock = _lock()
    try:
        if backup:
            BACKUP_DIR.mkdir(parents=True, exist_ok=True)
            os.chmod(BACKUP_DIR, 0o750)
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = BACKUP_DIR / f"{username}_{stamp}.tar.gz"
            r = run(["tar", "-czf", str(backup_file), "-C", str(SITES_DIR), username], timeout=300)
            if r.returncode != 0 or backup_file.stat().st_size == 0:
                return respond_error(f"备份失败，已中止删除: {r.stderr.strip()[:200]}", 500)
            os.chmod(backup_file, 0o640)
        shutil.rmtree(path)
    except OSError as exc:
        return respond_error(f"删除失败: {exc}", 500)
    finally:
        if lock:
            lock.close()

    meta_file = _meta_path(username)
    if meta_file.exists():
        try:
            meta_file.unlink()
        except OSError:
            pass

    return jsonify({"ok": True, "backup": backup,
                    "backup_file": str(backup_file) if backup_file else None})


@app.route("/api/users/<username>/disk", methods=["GET"])
@require_token
def api_user_disk(username: str):
    try:
        path = user_path(username)
    except ValueError as exc:
        return respond_error(str(exc))
    size, _ = dir_stats(path) if path.is_dir() else (0, 0)
    return jsonify({"username": username, "disk_bytes": size,
                    "disk_mb": round(size / 1024 / 1024, 2)})


@app.route("/api/settings", methods=["GET"])
@require_token
def api_get_settings():
    return jsonify(load_settings())


@app.route("/api/settings", methods=["POST"])
@require_token
def api_set_settings():
    payload = request.get_json(silent=True) or {}
    if not isinstance(payload, dict) or not payload:
        return respond_error("请求体需为非空 JSON 对象")
    current = load_settings()
    for k, v in payload.items():
        if k in DEFAULT_SETTINGS and isinstance(v, str):
            current[k] = v[:500]
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS_PATH.write_text(json.dumps(current, ensure_ascii=False, indent=2),
                             encoding="utf-8")
    _chown_chmod(SETTINGS_PATH, 0o640)
    return jsonify({"ok": True, "settings": current})


# =============================================================================
# 管理面板（独立 admin.html，不再内嵌）
# =============================================================================
def _find_panel() -> Path | None:
    here = Path(__file__).resolve().parent
    for cand in (here / "admin.html",
                 here.parent / "panel" / "admin.html",
                 Path("/opt/hosting-admin/admin.html")):
        if cand.is_file():
            return cand
    return None


@app.route("/admin")
def admin_panel():
    p = _find_panel()
    if p:
        resp = send_file(p, mimetype="text/html")
        resp.headers["Cache-Control"] = "no-store"
        return resp
    return "<h1>admin.html 未部署</h1><p>请把 admin.html 与 app.py 放在同一目录。</p>", 404


@app.errorhandler(404)
def _404(_):
    return jsonify({"error": "接口不存在"}), 404


@app.errorhandler(500)
def _500(exc):
    return jsonify({"error": f"服务端异常: {exc}"}), 500


# =============================================================================
# 启动
# =============================================================================
def main() -> None:
    if not ADMIN_TOKEN:
        print("[!] 警告：ADMIN_TOKEN 未设置，所有受保护接口已锁定(503)", file=sys.stderr)
    for d in (SITES_DIR, BACKUP_DIR, META_DIR):
        d.mkdir(parents=True, exist_ok=True)
    migrate_legacy_db()
    panel = _find_panel()
    print(f"""
    ╔════════════════════════════════════════════╗
    ║   HomePage Hosting Backend (refactored)    ║
    ║   http://{LISTEN_HOST}:{LISTEN_PORT}                  ║
    ║   Token: {'<未配置，接口已锁定>' if not ADMIN_TOKEN else '<来自环境变量>'}   ║
    ║   站点: {SITES_DIR}   ║
    ║   面板: {'已找到 ' + panel.name if panel else '未找到 admin.html'}               ║
    ╚════════════════════════════════════════════╝
    """, file=sys.stderr)
    try:
        from waitress import serve
        serve(app, host=LISTEN_HOST, port=LISTEN_PORT, threads=8, ident="hosting-admin")
    except ImportError:
        app.run(host=LISTEN_HOST, port=LISTEN_PORT, threaded=True, debug=False)


if __name__ == "__main__":
    main()
