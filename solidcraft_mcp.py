#!/usr/bin/env python3
"""
solidcraft_mcp.py — SolidCraft (parametrisches CAD) als optionales MCP-Werkzeug für clau.

Nur aktiv bei CLAU_SOLIDCRAFT=1 oder "solidcraft": true im clau --delegate-Spec.
Dünne stdio-Schicht vor der vorhandenen Brücke (mcp_bruecke.py, Port 8311, ein CLI-Prozess je Chat,
Entwurf bleibt erhalten, modell.stl + 3D-Ansicht-Link bleiben bestehen). Die Brücke arbeitet im
WebUI-Ordner static/arbeit/<kennung>/; diese Schicht spiegelt vor jedem Aufruf Eingabedateien aus
dem cwd dorthin und holt danach neue/geänderte Dateien (modell.stl, STEP, PNG, 3MF ...) ins cwd.
Kennung: CLAU_CHAT_ID, sonst Ordnername (wie matlab_mcp.py).
Env: CLAU_SOLIDCRAFT_URL (Default http://127.0.0.1:8311/mcp), CLAU_SOLIDCRAFT_ROOT.
"""
import json
import os
import re
import shutil
import sys
import urllib.request
from pathlib import Path

URL = os.environ.get("CLAU_SOLIDCRAFT_URL", "http://127.0.0.1:8311/mcp")
WURZEL = Path(os.environ.get(
    "CLAU_SOLIDCRAFT_ROOT", "/mnt/models/open-webui-venv/lib/python3.12/site-packages/open_webui/static/arbeit"))
EXT = {".stl", ".step", ".stp", ".3mf", ".obj", ".png", ".sc", ".svg", ".dxf", ".json", ".csv", ".txt"}
MAX_MB = 100


def kennung():
    k = os.environ.get("CLAU_CHAT_ID") or os.path.basename(os.getcwd().rstrip("/"))
    return re.sub(r"[^A-Za-z0-9]", "", k)[:16] or "allgemein"


def post(body):
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "X-Chat-Id": kennung()})
    with urllib.request.urlopen(req, timeout=620) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def stand(d):
    out = {}
    try:
        for f in d.iterdir():
            if f.is_file() and f.suffix.lower() in EXT:
                s = f.stat()
                out[f.name] = (s.st_size, int(s.st_mtime))
    except OSError:
        pass
    return out


def rein(ziel):
    ziel.mkdir(parents=True, exist_ok=True)
    for f in Path.cwd().iterdir():
        if f.is_file() and f.suffix.lower() in EXT and not f.name.startswith("."):
            s = f.stat()
            z = ziel / f.name
            if s.st_size <= MAX_MB * 1048576 and (not z.exists() or z.stat().st_mtime < s.st_mtime):
                shutil.copy2(f, z)


def raus(ziel, vorher):
    geholt = []
    for n, st in stand(ziel).items():
        if vorher.get(n) != st:
            shutil.copy2(ziel / n, Path.cwd() / n)
            geholt.append(n)
    return geholt


def reply(i, res=None, err=None):
    m = {"jsonrpc": "2.0", "id": i}
    m["error" if err else "result"] = err or res
    sys.stdout.write(json.dumps(m, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        i = r.get("method"), r.get("id")
        m, rid = i
        if rid is None:
            continue
        ziel = WURZEL / kennung()
        try:
            if m == "tools/call":
                rein(ziel)
                vorher = stand(ziel)
                ant = post(r)
                neu = raus(ziel, vorher)
                res = (ant or {}).get("result")
                if res and neu:
                    res.setdefault("content", []).append({"type": "text", "text":
                        "Dateien im Arbeitsverzeichnis (cwd) aktualisiert: " + ", ".join(neu)
                        + " – Pfade relativ zum cwd angeben; die http-Links oben nur an den Nutzer weitergeben."})
                reply(rid, res, (ant or {}).get("error"))
            else:
                ant = post(r)
                reply(rid, (ant or {}).get("result"), (ant or {}).get("error"))
        except Exception as e:
            reply(rid, err={"code": -32000, "message": f"SolidCraft-Brücke nicht erreichbar ({URL}): {e}"})


if __name__ == "__main__":
    main()
