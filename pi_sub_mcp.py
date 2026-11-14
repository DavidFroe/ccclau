#!/usr/bin/env python3
"""
pi_sub_mcp.py — MCP-Server: pi (https://github.com/earendil-works/pi) als Subagent für jede Engine mit MCP
(Claude Code und nano über clau). Unabhängig vom Team-Modus (dafür gibt es pi_team_mcp.py).

Der Hauptagent gibt abgegrenzte Teilaufgaben ab; jede läuft als eigener `pi -p`-Prozess im Projektordner,
mit kleinem Prompt (~1,7k Tokens statt ~36k bei Claude-Code-Subagenten) und dem in clau gewählten Modell.
Asynchron, damit mehrere Aufträge parallel laufen:
  pi_agent_starten   → Hintergrundauftrag, kommt sofort mit ID zurück
  pi_agent_abwarten  → blockiert bis fertig, liefert die Berichte
  pi_agent_status    → Momentaufnahme
Gleichzeitig laufen höchstens CLAU_PI_SUB_MAX Aufträge, weitere warten hier in der Schlange.

Env (setzt clau):
  CLAU_PI_BIN           pi-Binary
  PI_CODING_AGENT_DIR   pi-Konfigurationsordner (models.json mit owl-/Direkt-Providern)
  CLAU_PI_SUB_MODEL     "provider/modell" für pi --model  (Anzeige: CLAU_PI_SUB_LABEL)
  CLAU_PI_SUB_MAX       gleichzeitige Subagenten, Default 2
  CLAU_PI_SUB_TIMEOUT   Sekunden pro Auftrag, Default 1800
  CLAU_PI_SUB_LOG_DIR   Default ~/.cache/clau/pi-sub
"""
import json
import os
import subprocess
import sys
import threading
import time

PI_BIN = os.environ.get("CLAU_PI_BIN", "pi")
MODEL = os.environ.get("CLAU_PI_SUB_MODEL", "")
LABEL = os.environ.get("CLAU_PI_SUB_LABEL", MODEL)
MAX_PAR = max(1, int(os.environ.get("CLAU_PI_SUB_MAX", "2") or 2))
TIMEOUT = int(os.environ.get("CLAU_PI_SUB_TIMEOUT", "1800") or 1800)
LOG_DIR = os.environ.get("CLAU_PI_SUB_LOG_DIR",
                         os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "clau", "pi-sub"))
BERICHT_MAX = 6000
RW_TOOLS = "read,bash,edit,write,grep,find,ls"
RO_TOOLS = "read,bash,grep,find,ls"
SYS_ADD = ("Du bist ein Unteragent und erledigst genau den übergebenen Auftrag im Arbeitsordner. Keine Rückfragen: "
           "bei Unklarheit die vernünftigste Annahme treffen. Ändere nur Dateien, die zum Auftrag gehören. "
           "Beende mit einem knappen Bericht: was getan, geänderte Dateien, offene Punkte.")

