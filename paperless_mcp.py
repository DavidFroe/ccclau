#!/usr/bin/env python3
"""MCP-Server (stdio) für Paperless-ngx: Dokumente suchen, lesen, Tags auflisten.

Env: PAPERLESS_URL (z.B. http://11.0.0.12:8010), PAPERLESS_TOKEN
     oder PAPERLESS_TOKEN_FILE (Standard ~/.config/clau/paperless.token).
Protokoll: newline-delimited JSON-RPC, wie websearch_mcp.py.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

URL = os.environ.get("PAPERLESS_URL", "http://11.0.0.12:8010").rstrip("/")
TOKEN_FILE = os.environ.get("PAPERLESS_TOKEN_FILE") or os.path.expanduser("~/.config/clau/paperless.token")
PROTOCOL_FALLBACK = "2024-11-05"


def log(msg):
    print(f"[paperless_mcp] {msg}", file=sys.stderr, flush=True)


def token():
    t = os.environ.get("PAPERLESS_TOKEN", "").strip()
    if not t and os.path.isfile(TOKEN_FILE):
        t = open(TOKEN_FILE, encoding="utf-8").read().strip()
    return t


def api(path, params=None):
    t = token()
    if not t:
        raise RuntimeError(f"Kein Paperless-Token (Datei {TOKEN_FILE} oder PAPERLESS_TOKEN)")
    url = f"{URL}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Token {t}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Paperless HTTP {e.code} bei {path}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Paperless nicht erreichbar ({URL}): {e.reason}")


def tool_search(a):
    limit = max(1, min(int(a.get("limit") or 10), 25))
    data = api("/api/documents/", {"query": a["query"], "page_size": limit})
    docs = data.get("results", [])
    if not docs:
        return "Keine Treffer."
    lines = [f"{data.get('count', len(docs))} Treffer, zeige {len(docs)}:"]
    for d in docs:
        hit = ((d.get("__search_hit__") or {}).get("highlights") or "")
        hit = " ".join(hit.replace("<b>", "").replace("</b>", "").replace("<span class=\"match\">", "").replace("</span>", "").split())
        lines.append(f"#{d['id']} {d.get('title', '')} ({(d.get('created') or '')[:10]})" + (f" — {hit[:200]}" if hit else ""))
    return "\n".join(lines)


def tool_read(a):
    maxc = max(500, min(int(a.get("max_chars") or 6000), 30000))
    d = api(f"/api/documents/{int(a['id'])}/")
    text = d.get("content") or ""
    cut = "" if len(text) <= maxc else f"\n[… gekürzt, {len(text) - maxc} weitere Zeichen]"
    return f"#{d['id']} {d.get('title', '')} ({(d.get('created') or '')[:10]})\n\n{text[:maxc]}{cut}"


def tool_tags(a):
    data = api("/api/tags/", {"page_size": 100, "ordering": "-document_count"})
    return "\n".join(f"{t['name']} ({t.get('document_count', 0)})" for t in data.get("results", [])) or "Keine Tags."


TOOLS = {
    "paperless_search": (tool_search, "Paperless-Dokumente per Volltext suchen. Liefert IDs, Titel, Datum, Fundstelle.",
                         {"query": {"type": "string"}, "limit": {"type": "integer"}}, ["query"]),
    "paperless_read": (tool_read, "Text eines Paperless-Dokuments lesen (per ID aus paperless_search).",
                       {"id": {"type": "integer"}, "max_chars": {"type": "integer"}}, ["id"]),
    "paperless_tags": (tool_tags, "Paperless-Tags mit Dokumentanzahl auflisten.", {}, []),
}


def handle(req):
    method, rid = req.get("method"), req.get("id")
    if method == "initialize":
        proto = (req.get("params") or {}).get("protocolVersion") or PROTOCOL_FALLBACK
        return {"protocolVersion": proto, "capabilities": {"tools": {}},
                "serverInfo": {"name": "paperless", "version": "1.0.0"}}
    if method == "tools/list":
        return {"tools": [{"name": n, "description": d,
                           "inputSchema": {"type": "object", "properties": p, "required": r}}
                          for n, (_, d, p, r) in TOOLS.items()]}
    if method == "tools/call":
        params = req.get("params") or {}
        entry = TOOLS.get(params.get("name"))
        if not entry:
            return {"content": [{"type": "text", "text": f"Unbekanntes Tool {params.get('name')}"}], "isError": True}
        try:
            return {"content": [{"type": "text", "text": entry[0](params.get("arguments") or {})}]}
        except Exception as e:
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
    if method == "ping":
        return {}
    return None


def main():
    log(f"bereit → {URL}")
    for line in sys.stdin:
        try:
            req = json.loads(line)
        except ValueError:
            continue
        res = handle(req)
        if res is not None and req.get("id") is not None:
            print(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": res}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
