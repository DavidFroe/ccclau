#!/usr/bin/env python3
"""
clau_api.py — Fernsteuerung für clau-Sessions (Default AUS).

Kleiner HTTP-Dienst (nur stdlib), gestartet über `clau --api`. Verwaltet drei
benannte Rollen (teamleiter, planer, tester). Jede Rolle läuft als
interaktive clau-Session in einer eigenen tmux-Session (clau-api-<rolle>), man
kann sie also auch direkt ansehen (tmux attach -t clau-api-teamleiter).

Zustand liegt unter ~/.config/clau/api/:
  rollen.json        Ordner, Session-ID, Modell pro Rolle
  status/<sid>.json  vom Hook geschrieben (arbeitet | wartet_auf_eingabe | fertig | beendet)
  logs/              Ausgaben von Headless-Turns

Unterbefehle:
  clau_api.py serve   HTTP-Dienst (Bind CLAU_API_BIND, Token CLAU_API_TOKEN)
  clau_api.py hook    Claude-Code-Hook: liest das Hook-JSON von stdin, schreibt status/<sid>.json

Endpunkte:
  GET  /status
  GET  /llm
  GET  /sessions/<rolle>/verlauf?n=50
  GET  /sessions/<rolle>/bildschirm
  POST /sessions/<rolle>/nachricht  {"text": "..."}
  POST /sessions/<rolle>/taste      {"taste": "esc|enter|ctrl-c|tab|shift-tab|up|down|left|right|y|n|1|2|3"}
  POST /sessions/<rolle>/start      {"ordner": "...", "auftrag": "...", "modell": "owl:120"}
  POST /sessions/<rolle>/stop
"""

import glob
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.environ.get("CLAU_API_STATE_DIR") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "clau", "api")
STATUS_DIR = os.path.join(STATE_DIR, "status")
LOG_DIR = os.path.join(STATE_DIR, "logs")
ROLES_FILE = os.path.join(STATE_DIR, "rollen.json")
CLAU_BIN = os.environ.get("CLAU_BIN") or os.path.join(HERE, "clau.sh")
CLAUDE_PROJECTS = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"), "projects")

ROLES = ("teamleiter", "planer", "tester")
# Teamleiter läuft im Team-Modus (verteilt an Ausführer), Planer und Tester
# als normale Einzel-Sessions. modell "" = was die .clau.conf im Ordner sagt.
ROLE_DEFAULTS = {
    "teamleiter": {"team": True, "modell": ""},
    "planer": {"team": False, "modell": ""},
    "tester": {"team": False, "modell": ""},
}

HOOK_STATE = {
    "UserPromptSubmit": "arbeitet",
    "PreToolUse": "arbeitet",
    "PostToolUse": "arbeitet",
    "Notification": "wartet_auf_eingabe",
    "Stop": "fertig",
    "SessionEnd": "beendet",
}
HOOK_EVENTS = ("UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd")

KEYS = {
    "esc": "Escape", "enter": "Enter", "ctrl-c": "C-c", "tab": "Tab", "shift-tab": "BTab",
    "up": "Up", "down": "Down", "left": "Left", "right": "Right",
    "y": "y", "n": "n", "1": "1", "2": "2", "3": "3",
}

_lock = threading.Lock()
_headless = {}  # rolle → Popen eines laufenden Headless-Turns


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def now_iso(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts if ts is not None else time.time()))


# ── Hook ──────────────────────────────────────────────────────────────────────

def hook_settings_json():
    """--settings-JSON für API-Sessions: Status-Hooks, nur für diese Session."""
    cmd = f"python3 {shlex.quote(os.path.abspath(__file__))} hook"
    return json.dumps({"hooks": {e: [{"hooks": [{"type": "command", "command": cmd}]}]
                                 for e in HOOK_EVENTS}})


