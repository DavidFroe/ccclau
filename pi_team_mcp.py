#!/usr/bin/env python3
"""
pi_team_mcp.py — MCP-Server: Team-Subagenten als schlanke pi-Prozesse.

Im Team-Modus verteilt der Teamleiter (Claude Code) Teilaufträge nicht mehr
an Claude-Code-Subagenten (~36k Tokens System-Prompt + Tool-Schema pro
Anfrage), sondern an pi (https://pi.dev, ~1,7k Tokens). Jeder Auftrag ist ein
eigener `pi -p`-Prozess im Projektordner.

Claude Code führt MCP-Tools nur parallel aus, wenn sie als read-only markiert
sind -- ein Ausführer schreibt aber. Deshalb asynchron:
  auftrag_starten     → startet im Hintergrund, kommt sofort mit einer ID zurück
  auftraege_abwarten  → blockiert, bis die Aufträge fertig sind, liefert Berichte
  auftraege_status    → Momentaufnahme ohne zu warten
Gleichzeitig laufen höchstens CLAU_TEAM_PI_SLOTS je Modell, der Rest wartet hier.

Rollen (Prompt aus team/agents/<rolle>.md, Frontmatter wird ignoriert):
  ausfuehrer → CLAU_TEAM_EXEC_MODEL (121), Tools read,bash,edit,write,grep,find,ls
  tester     → CLAU_TEAM_LEAD_MODEL (120), Tools read,bash,grep,find,ls
  planer     → CLAU_TEAM_LEAD_MODEL (120), Tools read,write,grep,find,ls

stdio-Transport, JSON-RPC 2.0. Nur stdlib. Logs nach stderr, volle
Auftragsausgaben nach $CLAU_TEAM_LOG_DIR/<id>.log.

Env:
  CLAU_PI_BIN             pi-Binary (Default: pi im PATH)
  PI_CODING_AGENT_DIR     von clau erzeugtes pi-Konfig-Verzeichnis (owl-Provider)
  CLAU_TEAM_DIR           Ordner mit agents/*.md
  CLAU_TEAM_EXEC_MODEL    Default 121
  CLAU_TEAM_LEAD_MODEL    Default 120
  CLAU_TEAM_PI_SLOTS      z.B. "121=3,120=1" (Default: Ausführer 3, sonst 1)
  CLAU_TEAM_PI_TIMEOUT    Sekunden pro Auftrag, Default 1800
  CLAU_TEAM_LOG_DIR       Default ~/.cache/clau/team
"""

import json
import os
import subprocess
import sys
import threading
import time

PI_BIN = os.environ.get("CLAU_PI_BIN", "pi")
TEAM_DIR = os.environ.get("CLAU_TEAM_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "team"))
EXEC_MODEL = os.environ.get("CLAU_TEAM_EXEC_MODEL", "121")
LEAD_MODEL = os.environ.get("CLAU_TEAM_LEAD_MODEL", "120")
TIMEOUT = int(os.environ.get("CLAU_TEAM_PI_TIMEOUT", "1800") or 1800)
LOG_DIR = os.environ.get("CLAU_TEAM_LOG_DIR",
                         os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "clau", "team"))
BERICHT_MAX = 6000  # Zeichen pro Bericht an den Teamleiter (volle Ausgabe im Log)

PROTOCOL_FALLBACK = "2024-11-05"

ROLLEN = {
    "ausfuehrer": {"model": EXEC_MODEL, "tools": "read,bash,edit,write,grep,find,ls"},
    "tester": {"model": LEAD_MODEL, "tools": "read,bash,grep,find,ls"},
    "planer": {"model": LEAD_MODEL, "tools": "read,write,grep,find,ls"},
}

