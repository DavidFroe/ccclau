#!/usr/bin/env python3
"""clau_delegate_mcp.py — MCP-Server (stdio): Aufgaben an einen konfigurierbaren clau/Claude-Code-Lauf delegieren.
Dünner Aufsatz auf clau_delegate.py. Registrieren: claude mcp add clau-delegate -- python3 /pfad/clau_delegate_mcp.py"""
import json
import os
import subprocess
import sys

DEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clau_delegate.py")
STR = {"type": "string"}
LST = {"type": "array", "items": STR}
TOOLS = [
    ("delegate", "Schwere Aufgabe an einen eigenen Claude-Code-Lauf abgeben (keine Rückfragen). Gibt job_id zurück.",
     {"aufgabe": STR, "preset": STR, "modell": {"type": "string", "description": "z.B. owl:137 (Coder), owl:136 (Planer)"},
      "ordner": STR, "isolation": {"type": "string", "enum": ["worktree", "direkt"]},
      "tools": LST, "tools_verboten": LST, "skills": LST, "kontext": STR, "kontext_dateien": LST,
      "systemprompt_zusatz": STR, "rechte": {"type": "string", "enum": ["bypass", "normal"]},
      "mcp_server": {"type": "array", "items": {"type": "object"}}, "limits": {"type": "object"}}, ["aufgabe"]),
    ("job_zwischenstand", "Zwischenstand eines Jobs (letzte Schritte, FORTSCHRITT.md).", {"job_id": STR}, ["job_id"]),
    ("job_ergebnis", "Endergebnis samt Diff, oder 'läuft noch'.", {"job_id": STR, "warte_s": {"type": "integer"}}, ["job_id"]),
    ("job_weiter", "Zusatzinfo an einen beendeten Job (setzt die Session fort).", {"job_id": STR, "text": STR}, ["job_id", "text"]),
    ("job_stop", "Job abbrechen.", {"job_id": STR}, ["job_id"]),
    ("job_liste", "Alle Jobs.", {}, []),
    ("fortschritt", "Kurzstand einer laufenden clau-Session (was passiert gerade, letzte größere Schritte, Zähler) – braucht das Denkprotokoll "
     "(CLAU_TRACE=1 oder trace_setzen). Mit job_id für einen Delegate-Job, sonst port oder der einzige laufende Proxy.",
     {"job_id": STR, "port": {"type": "integer"}}, []),
    ("aktivitaet_lesen", "Denkprotokoll in Echtzeit abfragen: Ereignisse (denken, text, tool, tool_ergebnis, schritt_ende, auftrag, eskalation) "
     "seit Nummer 'seit' (0 = alles im Puffer); 'naechste' aus der Antwort als neues 'seit' nehmen. warte_s (max 30) wartet auf Neues.",
     {"job_id": STR, "port": {"type": "integer"}, "seit": {"type": "integer"}, "arten": LST, "max": {"type": "integer"},
      "warte_s": {"type": "integer"}}, []),
    ("trace_setzen", "Denkprotokoll an-/ausschalten (ab dann wird mitgeschnitten; Ring-Puffer im Speicher, Datei <sid>.trace.jsonl).",
     {"job_id": STR, "port": {"type": "integer"}, "aktiv": {"type": "boolean"}}, ["aktiv"]),
    ("eskalation_status", "Status der Laufzeit-Eskalation (auf größeres Modell) der laufenden clau-Proxys: Konfig, Zähler, ob eskaliert.",
     {"port": {"type": "integer"}}, []),
    ("eskalation_setzen", "Laufzeit-Eskalation steuern. aktiv (bool), ziel (Modell-ID, z.B. d-qwen3.8-flash-next-q3xl-1x261k), Schwellen "
     "compact_max, fehler_max, abbrueche_max, schleife_max, ueberlauf_max, fenster (Anfragen), zurueck_nach (0 = bleibt), skalieren (bool); "
     "jetzt=true eskaliert sofort, zurueck=true geht zurück. Gilt ab der nächsten Anfrage, ohne Neustart.",
     {"port": {"type": "integer"}, "aktiv": {"type": "boolean"}, "ziel": STR, "compact_max": {"type": "integer"},
      "fehler_max": {"type": "integer"}, "abbrueche_max": {"type": "integer"}, "schleife_max": {"type": "integer"},
      "ueberlauf_max": {"type": "integer"}, "fenster": {"type": "integer"}, "zurueck_nach": {"type": "integer"},
      "skalieren": {"type": "boolean"}, "jetzt": {"type": "boolean"}, "zurueck": {"type": "boolean"}}, []),
]