def run_hook():
    # Darf nie scheitern oder blockieren -- Hooks laufen bei jedem Tool-Aufruf.
    try:
        d = json.load(sys.stdin)
        sid = str(d.get("session_id") or "")
        ev = str(d.get("hook_event_name") or "")
        state = HOOK_STATE.get(ev)
        if not sid or not state:
            return
        os.makedirs(STATUS_DIR, exist_ok=True)
        rec = {"zustand": state, "event": ev, "letzte_aktivitaet": now_iso(),
               "cwd": d.get("cwd") or "", "rolle": os.environ.get("CLAU_API_ROLE", "")}
        if ev == "Notification":
            rec["meldung"] = str(d.get("message") or "")[:300]
        if ev == "PreToolUse":
            rec["tool"] = str(d.get("tool_name") or "")
        tmp = os.path.join(STATUS_DIR, f".{sid}.{os.getpid()}.tmp")
        with open(tmp, "w") as f:
            json.dump(rec, f, ensure_ascii=False)
        os.replace(tmp, os.path.join(STATUS_DIR, f"{sid}.json"))
    except Exception:
        pass


# ── Rollen-Zustand ────────────────────────────────────────────────────────────

def load_roles():
    try:
        with open(ROLES_FILE) as f:
            data = json.load(f)
    except Exception:
        data = {}
    default_dir = os.environ.get("CLAU_API_ORDNER") or os.getcwd()
    for r in ROLES:
        cur = data.setdefault(r, {})
        for k, v in ROLE_DEFAULTS[r].items():
            cur.setdefault(k, v)
        cur.setdefault("ordner", os.environ.get(f"CLAU_API_ORDNER_{r.upper()}") or default_dir)
        cur.setdefault("session_id", "")
    return data


def save_roles(data):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = f"{ROLES_FILE}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, ROLES_FILE)


def tmux_name(rolle):
    return f"clau-api-{rolle}"


def tmux(*args, input_text=None):
    return subprocess.run(["tmux", *args], capture_output=True, text=True, input=input_text, timeout=10)


def tmux_alive(rolle):
    try:
        return tmux("has-session", "-t", "=" + tmux_name(rolle)).returncode == 0
    except Exception:
        return False


def session_file(sid):
    if not sid:
        return None
    hits = glob.glob(os.path.join(CLAUDE_PROJECTS, "*", f"{sid}.jsonl"))
    return max(hits, key=os.path.getmtime) if hits else None


def read_status(sid):
    if not sid:
        return {}
    try:
        with open(os.path.join(STATUS_DIR, f"{sid}.json")) as f:
            return json.load(f)
    except Exception:
        return {}


def headless_running(rolle):
    p = _headless.get(rolle)
    return p is not None and p.poll() is None


def role_state(rolle, info):
    sid = info.get("session_id", "")
    st = read_status(sid)
    alive = tmux_alive(rolle)
    if headless_running(rolle):
        zustand = "arbeitet"
    elif not alive:
        zustand = "beendet"
    else:
        # tmux läuft: Hook-Zustand, vor dem ersten Hook wartet die TUI auf Eingabe.
        zustand = st.get("zustand") or "wartet_auf_eingabe"
        if zustand == "beendet":
            zustand = "wartet_auf_eingabe"
    letzte = st.get("letzte_aktivitaet")
    if not letzte:
        sf = session_file(sid)
        letzte = now_iso(os.path.getmtime(sf)) if sf else None
    out = {"rolle": rolle, "zustand": zustand, "letzte_aktivitaet": letzte,
           "session_id": sid or None, "ordner": info.get("ordner"),
           "tmux": tmux_name(rolle) if alive else None,
           "modell": info.get("modell") or None, "team": bool(info.get("team"))}
    if st.get("meldung") and zustand == "wartet_auf_eingabe":
        out["meldung"] = st["meldung"]
    if st.get("tool") and zustand == "arbeitet":
        out["tool"] = st["tool"]
    return out


def llm_status():
    try:
        sys.path.insert(0, HERE)
        import llm_status_mcp
        return llm_status_mcp.get_status()
    except Exception as e:
        return {"frei": None, "fehler": f"llm_status nicht verfügbar: {e}"}


