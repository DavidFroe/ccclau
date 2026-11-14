#!/usr/bin/env python3
"""
gitea_mgr.py — eine gemeinsame Gitea-Instanz (https://github.com/go-gitea/gitea, MIT) für alle clau-Sessions.

Kein eigener Dienst und nichts vendored: das Release-Binary wird bei Bedarf geholt (SHA256-geprüft) und nur
lokal auf 127.0.0.1 betrieben (SQLite, keine Registrierung, kein SSH). Die Lebensdauer hängt an clau:

  * jede clau-Session meldet sich mit ihrer PID an ("Lease");
  * die erste startet einen kleinen Wächter, der Gitea startet und beendet;
  * der Wächter prüft alle 2 s, ob noch eine angemeldete PID lebt, und stoppt Gitea, sobald die letzte
    clau-Session weg ist (auch bei Absturz/kill -9). Alle weiteren Sessions hängen sich an dieselbe Instanz.

  gitea_mgr.py get | set enabled|port <wert>      globale Einstellung (~/.config/clau/gitea/settings.json)
  gitea_mgr.py install [version]                   Binary holen
  gitea_mgr.py up --pid P [--dir D --harness H]    Instanz sicherstellen, Lease anlegen, ggf. Repo für D (+ Fork für H)
  gitea_mgr.py down --pid P                        Lease lösen
  gitea_mgr.py status                              läuft? Port, Version, Leases, Repos
  gitea_mgr.py project --dir D [--harness H]       nur Repo/Fork für ein Verzeichnis anlegen (Instanz muss laufen)
  gitea_mgr.py admin                               Admin-Zugang (Benutzer/Passwort/Token-Datei)
  gitea_mgr.py watch                               intern: Wächter
Ausgabe von up/project: eine JSON-Zeile (url, repo, fork, clone_url …); Meldungen nach stderr.
"""
import fcntl
import hashlib
import json
import os
import platform
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

XDG_DATA = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
XDG_CONF = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
HOME_DIR = os.environ.get("CLAU_GITEA_HOME") or os.path.join(XDG_DATA, "clau", "gitea")
CONF_DIR = os.path.join(XDG_CONF, "clau", "gitea")
SETTINGS = os.path.join(CONF_DIR, "settings.json")
TOKEN_FILE = os.path.join(CONF_DIR, "token")
ADMIN_FILE = os.path.join(CONF_DIR, "admin.json")
REPOS_FILE = os.path.join(CONF_DIR, "repos.json")
BIN = os.path.join(HOME_DIR, "bin", "gitea")
RUN = os.path.join(HOME_DIR, "run")
LEASES = os.path.join(RUN, "leases")
STATE = os.path.join(RUN, "server.json")
LOCK = os.path.join(RUN, "lock")
APP_INI = os.path.join(HOME_DIR, "custom", "conf", "app.ini")
ADMIN_USER = "clau"
HARNESSES = ("claude", "nano", "opencode", "atomic", "pi")


def err(*a):
    print(*a, file=sys.stderr, flush=True)