def run(name, a):
    if name in ("fortschritt", "aktivitaet_lesen", "trace_setzen"):
        sys.path.insert(0, os.path.dirname(DEL))
        import eskalation
        try:
            cwd = None
            if a.get("job_id"):
                cwd = json.load(open(os.path.expanduser(f"~/.local/share/clau/delegate/jobs/{a['job_id']}/job.json")))["work"]
            kw = {"port": a.get("port"), "cwd": cwd}
            if name == "fortschritt":
                r = eskalation.anfrage_proxy("/fortschritt", **kw)
            elif name == "trace_setzen":
                r = eskalation.anfrage_proxy("/trace", {"aktiv": bool(a.get("aktiv"))}, **kw)
            else:
                arten = ",".join(a.get("arten") or [])
                r = eskalation.anfrage_proxy(f"/aktivitaet?seit={int(a.get('seit') or 0)}&max={int(a.get('max') or 100)}"
                                             f"&arten={arten}&warte={int(a.get('warte_s') or 0)}", timeout=60, **kw)
            return json.dumps(r, ensure_ascii=False, indent=1), False
        except Exception as e:
            return f"Fehler: {e}", True
    if name.startswith("eskalation_"):
        sys.path.insert(0, os.path.dirname(DEL))
        import eskalation
        try:
            d = None if name == "eskalation_status" else {k: v for k, v in a.items() if k != "port"}
            return json.dumps(eskalation.steuern(d, a.get("port")), ensure_ascii=False, indent=1), False
        except Exception as e:
            return f"Fehler: {e}", True
    if name == "delegate":
        p = subprocess.run([sys.executable, DEL, "start", "-"], input=json.dumps(a), capture_output=True, text=True)
    elif name == "job_zwischenstand":
        p = subprocess.run([sys.executable, DEL, "status", a["job_id"]], capture_output=True, text=True)
    elif name == "job_ergebnis":
        cmd = [sys.executable, DEL, "wait", a["job_id"], str(a["warte_s"])] if a.get("warte_s") else [sys.executable, DEL, "result", a["job_id"]]
        p = subprocess.run(cmd, capture_output=True, text=True)
    elif name == "job_weiter":
        p = subprocess.run([sys.executable, DEL, "more", a["job_id"], a["text"]], capture_output=True, text=True)
    elif name == "job_stop":
        p = subprocess.run([sys.executable, DEL, "stop", a["job_id"]], capture_output=True, text=True)
    else:
        p = subprocess.run([sys.executable, DEL, "list"], capture_output=True, text=True)
    return (p.stdout + p.stderr).strip() or "(leer)", p.returncode != 0


def reply(i, res=None, err=None):
    m = {"jsonrpc": "2.0", "id": i}
    m["error" if err else "result"] = err or res
    sys.stdout.write(json.dumps(m, ensure_ascii=False) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    m, i = r.get("method"), r.get("id")
    if m == "initialize":
        reply(i, {"protocolVersion": r["params"].get("protocolVersion", "2024-11-05"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "clau-delegate", "version": "1.0"}})
    elif m == "tools/list":
        reply(i, {"tools": [{"name": n, "description": d, "inputSchema": {"type": "object", "properties": p, "required": req}}
                            for n, d, p, req in TOOLS]})
    elif m == "tools/call":
        try:
            txt, bad = run(r["params"]["name"], r["params"].get("arguments") or {})
        except Exception as e:
            txt, bad = f"Fehler: {e!r}", True
        reply(i, {"content": [{"type": "text", "text": txt}], "isError": bad})
    elif i is not None:
        reply(i, err={"code": -32601, "message": "unbekannt"})