TOOLS = [
    {
        "name": "auftrag_starten",
        "description": (
            "Startet EINEN Teilauftrag für ein Teammitglied im Hintergrund und kommt sofort mit "
            "einer Auftrags-ID zurück. Mehrere Teilaufträge: nacheinander starten (jeder Aufruf "
            "dauert nur einen Moment), dann EINMAL auftraege_abwarten aufrufen -- sie laufen "
            "parallel, soweit Slots frei sind. Rollen: ausfuehrer (setzt um, eigener "
            "Dateibereich), tester (baut/testet, ändert nichts), planer (schreibt PLAN.md)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "rolle": {"type": "string", "enum": list(ROLLEN)},
                "auftrag": {"type": "string", "description": (
                    "Vollständiger Auftrag: Ziel, Dateibereich (nur diese Dateien ändern), "
                    "Schnittstellen, Fertig-Kriterium. Das Teammitglied kennt deinen Verlauf nicht.")},
            },
            "required": ["rolle", "auftrag"],
        },
    },
    {
        "name": "auftraege_abwarten",
        "description": (
            "Wartet, bis die angegebenen Aufträge (ohne ids: alle noch offenen) fertig sind, und "
            "liefert je Auftrag Status, Dauer und den Bericht des Teammitglieds."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"ids": {"type": "array", "items": {"type": "string"}}},
        },
    },
    {
        "name": "auftraege_status",
        "description": "Momentaufnahme aller Aufträge dieser Session (wartet nicht).",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
]


def log(msg):
    print(f"[pi_team_mcp] {msg}", file=sys.stderr, flush=True)


def _parse_slots(spec):
    out = {}
    for part in (spec or "").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                out[k.strip()] = max(1, int(v))
            except ValueError:
                pass
    return out


_slot_spec = _parse_slots(os.environ.get("CLAU_TEAM_PI_SLOTS", ""))
_sems = {}
_sems_lock = threading.Lock()


def _sem(model):
    with _sems_lock:
        if model not in _sems:
            n = _slot_spec.get(model, 3 if model == EXEC_MODEL else 1)
            _sems[model] = threading.Semaphore(n)
        return _sems[model]


def _rollen_prompt(rolle):
    try:
        text = open(os.path.join(TEAM_DIR, "agents", f"{rolle}.md"), encoding="utf-8").read()
    except OSError:
        return ""
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) == 3:
            text = parts[2]
    return text.strip()


class Job:
    def __init__(self, jid, rolle, auftrag):
        self.id, self.rolle, self.auftrag = jid, rolle, auftrag
        self.model = ROLLEN[rolle]["model"]
        self.status = "wartet"          # wartet → läuft → fertig | fehler | timeout
        self.rc = None
        self.t_start = None
        self.t_end = None
        self.ausgabe = ""
        self.done = threading.Event()
        # Eindeutig über Sessions hinweg (IDs a1, a2 … beginnen je Server neu)
        self.logname = f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{jid}.log"

    def info(self, mit_bericht=False):
        d = {"id": self.id, "rolle": self.rolle, "modell": self.model, "status": self.status}
        if self.t_start:
            d["dauer_s"] = round((self.t_end or time.time()) - self.t_start)
        if mit_bericht:
            text = self.ausgabe.strip()
            if len(text) > BERICHT_MAX:
                text = "[… gekürzt, volles Log: " + self._logfile() + "]\n" + text[-BERICHT_MAX:]
            d["bericht"] = text or "(keine Ausgabe)"
        return d

    def _logfile(self):
        return os.path.join(LOG_DIR, self.logname)

    def run(self):
        sem = _sem(self.model)
        with sem:
            self.status = "läuft"
            self.t_start = time.time()
            cmd = [PI_BIN, "-p", "--no-session", "-ne", "-ns", "-np",
                   "--model", f"owl/{self.model}",
                   "--tools", ROLLEN[self.rolle]["tools"]]
            prompt = _rollen_prompt(self.rolle)
            if prompt:
                cmd += ["--append-system-prompt", prompt]
            cmd += ["--", self.auftrag]
            env = dict(os.environ, PI_OFFLINE="1")
            log(f"{self.id} ({self.rolle}, owl/{self.model}) startet")
            try:
                # stdin schließen: pi liest sonst im -p-Modus von stdin und hängt
                p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True,
                                   text=True, timeout=TIMEOUT, env=env, cwd=os.getcwd())
                self.rc = p.returncode
                self.ausgabe = p.stdout + (("\n[stderr]\n" + p.stderr[-2000:]) if p.returncode and p.stderr else "")
                self.status = "fertig" if p.returncode == 0 else "fehler"
            except subprocess.TimeoutExpired as e:
                self.status = "timeout"
                out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
                self.ausgabe = out + f"\n[Abgebrochen nach {TIMEOUT}s]"
            except OSError as e:
                self.status = "fehler"
                self.ausgabe = f"pi konnte nicht gestartet werden ({PI_BIN}): {e}"
            self.t_end = time.time()
        try:
            os.makedirs(LOG_DIR, exist_ok=True)
            with open(self._logfile(), "w", encoding="utf-8") as f:
                f.write(f"# {self.id} {self.rolle} owl/{self.model} rc={self.rc} status={self.status}\n")
                f.write(f"## Auftrag\n{self.auftrag}\n\n## Ausgabe\n{self.ausgabe}\n")
        except OSError:
            pass
        log(f"{self.id} {self.status} nach {round(self.t_end - self.t_start)}s")
        self.done.set()


