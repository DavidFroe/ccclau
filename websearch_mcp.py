#!/usr/bin/env python3
"""
websearch_mcp.py — MCP-Server, der QuiteQues /websearch als Tool anbietet.

Claude Code kann über owl_proxy nicht das serverseitige WebSearch-Tool der
Anthropic-API nutzen — das gibt es nur bei Anthropic selbst. QuiteQue hat
aber eine eigene Such-Pipeline (SearXNG + Volltext + Rerank + Citation-/
Halluzinations-Check) unter POST /websearch. Dieser Server reicht sie als
MCP-Tool "websearch" durch.

Wichtig: NICHT über /v1/chat/completions mit model=websearch-* gehen —
das ist der Chat-Pfad, der die Query nie an die Suche gibt und das Modell
blind aus dem Trainingswissen antworten lässt (inkl. erfundener Quellen).

stdio-Transport, JSON-RPC 2.0. Nur stdlib. Logs gehen nach stderr,
stdout gehört dem Protokoll.

Env:
  QUITEQUE_URL       Basis-URL (Default http://11.0.0.13:7077)
  OWL_PROXY_USER     Username für X-OwlTrail-User (Default opencode)
  WEBSEARCH_DEPTH    Default-Tiefe (speed|balanced|quality, Default speed)
  WEBSEARCH_TIMEOUT  Sekunden (Default 300)
"""

import json
import os
import sys
import urllib.error
import urllib.request

QUITEQUE_URL = os.environ.get("QUITEQUE_URL", "http://11.0.0.13:7077").rstrip("/")
USER = os.environ.get("OWL_PROXY_USER", "opencode")
DEFAULT_DEPTH = os.environ.get("WEBSEARCH_DEPTH", "speed")
TIMEOUT = int(os.environ.get("WEBSEARCH_TIMEOUT", "300"))

PROTOCOL_FALLBACK = "2024-11-05"

TOOL = {
    "name": "websearch",
    "description": (
        "Durchsucht das Web über die lokale QuiteQue-Suche (SearXNG + Volltext "
        "+ Rerank) und liefert eine belegte Antwort mit Quellen-URLs. Nutze das "
        "für alles, was nach dem Trainingsstand liegt oder aktuell sein muss: "
        "Versionsnummern, Release-Daten, Preise, News, aktuelle Doku. "
        "Die Antwort enthält nur, was in den Quellen steht — sagt die Suche "
        "'steht nicht in den Quellen', dann rate nicht, sondern suche gezielter."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Suchanfrage in natürlicher Sprache.",
            },
            "depth": {
                "type": "string",
                "enum": ["speed", "balanced", "quality"],
                "description": (
                    "speed: ~15s, Snippets. balanced: ~25s, Volltext+Rerank. "
                    "quality: ~40s, zusätzlich Unterfragen. Default speed."
                ),
            },
            "max_sources": {
                "type": "integer",
                "description": "Maximale Anzahl Quellen (Default 6).",
            },
        },
        "required": ["query"],
    },
}


def log(msg):
    print(f"[websearch_mcp] {msg}", file=sys.stderr, flush=True)


def _parse_sse(stream):
    """Liest SSE und gibt (event_name, data_dict)-Paare zurück."""
    event = None
    for raw in stream:
        line = raw.decode("utf-8", "replace").rstrip("\n").rstrip("\r")
        if not line:
            event = None
            continue
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            try:
                yield event, json.loads(line[5:].strip())
            except json.JSONDecodeError:
                pass


def do_search(query, depth, max_sources):
    """Ruft QuiteQue /websearch auf. Gibt den fertigen Antworttext zurück."""
    payload = json.dumps({
        "query": query,
        "depth": depth,
        "max_sources": max_sources,
    }).encode()
    req = urllib.request.Request(
        f"{QUITEQUE_URL}/websearch",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "X-OwlTrail-User": USER,
            "Accept": "text/event-stream",
        },
        method="POST",
    )

    answer = ""
    tokens = []
    sources = []
    validation = {}
    duration_ms = None

    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            for event, data in _parse_sse(resp):
                if event == "token":
                    tokens.append(data.get("delta", ""))
                elif event == "source":
                    sources.append(data)
                elif event == "done":
                    answer = data.get("answer") or answer
                    sources = data.get("sources") or sources
                    validation = data.get("validation_summary") or {}
                    duration_ms = data.get("duration_ms")
                elif event == "error":
                    return f"Suche fehlgeschlagen: {json.dumps(data, ensure_ascii=False)}"
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:500]
        try:
            err = json.loads(body)
            kind = err.get("error", "")
            if kind == "quota_exceeded":
                return f"Such-Kontingent aufgebraucht, zurückgesetzt um {err.get('reset_at')}."
            if kind == "queue_full":
                return f"Such-Warteschlange voll, in ~{err.get('retry_after')}s nochmal."
            return f"Suche abgelehnt (HTTP {e.code}): {body}"
        except json.JSONDecodeError:
            return f"Suche abgelehnt (HTTP {e.code}): {body}"
    except urllib.error.URLError as e:
        return f"Suche nicht erreichbar ({QUITEQUE_URL}): {e.reason}"
    except TimeoutError:
        return f"Suche hat nach {TIMEOUT}s nicht geantwortet."

    if not answer:
        answer = "".join(tokens).strip()
    if not answer:
        return "Die Suche hat keine Antwort geliefert."

    out = [answer, ""]
    if sources:
        out.append("Quellen:")
        for s in sources:
            out.append(f"  [{s.get('idx', '?')}] {s.get('url', '')}")
    meta = []
    if duration_ms:
        meta.append(f"{duration_ms / 1000:.1f}s")
    if validation.get("hallucination") and validation["hallucination"] != "pass":
        meta.append(f"Halluzinations-Check: {validation['hallucination']}")
    if validation.get("citations") and validation["citations"] != "ok":
        meta.append(f"Citation-Check: {validation['citations']}")
    if meta:
        out.append("")
        out.append("(" + ", ".join(meta) + ")")
    return "\n".join(out)


def handle(req):
    """Gibt die Antwort auf einen JSON-RPC-Request zurück, oder None bei
    Notifications (die haben keine id und dürfen keine Antwort bekommen)."""
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
            "serverInfo": {"name": "websearch", "version": "1.0.0"},
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
        args = params.get("arguments") or {}
        query = str(args.get("query", "")).strip()
        if not query:
            return ok({"content": [{"type": "text", "text": "query fehlt."}],
                       "isError": True})
        depth = str(args.get("depth") or DEFAULT_DEPTH).lower()
        if depth not in ("speed", "balanced", "quality"):
            depth = DEFAULT_DEPTH
        try:
            max_sources = int(args.get("max_sources") or 6)
        except (TypeError, ValueError):
            max_sources = 6
        log(f"Suche: {query!r} depth={depth}")
        text = do_search(query, depth, max_sources)
        return ok({"content": [{"type": "text", "text": text}], "isError": False})

    return {"jsonrpc": "2.0", "id": req_id,
            "error": {"code": -32601, "message": f"Unbekannte Methode: {method}"}}


def main():
    log(f"bereit → {QUITEQUE_URL}/websearch (User {USER}, Default-Tiefe {DEFAULT_DEPTH})")
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