TOOLS = [
    {"name": "pi_agent_starten",
     "description": (f"Gibt EINE abgegrenzte Teilaufgabe an einen Unteragenten ({LABEL or 'pi'}) ab und kommt sofort mit einer ID zurück. "
                     "Der Unteragent kennt deinen Verlauf nicht: Ziel, betroffene Dateien, Schnittstellen und Fertig-Kriterium "
                     f"vollständig in 'auftrag' schreiben. Bis zu {MAX_PAR} laufen gleichzeitig. Mehrere unabhängige Aufgaben: "
                     "alle nacheinander starten, dann EINMAL pi_agent_abwarten aufrufen."),
     "inputSchema": {"type": "object", "properties": {
         "auftrag": {"type": "string"},
         "nur_lesen": {"type": "boolean", "description": "true = darf nichts ändern (Recherche, Review, Tests lesen)"}},
         "required": ["auftrag"]}},
    {"name": "pi_agent_abwarten",
     "description": "Wartet, bis die angegebenen Aufträge (ohne ids: alle offenen) fertig sind, und liefert je Auftrag Status, Dauer, Bericht.",
     "inputSchema": {"type": "object", "properties": {"ids": {"type": "array", "items": {"type": "string"}}}}},
    {"name": "pi_agent_status", "description": "Momentaufnahme aller Unteragenten-Aufträge (wartet nicht).",
     "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}},
]


def log(msg):
    print(f"[pi_sub_mcp] {msg}", file=sys.stderr, flush=True)


_sem = threading.Semaphore(MAX_PAR)
_jobs = {}
_lock = threading.Lock()
_n = [0]


class Job:
    def __init__(self, jid, auftrag, nur_lesen):
        self.id, self.auftrag, self.nur_lesen = jid, auftrag, nur_lesen
        self.status, self.rc, self.t0, self.t1, self.out = "wartet", None, None, None, ""
        self.done = threading.Event()
        self.logname = f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{jid}.log"

    def info(self, bericht=False):
        d = {"id": self.id, "status": self.status, "modus": "nur lesen" if self.nur_lesen else "darf ändern"}
        if self.t0:
            d["dauer_s"] = round((self.t1 or time.time()) - self.t0)
        if bericht:
            t = self.out.strip()
            if len(t) > BERICHT_MAX:
                t = f"[… gekürzt, volles Log: {os.path.join(LOG_DIR, self.logname)}]\n" + t[-BERICHT_MAX:]
            d["bericht"] = t or "(keine Ausgabe)"
        return d

    def run(self):
        with _sem:
            self.status, self.t0 = "läuft", time.time()
            cmd = [PI_BIN, "-p", "--no-session", "-ne", "-ns", "-np"]
            if MODEL:
                cmd += ["--model", MODEL]
            cmd += ["--tools", RO_TOOLS if self.nur_lesen else RW_TOOLS, "--append-system-prompt", SYS_ADD, "--", self.auftrag]
            try:
                p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TIMEOUT,
                                   env=dict(os.environ, PI_OFFLINE="1", PI_TELEMETRY="0"), cwd=os.getcwd())
                self.rc = p.returncode
                self.out = p.stdout + (("\n[stderr]\n" + p.stderr[-2000:]) if p.returncode and p.stderr else "")
                self.status = "fertig" if p.returncode == 0 else "fehler"
            except subprocess.TimeoutExpired as e:
                o = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
                self.status, self.out = "timeout", o + f"\n[Abgebrochen nach {TIMEOUT}s]"
            except OSError as e:
                self.status, self.out = "fehler", f"pi konnte nicht gestartet werden ({PI_BIN}): {e}"
            self.t1 = time.time()
        try:
            os.makedirs(LOG_DIR, exist_ok=True)
            with open(os.path.join(LOG_DIR, self.logname), "w", encoding="utf-8") as f:
                f.write(f"# {self.id} {MODEL} rc={self.rc} status={self.status}\n## Auftrag\n{self.auftrag}\n\n## Ausgabe\n{self.out}\n")
        except OSError:
            pass
        self.done.set()


def starten(a):
    auftrag = (a.get("auftrag") or "").strip()
    if not auftrag:
        return {"fehler": "auftrag ist leer"}, True
    with _lock:
        _n[0] += 1
        job = Job(f"p{_n[0]}", auftrag, bool(a.get("nur_lesen")))
        _jobs[job.id] = job
    threading.Thread(target=job.run, daemon=True).start()
    time.sleep(0.05)
    r = job.info()
    r["hinweis"] = "Läuft im Hintergrund. Weitere unabhängige Aufgaben jetzt starten, danach einmal pi_agent_abwarten."
    return r, False


def abwarten(a):
    ids = a.get("ids") or []
    with _lock:
        jobs = [_jobs[i] for i in ids if i in _jobs] if ids else [j for j in _jobs.values() if not j.done.is_set()]
        unb = [i for i in ids if i not in _jobs]
    for j in jobs:
        j.done.wait()
    r = {"auftraege": [j.info(True) for j in jobs]}
    if unb:
        r["unbekannte_ids"] = unb
    if not jobs and not unb:
        r["hinweis"] = "keine offenen Aufträge"
    return r, False


def status(_a):
    with _lock:
        return {"max_parallel": MAX_PAR, "modell": LABEL, "auftraege": [j.info() for j in _jobs.values()]}, False


HANDLER = {"pi_agent_starten": starten, "pi_agent_abwarten": abwarten, "pi_agent_status": status}
_out = threading.Lock()


def send(o):
    with _out:
        print(json.dumps(o, ensure_ascii=False), flush=True)


def handle(req):
    m, rid = req.get("method"), req.get("id")
    if rid is None:
        return
    if m == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": (req.get("params") or {}).get("protocolVersion") or "2024-11-05",
            "capabilities": {"tools": {}}, "serverInfo": {"name": "pi_sub", "version": "1.0.0"}}})
    elif m == "ping":
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif m == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})
    elif m == "tools/call":
        p = req.get("params") or {}
        fn = HANDLER.get(p.get("name"))
        if not fn:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": f"Unbekanntes Tool: {p.get('name')}"}})
            return
        res, err = fn(p.get("arguments") or {})
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=1)}], "isError": err}})
    else:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unbekannte Methode: {m}"}})


def _safe(req):
    try:
        handle(req)
    except Exception as e:  # noqa: BLE001
        log(f"Fehler in {req.get('method')}: {e!r}")
        if req.get("id") is not None:
            send({"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32603, "message": str(e)}})


def main():
    log(f"bereit: pi={PI_BIN}, Modell {LABEL}, max {MAX_PAR} parallel, cwd={os.getcwd()}")
    for line in sys.stdin:
        line = line.strip()
        if line:
            try:
                req = json.loads(line)
            except json.JSONDecodeError:
                continue
            threading.Thread(target=_safe, args=(req,), daemon=True).start()


if __name__ == "__main__":
    main()
