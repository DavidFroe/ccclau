#!/usr/bin/env python3
"""
llm_status_mcp.py — MCP-Server mit dem Tool "llm_status" (nur lesend).

Im Team-Modus fragt der Teamleiter vor jeder Verteilung ab, wie viele Slots
des Ausführer-Modells (Qwen3.8-Flash-Next, owl-121) gerade frei sind, und
zerlegt danach mehr oder weniger parallel. Quelle ist das /slots des
Flash-Tors (llama-server-Format: Liste mit id, n_ctx, is_processing).

Ist das Tor nicht erreichbar, kommt {"frei": null, "fehler": "..."} zurück --
der Teamleiter arbeitet dann so, als wäre genau EIN Slot frei. Kurzer Timeout,
damit die Session nie an dieser Abfrage hängt.

stdio-Transport, JSON-RPC 2.0. Nur stdlib. Logs nach stderr.
Direkt aufrufbar:  python3 llm_status_mcp.py --once   (JSON auf stdout)

Env:
  CLAU_TEAM_STATUS_URL      Default http://127.0.0.1:8293/slots
  CLAU_TEAM_EXEC_MODEL      Default 121 (nur für die Anzeige)
  CLAU_TEAM_MAX_AGENTS      Default 5
  CLAU_TEAM_STATUS_TIMEOUT  Sekunden, Default 3
"""

import json
import os
import sys
import urllib.error
import urllib.request

STATUS_URL = os.environ.get("CLAU_TEAM_STATUS_URL", "http://127.0.0.1:8293/slots")
EXEC_MODEL = os.environ.get("CLAU_TEAM_EXEC_MODEL", "121")
TIMEOUT = float(os.environ.get("CLAU_TEAM_STATUS_TIMEOUT", "3"))
try:
    MAX_AGENTS = max(1, int(os.environ.get("CLAU_TEAM_MAX_AGENTS", "5")))
except ValueError:
    MAX_AGENTS = 5

PROTOCOL_FALLBACK = "2024-11-05"

TOOL = {
    "name": "llm_status",
    "description": (
        "Zeigt, wie viele Slots des Ausführer-Modells (Subagenten mit "
        "model: sonnet) gerade frei sind, und wie viele Teilaufträge du "
        "deshalb parallel verteilen solltest (empfehlung_parallel). "
        "Vor JEDER Verteilung an Ausführer aufrufen. Bei fehler/frei=null so "
        "arbeiten, als wäre genau ein Slot frei."
    ),
    "inputSchema": {"type": "object", "properties": {}},
}


def log(msg):
    print(f"[llm_status_mcp] {msg}", file=sys.stderr, flush=True)


def recommend(frei):
    """Wie viele Teilaufträge parallel: 0-1 frei → 1 (sequenziell),
    2 frei → 2, ab 3 frei → bis CLAU_TEAM_MAX_AGENTS (überzählige warten
    im owl_proxy an der Slot-Sperre, ohne Fehler)."""
    if frei is None or frei <= 1:
        return 1
    if frei == 2:
        return min(2, MAX_AGENTS)
    return MAX_AGENTS


def get_status():
    try:
        req = urllib.request.Request(STATUS_URL, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return _error(f"HTTP {e.code} von {STATUS_URL}")
    except urllib.error.URLError as e:
        return _error(f"{STATUS_URL} nicht erreichbar: {e.reason}")
    except (TimeoutError, OSError) as e:
        return _error(f"{STATUS_URL}: {e}")
    except (json.JSONDecodeError, ValueError):
        return _error(f"{STATUS_URL} lieferte kein JSON")

    if isinstance(data, dict):
        data = data.get("slots") or []
    if not isinstance(data, list) or not data:
        # Flash-Tor ohne geladenes Modell (räumt nach Leerlauf ab) liefert
        # leer -- beim ersten Request lädt es neu, also nicht "voll".
        return {"modell": EXEC_MODEL, "slots": 0, "frei": None, "belegt": 0,
                "fehler": "keine Slot-Info (Modell evtl. gerade nicht geladen)",
                "empfehlung_parallel": 1}
    belegt = sum(1 for s in data if isinstance(s, dict) and s.get("is_processing"))
    slots = len(data)
    frei = slots - belegt
    ctx = next((s.get("n_ctx") for s in data if isinstance(s, dict) and s.get("n_ctx")), None)
    return {"modell": EXEC_MODEL, "slots": slots, "frei": frei, "belegt": belegt,
            "ctx_pro_slot": ctx, "empfehlung_parallel": recommend(frei)}


def _error(msg):
    return {"modell": EXEC_MODEL, "frei": None, "fehler": msg, "empfehlung_parallel": 1}


def handle(req):
    method = req.get("method")
    req_id = req.get("id")
    if req_id is None:
        return None

    def ok(result):
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    if method == "initialize":
        client_proto = (req.get("params") or {}).get("protocolVersion")
        return ok({
            "protocolVersion": client_proto or PROTOCOL_FALLBACK,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "llm_status", "version": "1.0.0"},
        })
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": [TOOL]})
    if method == "tools/call":
        params = req.get("params") or {}
        if params.get("name") != TOOL["name"]:
            return {"jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32602, "message": f"Unbekanntes Tool: {params.get('name')}"}}
        st = get_status()
        log(f"Status: {st}")
        return ok({"content": [{"type": "text", "text": json.dumps(st, ensure_ascii=False)}],
                   "isError": False})
    return {"jsonrpc": "2.0", "id": req_id,
            "error": {"code": -32601, "message": f"Unbekannte Methode: {method}"}}


def main():
    if "--once" in sys.argv:
        print(json.dumps(get_status(), ensure_ascii=False))
        return
    log(f"bereit → {STATUS_URL} (Modell {EXEC_MODEL}, max. {MAX_AGENTS} Agenten)")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            resp = handle(req)
        except Exception as e:
            log(f"Fehler in {req.get('method')}: {e!r}")
            resp = {"jsonrpc": "2.0", "id": req.get("id"),
                    "error": {"code": -32603, "message": str(e)}}
        if resp is not None:
            print(json.dumps(resp, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