# ── Verlauf aus dem Session-JSONL ─────────────────────────────────────────────

def _short(s, n):
    s = str(s)
    return s if len(s) <= n else s[:n] + " …"


def history(sid, n):
    sf = session_file(sid)
    if not sf:
        return []
    out = []
    with open(sf, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") not in ("user", "assistant") or d.get("isMeta"):
                continue
            msg = d.get("message") or {}
            content = msg.get("content")
            parts = []
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                for b in content:
                    t = b.get("type")
                    if t == "text":
                        parts.append(b.get("text", ""))
                    elif t == "tool_use":
                        parts.append(f"[Tool {b.get('name')}] {_short(json.dumps(b.get('input', {}), ensure_ascii=False), 200)}")
                    elif t == "tool_result":
                        c = b.get("content")
                        if isinstance(c, list):
                            c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict))
                        parts.append(f"[Ergebnis] {_short(c or '', 300)}")
            text = "\n".join(p for p in parts if p).strip()
            if not text:
                continue
            out.append({"zeit": d.get("timestamp"), "von": msg.get("role") or d.get("type"), "text": text})
    return out[-n:]


# ── Sessions steuern ──────────────────────────────────────────────────────────

def clau_env(rolle, info, sid, resume, prompt_file=None):
    env = {
        "CLAU_API_ROLE": rolle,
        "CLAU_API_SESSION_ID": sid,
        "CLAU_API_RESUME": "1" if resume else "0",
        "CLAU_API_HOOK_SETTINGS": hook_settings_json(),
        "CLAU_UPDATE_CHECK": "0",   # kein Rückfrage-Prompt in der tmux-Session
        "CLAU_TEAM": "1" if info.get("team") else "0",
    }
    if prompt_file:
        env["CLAU_API_PROMPT_FILE"] = prompt_file
    return env


def clau_args(info):
    args = []
    if info.get("modell"):
        args += ["-m", info["modell"]]
    return args + ["--interaction", str(info.get("interaction", 0))]


def start_role(rolle, body):
    with _lock:
        roles = load_roles()
        info = roles[rolle]
        if tmux_alive(rolle):
            return 409, {"fehler": f"{rolle} läuft schon", "tmux": tmux_name(rolle)}
        if body.get("ordner"):
            info["ordner"] = os.path.abspath(os.path.expanduser(body["ordner"]))
        if "modell" in body:
            info["modell"] = body.get("modell") or ""
        ordner = info["ordner"]
        if not os.path.isdir(ordner):
            return 400, {"fehler": f"Ordner existiert nicht: {ordner}"}
        sid = info.get("session_id") or ""
        sf = session_file(sid)
        # Fortsetzen nur im selben Ordner -- claude --resume sucht im
        # Projekt-Bucket des aktuellen Verzeichnisses.
        resume = bool(sf) and os.path.basename(os.path.dirname(sf)) == re.sub(r"[^A-Za-z0-9]", "-", ordner)
        if not resume:
            sid = str(uuid.uuid4())
        info["session_id"] = sid
        save_roles(roles)

    prompt_file = None
    if body.get("auftrag"):
        os.makedirs(LOG_DIR, exist_ok=True)
        prompt_file = os.path.join(LOG_DIR, f"auftrag-{rolle}-{int(time.time())}.txt")
        with open(prompt_file, "w") as f:
            f.write(str(body["auftrag"]))
    env = clau_env(rolle, info, sid, resume, prompt_file)
    args = clau_args(info) + (["--resume", sid] if resume else ["--new"])
    cmd = "env " + " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items()) + " " + \
          " ".join(shlex.quote(a) for a in [CLAU_BIN, *args])
    r = tmux("new-session", "-d", "-s", tmux_name(rolle), "-x", "200", "-y", "50", "-c", ordner, cmd)
    if r.returncode != 0:
        return 500, {"fehler": f"tmux: {r.stderr.strip()}"}
    log(f"start {rolle}: {'resume' if resume else 'neu'} sid={sid} ordner={ordner}")
    return 200, {"rolle": rolle, "session_id": sid, "fortgesetzt": resume,
                 "ordner": ordner, "tmux": tmux_name(rolle)}