_jobs = {}
_jobs_lock = threading.Lock()
_counter = [0]


def starten(args):
    rolle = (args.get("rolle") or "").strip()
    auftrag = (args.get("auftrag") or "").strip()
    if rolle not in ROLLEN:
        return {"fehler": f"Unbekannte Rolle '{rolle}', erlaubt: {', '.join(ROLLEN)}"}, True
    if not auftrag:
        return {"fehler": "auftrag ist leer"}, True
    with _jobs_lock:
        _counter[0] += 1
        jid = f"a{_counter[0]}"
        job = Job(jid, rolle, auftrag)
        _jobs[jid] = job
    threading.Thread(target=job.run, daemon=True).start()
    time.sleep(0.05)
    res = job.info()
    res["hinweis"] = ("Läuft im Hintergrund. Weitere unabhängige Teilaufträge JETZT ebenfalls starten; "
                      "erst wenn alle dieser Runde gestartet sind, einmal auftraege_abwarten aufrufen.")
    return res, False


def abwarten(args):
    ids = args.get("ids") or []
    with _jobs_lock:
        if ids:
            jobs = [_jobs[i] for i in ids if i in _jobs]
            unbekannt = [i for i in ids if i not in _jobs]
        else:
            jobs = [j for j in _jobs.values() if not j.done.is_set()]
            unbekannt = []
    for j in jobs:
        j.done.wait()
    res = {"auftraege": [j.info(mit_bericht=True) for j in jobs]}
    if unbekannt:
        res["unbekannte_ids"] = unbekannt
    if not jobs and not unbekannt:
        res["hinweis"] = "keine offenen Aufträge"
    return res, False


def status(_args):
    with _jobs_lock:
        return {"auftraege": [j.info() for j in _jobs.values()]}, False


HANDLER = {"auftrag_starten": starten, "auftraege_abwarten": abwarten, "auftraege_status": status}

_out_lock = threading.Lock()


def send(obj):
    with _out_lock:
        print(json.dumps(obj, ensure_ascii=False), flush=True)


def handle(req):
    method = req.get("method")
    req_id = req.get("id")
    if req_id is None:
        return

    def ok(result):
        send({"jsonrpc": "2.0", "id": req_id, "result": result})

    if method == "initialize":
        client_proto = (req.get("params") or {}).get("protocolVersion")
        ok({"protocolVersion": client_proto or PROTOCOL_FALLBACK,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "pi_team", "version": "1.0.0"}})
    elif method == "ping":
        ok({})
    elif method == "tools/list":
        ok({"tools": TOOLS})
    elif method == "tools/call":
        params = req.get("params") or {}
        fn = HANDLER.get(params.get("name"))
        if not fn:
            send({"jsonrpc": "2.0", "id": req_id,
                  "error": {"code": -32602, "message": f"Unbekanntes Tool: {params.get('name')}"}})
            return
        result, is_err = fn(params.get("arguments") or {})
        ok({"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=1)}],
            "isError": is_err})
    else:
        send({"jsonrpc": "2.0", "id": req_id,
              "error": {"code": -32601, "message": f"Unbekannte Methode: {method}"}})


def _safe_handle(req):
    try:
        handle(req)
    except Exception as e:
        log(f"Fehler in {req.get('method')}: {e!r}")
        if req.get("id") is not None:
            send({"jsonrpc": "2.0", "id": req.get("id"),
                  "error": {"code": -32603, "message": str(e)}})


def main():
    log(f"bereit: pi={PI_BIN}, Ausführer owl/{EXEC_MODEL}, Leitung owl/{LEAD_MODEL}, cwd={os.getcwd()}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Jede Anfrage in eigenem Thread: auftraege_abwarten blockiert lange,
        # ping/status sollen trotzdem beantwortet werden.
        threading.Thread(target=_safe_handle, args=(req,), daemon=True).start()


if __name__ == "__main__":
    main()
