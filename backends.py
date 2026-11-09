#!/usr/bin/env python3
"""
backends.py — Direktanbindung lokaler Modelle ohne Umweg über QuiteQue.

Konfiguration: ~/.config/clau/backends.json (Pfad per CLAU_BACKENDS_FILE).
Ohne Datei ist alles aus und clau verhält sich wie bisher. Beispiel: backends.example.json

  {
    "136": {"url": "http://127.0.0.1:8275/v1", "model": "qwen3.8-27b-brilliance",
            "ctx": 99328, "name": "Brilliance 27B", "api_key": ""}
  }

Schlüssel = owl-Modell-ID (wie bei owl:136). Aufrufe:
  backends.py routes            OWL_ROUTES-String (id=url#modell,...)
  backends.py tsv               Menüzeilen: id status anbieter ctx preis name
  backends.py ctx <id>          Kontextfenster
  backends.py check [<id>]      Erreichbarkeit/Modell prüfen (Exit 0 = alle ok)
"""
import json
import os
import sys
import urllib.request

PATH = os.environ.get("CLAU_BACKENDS_FILE") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"),
    "clau", "backends.json")


def load(path=None):
    try:
        with open(path or PATH, encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return {}
    out = {}
    for k, v in (raw or {}).items():
        if k.startswith("_") or not isinstance(v, dict) or not v.get("url"):
            continue
        out[str(k)] = {
            "url": v["url"].rstrip("/"),
            "model": v.get("model") or str(k),
            "ctx": int(v.get("ctx") or 0),
            "name": v.get("name") or v.get("model") or str(k),
            "api_key": v.get("api_key") or "",
        }
    return out


def routes_string(cfg=None):
    cfg = load() if cfg is None else cfg
    return ",".join(f"{k}={v['url']}#{v['model']}" for k, v in cfg.items())


def check(entry, timeout=3):
    """True, wenn der Server antwortet und (sofern /models das Modell nennt) das Modell kennt."""
    req = urllib.request.Request(entry["url"] + "/models")
    if entry.get("api_key"):
        req.add_header("Authorization", "Bearer " + entry["api_key"])
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
    except Exception:
        return False
    ids = {m.get("id") for m in (data.get("data") or [])}
    return not ids or entry["model"] in ids


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "routes"
    cfg = load()
    if cmd == "routes":
        print(routes_string(cfg))
    elif cmd == "tsv":
        for k, v in cfg.items():
            st = "OK" if check(v, 1.5) else "OFFLINE"
            print("\t".join([k, st, "direkt", str(v["ctx"]), "GRATIS", v["name"] + " [direkt]"]))
    elif cmd == "ctx":
        v = cfg.get(argv[2] if len(argv) > 2 else "")
        print(v["ctx"] if v and v["ctx"] else "")
    elif cmd == "check":
        ids = argv[2:] or list(cfg)
        bad = 0
        for k in ids:
            ok = k in cfg and check(cfg[k])
            print(f"{k}\t{'ok' if ok else 'NICHT ERREICHBAR'}\t{cfg.get(k, {}).get('url', '-')}")
            bad += 0 if ok else 1
        return 1 if bad else 0
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