def stop_role(rolle):
    if not tmux_alive(rolle):
        return 200, {"rolle": rolle, "zustand": "beendet", "hinweis": "lief nicht"}
    name = tmux_name(rolle)
    # Erst sauber (Doppel-Strg-C beendet Claude Code inkl. SessionEnd-Hook),
    # nach 8 s hart.
    for _ in range(2):
        tmux("send-keys", "-t", name, "C-c")
        time.sleep(0.4)
    for _ in range(40):
        if not tmux_alive(rolle):
            break
        time.sleep(0.2)
    if tmux_alive(rolle):
        tmux("kill-session", "-t", name)
    return 200, {"rolle": rolle, "zustand": "beendet"}


def send_message(rolle, text):
    if tmux_alive(rolle):
        name = tmux_name(rolle)
        # Über einen Paste-Buffer mit Bracketed Paste: mehrzeiliger Text
        # landet als EIN Prompt statt bei jedem Zeilenumbruch abzuschicken.
        buf = f"clauapi-{rolle}"
        r = tmux("load-buffer", "-b", buf, "-", input_text=text)
        if r.returncode != 0:
            return 500, {"fehler": f"tmux load-buffer: {r.stderr.strip()}"}
        tmux("paste-buffer", "-p", "-d", "-b", buf, "-t", name)
        time.sleep(0.3)
        tmux("send-keys", "-t", name, "Enter")
        return 200, {"rolle": rolle, "modus": "tmux", "tmux": name}

    # Keine laufende Session: ein Headless-Turn in der Rollen-Session
    # (fortsetzen, wenn es sie schon gibt).
    with _lock:
        if headless_running(rolle):
            return 409, {"fehler": f"{rolle}: ein Headless-Turn läuft noch"}
        roles = load_roles()
        info = roles[rolle]
        sid = info.get("session_id") or ""
        resume = bool(session_file(sid))
        if not resume:
            sid = str(uuid.uuid4())
            info["session_id"] = sid
            save_roles(roles)
        os.makedirs(LOG_DIR, exist_ok=True)
        logf = os.path.join(LOG_DIR, f"headless-{rolle}-{int(time.time())}.log")
        env = dict(os.environ)
        env.update(clau_env(rolle, info, sid, resume))
        args = [CLAU_BIN, *clau_args(info), "--headless", "--dangerously-skip-permissions", "-p", text]
        with open(logf, "w") as lf:
            _headless[rolle] = subprocess.Popen(args, cwd=info["ordner"], env=env, stdout=lf,
                                                stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                                start_new_session=True)
    log(f"headless {rolle}: sid={sid} resume={resume}")
    return 202, {"rolle": rolle, "modus": "headless", "session_id": sid, "fortgesetzt": resume, "log": logf}


def send_key(rolle, taste):
    key = KEYS.get(str(taste).lower())
    if not key:
        return 400, {"fehler": f"unbekannte Taste: {taste}", "erlaubt": sorted(KEYS)}
    if not tmux_alive(rolle):
        return 409, {"fehler": f"{rolle} läuft nicht"}
    tmux("send-keys", "-t", tmux_name(rolle), key)
    return 200, {"rolle": rolle, "taste": taste}


# ── HTTP ──────────────────────────────────────────────────────────────────────

TOKEN = os.environ.get("CLAU_API_TOKEN", "")