def rj(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def wj(path, obj, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)
    if mode:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def settings():
    s = {"enabled": False, "port": 3300}
    s.update(rj(SETTINGS, {}) or {})
    if os.environ.get("CLAU_GITEA") in ("0", "1"):
        s["enabled"] = os.environ["CLAU_GITEA"] == "1"
    if os.environ.get("CLAU_GITEA_PORT", "").isdigit():
        s["port"] = int(os.environ["CLAU_GITEA_PORT"])
    return s


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


# ── Installation ─────────────────────────────────────────────────────────

def _get(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": "clau-gitea-setup"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def installed_version():
    if not os.path.exists(BIN):
        return ""
    try:
        out = subprocess.run([BIN, "--version"], capture_output=True, text=True, timeout=20).stdout
        m = re.search(r"version (\S+)", out)
        return m.group(1) if m else out.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def install(version=""):
    if os.path.exists(BIN) and not version:
        err(f"  gitea: bereits vorhanden ({installed_version()})")
        return True
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    if not arch:
        err(f"  WARN: Gitea-Release gibt es hier nicht für {platform.machine()}.")
        return False
    os.makedirs(os.path.dirname(BIN), exist_ok=True)
    free = shutil.disk_usage(os.path.dirname(BIN)).free // (1 << 20)
    if free < 300:
        err(f"  WARN: nur {free} MB frei unter {HOME_DIR} (nötig ~300 MB). Anderer Ort: CLAU_GITEA_HOME=/pfad")
        return False
    version = version or os.environ.get("CLAU_GITEA_VERSION", "")
    try:
        if not version:
            try:
                version = json.loads(_get("https://dl.gitea.com/gitea/version.json"))["latest"]["version"]
            except Exception:
                version = json.loads(_get("https://api.github.com/repos/go-gitea/gitea/releases/latest"))["tag_name"]
        version = version.lstrip("v")
    except Exception as e:  # noqa: BLE001
        err(f"  WARN: aktuelle Gitea-Version nicht ermittelbar ({e}). CLAU_GITEA_VERSION=1.x.y setzen.")
        return False
    name = f"gitea-{version}-linux-{arch}"
    bases = [f"https://dl.gitea.com/gitea/{version}/{name}",
             f"https://github.com/go-gitea/gitea/releases/download/v{version}/{name}"]
    err(f"  gitea {version}: lade Release (go-gitea/gitea, MIT; SHA256 wird geprüft) …")
    for base in bases:
        try:
            data = _get(base, timeout=300)
            want = _get(base + ".sha256", timeout=30).decode().split()[0].lower()
        except Exception as e:  # noqa: BLE001
            err(f"  … {base.split('/')[2]}: {e}")
            continue
        if hashlib.sha256(data).hexdigest() != want:
            err("  WARN: SHA256 stimmt nicht — abgebrochen.")
            return False
        tmp = BIN + ".part"
        with open(tmp, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o755)
        os.replace(tmp, BIN)
        err(f"  gitea {version} installiert: {BIN}")
        return True
    err("  WARN: Download fehlgeschlagen (Netz?).")
    return False


# ── Konfiguration, Start, Wächter ────────────────────────────────────────

def _gitea(*args, check=False, timeout=120):
    env = dict(os.environ, GITEA_WORK_DIR=HOME_DIR, GITEA_CUSTOM=os.path.join(HOME_DIR, "custom"))
    return subprocess.run([BIN, *args], capture_output=True, text=True, timeout=timeout, env=env, cwd=HOME_DIR)


def write_ini(port):
    keep = {}
    old = open(APP_INI, encoding="utf-8").read() if os.path.exists(APP_INI) else ""
    for k in ("SECRET_KEY", "INTERNAL_TOKEN", "JWT_SECRET"):
        m = re.search(rf"^{k}\s*=\s*(\S+)", old, re.M)
        if m:
            keep[k] = m.group(1)
    if "SECRET_KEY" not in keep:
        keep["SECRET_KEY"] = _gitea("generate", "secret", "SECRET_KEY").stdout.strip() or secrets.token_hex(32)
    if "INTERNAL_TOKEN" not in keep:
        keep["INTERNAL_TOKEN"] = _gitea("generate", "secret", "INTERNAL_TOKEN").stdout.strip()
    if "JWT_SECRET" not in keep:
        keep["JWT_SECRET"] = _gitea("generate", "secret", "JWT_SECRET").stdout.strip()
    data = os.path.join(HOME_DIR, "data")
    ini = f"""APP_NAME = clau Gitea
RUN_MODE = prod
WORK_PATH = {HOME_DIR}

[server]
HTTP_ADDR = 127.0.0.1
HTTP_PORT = {port}
DOMAIN = 127.0.0.1
ROOT_URL = http://127.0.0.1:{port}/
DISABLE_SSH = true
START_SSH_SERVER = false
OFFLINE_MODE = true
LFS_START_SERVER = false

[database]
DB_TYPE = sqlite3
PATH = {data}/gitea.db

[repository]
ROOT = {HOME_DIR}/repositories
DEFAULT_BRANCH = main

[security]
INSTALL_LOCK = true
SECRET_KEY = {keep['SECRET_KEY']}
INTERNAL_TOKEN = {keep['INTERNAL_TOKEN']}

[oauth2]
JWT_SECRET = {keep['JWT_SECRET']}

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
ENABLE_NOTIFY_MAIL = false

[mailer]
ENABLED = false

[log]
MODE = file
ROOT_PATH = {HOME_DIR}/log
LEVEL = warn

[other]
SHOW_FOOTER_VERSION = false

[picture]
DISABLE_GRAVATAR = true

[update_checker]
ENABLED = false
"""
    os.makedirs(os.path.dirname(APP_INI), exist_ok=True)
    with open(APP_INI, "w", encoding="utf-8") as f:
        f.write(ini)
    os.chmod(APP_INI, 0o600)


def health(port, timeout=2):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/healthz", timeout=timeout) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def server_state():
    st = rj(STATE, None)
    if st and alive(st.get("watcher")) and health(st.get("port", 0)):
        return st
    return None


def live_leases():
    os.makedirs(LEASES, exist_ok=True)
    out = []
    for n in os.listdir(LEASES):
        if n.isdigit() and alive(n):
            out.append(int(n))
        else:
            try:
                os.unlink(os.path.join(LEASES, n))
            except OSError:
                pass
    return out


def watch():
    """Wächter: startet Gitea, beendet es, wenn keine clau-Session mehr lebt."""
    s = settings()
    port = s["port"]
    os.makedirs(os.path.join(HOME_DIR, "log"), exist_ok=True)
    env = dict(os.environ, GITEA_WORK_DIR=HOME_DIR, GITEA_CUSTOM=os.path.join(HOME_DIR, "custom"))
    logf = open(os.path.join(HOME_DIR, "log", "gitea-stdout.log"), "a")
    proc = subprocess.Popen([BIN, "web", "--config", APP_INI, "--port", str(port)], env=env, cwd=HOME_DIR,
                            stdout=logf, stderr=logf, stdin=subprocess.DEVNULL)
    wj(STATE, {"watcher": os.getpid(), "pid": proc.pid, "port": port, "started": int(time.time())})
    idle_since = None
    stop = [False]
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__(0, True))
    try:
        while not stop[0] and proc.poll() is None:
            time.sleep(2)
            if live_leases():
                idle_since = None
            else:
                idle_since = idle_since or time.time()
                if time.time() - idle_since >= 4:
                    break
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        try:
            os.unlink(STATE)
        except OSError:
            pass


def ensure_admin():
    if os.path.exists(TOKEN_FILE) and rj(ADMIN_FILE):
        return True
    pw = secrets.token_urlsafe(18)
    m = _gitea("migrate", "--config", APP_INI, timeout=300)
    if m.returncode != 0:
        err("  gitea: Datenbank-Migration fehlgeschlagen: " + (m.stderr or m.stdout).strip()[-300:])
        return False
    r = _gitea("admin", "user", "create", "--config", APP_INI, "--admin", "--username", ADMIN_USER, "--password", pw,
               "--email", "clau@localhost", "--must-change-password=false")
    if r.returncode != 0 and "already exists" not in (r.stdout + r.stderr):
        err("  gitea: Admin-Benutzer nicht anlegbar: " + (r.stderr or r.stdout).strip()[-300:])
        return False
    if r.returncode == 0:
        wj(ADMIN_FILE, {"user": ADMIN_USER, "password": pw}, 0o600)
    t = _gitea("admin", "user", "generate-access-token", "--config", APP_INI, "--username", ADMIN_USER,
               "--token-name", f"clau-{int(time.time())}", "--scopes", "all", "--raw")
    tok = t.stdout.strip().splitlines()[-1].strip() if t.stdout.strip() else ""
    if t.returncode != 0 or not re.fullmatch(r"[0-9a-f]{20,}", tok):
        err("  gitea: Token nicht erzeugbar: " + (t.stderr or t.stdout).strip()[-300:])
        return False
    os.makedirs(CONF_DIR, exist_ok=True)
    with open(TOKEN_FILE, "w") as f:
        f.write(tok + "\n")
    os.chmod(TOKEN_FILE, 0o600)
    return True


def up(pid, d="", harness=""):
    s = settings()
    if not s["enabled"]:
        return None
    if not os.path.exists(BIN):
        err("  gitea: nicht installiert (Einstellungen → Gitea → Installieren, oder: gitea_mgr.py install).")
        return None
    os.makedirs(RUN, exist_ok=True)
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        live_leases()
        if pid:
            open(os.path.join(LEASES, str(pid)), "w").close()
        st = server_state()
        if not st:
            if not ensure_admin_ready(s["port"]):
                return None
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "watch"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            for _ in range(120):
                time.sleep(0.5)
                st = server_state()
                if st:
                    break
            if not st:
                err(f"  gitea: startet nicht (Port {s['port']} belegt? Log: {HOME_DIR}/log/). Port ändern: Einstellungen → Gitea.")
                return None
        fcntl.flock(lk, fcntl.LOCK_UN)
    info = {"url": f"http://127.0.0.1:{st['port']}", "port": st["port"], "token_file": TOKEN_FILE, "user": ADMIN_USER}
    if d:
        try:
            info.update(project(d, harness, st["port"]))
        except Exception as e:  # noqa: BLE001
            err(f"  gitea: Repository für {d}: {e}")
    return info


def ensure_admin_ready(port):
    write_ini(port)
    return ensure_admin()


# ── API ──────────────────────────────────────────────────────────────────

def token():
    try:
        return open(TOKEN_FILE).read().strip()
    except OSError:
        return ""


def api(method, path, body=None, port=None, ok404=False):
    port = port or (rj(STATE, {}) or {}).get("port") or settings()["port"]
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/v1{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"token {token()}", "Content-Type": "application/json",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            data = json.loads(raw)
        except ValueError:
            data = {"message": raw.decode("utf-8", "replace")[:300]}
        return e.code, data


def _repo_name(d):
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", os.path.basename(os.path.abspath(d)).strip()).strip("-.") or "projekt"
    return base[:80]


def project(d, harness="", port=None):
    """Repository für das Verzeichnis (einmalig), Fork für den Harness, git-Remotes. Gibt Infos zurück."""
    d = os.path.abspath(d)
    repos = rj(REPOS_FILE, {}) or {}
    ent = repos.get(d)
    if not ent:
        name = _repo_name(d)
        used = {e["name"] for p, e in repos.items() if p != d}
        if name in used:
            name = f"{name}-{hashlib.sha1(d.encode()).hexdigest()[:6]}"
        ent = {"name": name, "created": False, "forks": {}}
    name = ent["name"]
    code, _ = api("GET", f"/repos/{ADMIN_USER}/{name}", port=port)
    fresh = False
    if code == 404:
        code, data = api("POST", "/user/repos", {"name": name, "description": f"clau: {d}", "private": True,
                                                  "default_branch": "main", "auto_init": False, "issue_labels": "Default"}, port=port)
        if code not in (200, 201):
            raise RuntimeError(f"Repo anlegen: HTTP {code} {data.get('message', '')}")
        fresh = True
    ent["created"] = True
    port = port or (rj(STATE, {}) or {}).get("port") or settings()["port"]
    url = f"http://127.0.0.1:{port}"
    info = {"repo": f"{ADMIN_USER}/{name}", "repo_url": f"{url}/{ADMIN_USER}/{name}", "name": name}
    is_git = os.path.isdir(os.path.join(d, ".git"))
    if is_git:
        _git_remote(d, "gitea", f"{url}/{ADMIN_USER}/{name}.git", port)
        if fresh:
            r = subprocess.run(["git", "-C", d, "push", "gitea", "HEAD:refs/heads/main"], capture_output=True, text=True, timeout=300)
            info["erstes_push"] = "ok" if r.returncode == 0 else (r.stderr.strip()[-200:] or "fehlgeschlagen")
    if harness in HARNESSES:
        org = f"h-{harness}"
        code, _ = api("GET", f"/orgs/{org}", port=port)
        if code == 404:
            api("POST", "/orgs", {"username": org, "visibility": "private", "full_name": f"Harness {harness}"}, port=port)
        code, _ = api("GET", f"/repos/{org}/{name}", port=port)
        if code == 404:
            code, data = api("POST", f"/repos/{ADMIN_USER}/{name}/forks", {"organization": org, "name": name}, port=port)
            if code not in (200, 201, 202):
                info["fork_hinweis"] = f"Fork fehlgeschlagen (HTTP {code}: {data.get('message', '')[:120]}) — leeres Repo? Erst committen/pushen."
        code, _ = api("GET", f"/repos/{org}/{name}", port=port)
        if code == 200:
            ent["forks"][harness] = f"{org}/{name}"
            info["fork"] = f"{org}/{name}"
            if is_git:
                _git_remote(d, f"gitea-{harness}", f"{url}/{org}/{name}.git", port)
    info["forks"] = ent["forks"]
    repos[d] = ent
    wj(REPOS_FILE, repos)
    return info


def _git_remote(d, remote, url, port):
    def git(*a):
        return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True, timeout=30)
    cur = git("remote", "get-url", remote)
    if cur.returncode != 0:
        git("remote", "add", remote, url)
    elif cur.stdout.strip() != url:
        git("remote", "set-url", remote, url)
    helper = f"!f() {{ echo username={ADMIN_USER}; echo password=$(cat {TOKEN_FILE}); }}; f"
    git("config", f"credential.http://127.0.0.1:{port}.helper", helper)


# ── CLI ──────────────────────────────────────────────────────────────────

def main(argv):
    cmd = argv[0] if argv else ""
    opt = {}
    pos = []
    i = 1
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opt[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            pos.append(argv[i])
            i += 1
    if cmd == "get":
        print(json.dumps(settings()))
    elif cmd == "set" and len(pos) == 2:
        s = rj(SETTINGS, {}) or {}
        k, v = pos
        if k == "enabled":
            s["enabled"] = v in ("1", "true", "an", "on")
        elif k == "port" and v.isdigit() and 1024 <= int(v) <= 65535:
            s["port"] = int(v)
        else:
            err("Ungültig (enabled 0|1, port 1024-65535).")
            return 2
        wj(SETTINGS, s)
    elif cmd == "enabled":
        return 0 if settings()["enabled"] else 1
    elif cmd == "latest":
        try:
            print(json.loads(_get("https://dl.gitea.com/gitea/version.json"))["latest"]["version"])
        except Exception:  # noqa: BLE001
            return 1
    elif cmd == "install":
        return 0 if install(pos[0] if pos else "") else 1
    elif cmd == "up":
        info = up(opt.get("pid", ""), opt.get("dir", ""), opt.get("harness", ""))
        if info is None:
            return 3
        print(json.dumps(info, ensure_ascii=False))
    elif cmd == "down":
        try:
            os.unlink(os.path.join(LEASES, str(opt.get("pid", ""))))
        except OSError:
            pass
    elif cmd == "project":
        st = server_state()
        if not st:
            err("Gitea läuft nicht.")
            return 3
        print(json.dumps(project(opt.get("dir", os.getcwd()), opt.get("harness", ""), st["port"]), ensure_ascii=False))
    elif cmd == "status":
        st = server_state()
        s = settings()
        print(json.dumps({"enabled": s["enabled"], "port": s["port"], "installiert": installed_version(),
                          "laeuft": bool(st), "url": f"http://127.0.0.1:{st['port']}" if st else "",
                          "sessions": len(live_leases()) if os.path.isdir(LEASES) else 0,
                          "repos": len(rj(REPOS_FILE, {}) or {})}, ensure_ascii=False))
    elif cmd == "admin":
        a = rj(ADMIN_FILE, {}) or {}
        st = server_state()
        print(f"  URL      : {('http://127.0.0.1:%d' % st['port']) if st else '(läuft gerade nicht; Port ' + str(settings()['port']) + ')'}")
        print(f"  Benutzer : {a.get('user', ADMIN_USER)}")
        print(f"  Passwort : {a.get('password', '(unbekannt)')}")
        print(f"  API-Token: {TOKEN_FILE}")
    elif cmd == "watch":
        watch()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