class Handler(BaseHTTPRequestHandler):
    server_version = "clau-api/1.0"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False, indent=1).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        if not TOKEN:
            return True
        if self.headers.get("Authorization", "") == f"Bearer {TOKEN}":
            return True
        self._send(401, {"fehler": "Authorization: Bearer <CLAU_API_TOKEN> fehlt oder falsch"})
        return False

    def _route(self):
        u = urlparse(self.path)
        parts = [p for p in u.path.split("/") if p]
        return u, parts

    def _role(self, parts):
        if len(parts) >= 3 and parts[0] == "sessions" and parts[1] in ROLES:
            return parts[1], parts[2]
        return None, None

    def do_GET(self):
        if not self._auth():
            return
        u, parts = self._route()
        try:
            if parts == ["status"]:
                roles = load_roles()
                return self._send(200, {"rollen": [role_state(r, roles[r]) for r in ROLES],
                                        "llm": llm_status(), "zeit": now_iso()})
            if parts == ["llm"]:
                return self._send(200, llm_status())
            rolle, what = self._role(parts)
            if rolle and what == "verlauf":
                try:
                    n = max(1, min(500, int(parse_qs(u.query).get("n", ["50"])[0])))
                except ValueError:
                    n = 50
                sid = load_roles()[rolle].get("session_id")
                return self._send(200, {"rolle": rolle, "session_id": sid or None,
                                        "nachrichten": history(sid, n)})
            if rolle and what == "bildschirm":
                if not tmux_alive(rolle):
                    return self._send(409, {"fehler": f"{rolle} läuft nicht"})
                r = tmux("capture-pane", "-p", "-t", tmux_name(rolle))
                return self._send(200, {"rolle": rolle, "bildschirm": r.stdout})
            self._send(404, {"fehler": f"unbekannt: GET {u.path}"})
        except Exception as e:
            log(f"GET {u.path}: {e!r}")
            self._send(500, {"fehler": str(e)})

    def do_POST(self):
        if not self._auth():
            return
        u, parts = self._route()
        try:
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            try:
                body = json.loads(raw) if raw.strip() else {}
            except json.JSONDecodeError:
                return self._send(400, {"fehler": "Body ist kein JSON"})
            if not isinstance(body, dict):
                return self._send(400, {"fehler": "Body muss ein JSON-Objekt sein"})
            rolle, what = self._role(parts)
            if not rolle:
                return self._send(404, {"fehler": f"unbekannt: POST {u.path}"})
            if what == "nachricht":
                text = str(body.get("text") or "").strip()
                if not text:
                    return self._send(400, {"fehler": "text fehlt"})
                return self._send(*send_message(rolle, text))
            if what == "taste":
                return self._send(*send_key(rolle, body.get("taste", "")))
            if what == "start":
                return self._send(*start_role(rolle, body))
            if what == "stop":
                return self._send(*stop_role(rolle))
            self._send(404, {"fehler": f"unbekannt: POST {u.path}"})
        except Exception as e:
            log(f"POST {u.path}: {e!r}")
            self._send(500, {"fehler": str(e)})


def is_local(host):
    return host in ("127.0.0.1", "localhost", "::1")


def serve():
    bind = os.environ.get("CLAU_API_BIND", "127.0.0.1:7010")
    host, _, port = bind.rpartition(":")
    host = host.strip("[]") or "127.0.0.1"
    if not is_local(host) and not TOKEN:
        print(f"clau --api: Bind {bind} ist nicht lokal -- CLAU_API_TOKEN muss gesetzt sein.", file=sys.stderr)
        sys.exit(2)
    try:
        subprocess.run(["tmux", "-V"], capture_output=True, check=True)
    except Exception:
        print("clau --api: tmux fehlt (sudo apt install tmux).", file=sys.stderr)
        sys.exit(2)
    os.makedirs(STATUS_DIR, exist_ok=True)
    save_roles(load_roles())
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    print(f"clau-api läuft auf http://{bind}  (Token: {'an' if TOKEN else 'aus'}, Zustand: {STATE_DIR})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "hook":
        run_hook()
    elif cmd == "serve":
        serve()
    elif cmd == "hook-settings":
        print(hook_settings_json())
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
