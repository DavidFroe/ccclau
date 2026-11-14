#!/usr/bin/env python3
"""
gitea_mcp.py — MCP-Server: Ticketsystem (Issues) und Pull Requests der lokalen clau-Gitea-Instanz für das
Repository des aktuellen Projekts. Damit arbeitet der Harness Tickets ab: lesen, kommentieren, schließen,
neue anlegen, Pull Request aus dem Harness-Fork.

Env (setzt clau):  GITEA_URL, GITEA_TOKEN_FILE, GITEA_REPO ("clau/projekt"), GITEA_FORK ("h-nano/projekt", optional),
                   GITEA_HARNESS
"""
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("GITEA_URL", "http://127.0.0.1:3300").rstrip("/")
REPO = os.environ.get("GITEA_REPO", "")
FORK = os.environ.get("GITEA_FORK", "")
HARNESS = os.environ.get("GITEA_HARNESS", "")
TOKEN_FILE = os.environ.get("GITEA_TOKEN_FILE", "")
STR = {"type": "string"}
INT = {"type": "integer"}
LST = {"type": "array", "items": STR}


def token():
    try:
        return open(TOKEN_FILE).read().strip()
    except OSError:
        return ""


def api(method, path, body=None):
    req = urllib.request.Request(f"{URL}/api/v1{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"token {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read()).get("message", "")
        except ValueError:
            msg = ""
        raise RuntimeError(f"Gitea HTTP {e.code}: {msg}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"Gitea nicht erreichbar ({URL}): {e.reason}")


def _short(i):
    return {"nummer": i["number"], "titel": i["title"], "status": i["state"],
            "labels": [l["name"] for l in i.get("labels") or []],
            "zugewiesen": [a["login"] for a in i.get("assignees") or []],
            "kommentare": i.get("comments", 0), "url": i.get("html_url", "")}


def _label_ids(names):
    if not names:
        return None
    have = {l["name"].lower(): l["id"] for l in api("GET", f"/repos/{REPO}/labels?limit=100")}
    ids = []
    for n in names:
        if n.lower() not in have:
            have[n.lower()] = api("POST", f"/repos/{REPO}/labels", {"name": n, "color": "#4c9aff"})["id"]
        ids.append(have[n.lower()])
    return ids


def t_liste(a):
    q = f"?type=issues&state={a.get('status', 'open')}&limit={int(a.get('max', 30))}"
    if a.get("suche"):
        q += "&q=" + urllib.request.quote(a["suche"])
    if a.get("labels"):
        q += "&labels=" + urllib.request.quote(",".join(a["labels"]))
    if a.get("zugewiesen"):
        q += "&assigned_by=" + urllib.request.quote(a["zugewiesen"])
    return [_short(i) for i in api("GET", f"/repos/{REPO}/issues{q}")]


def t_lesen(a):
    n = int(a["nummer"])
    i = api("GET", f"/repos/{REPO}/issues/{n}")
    d = _short(i)
    d["text"] = i.get("body", "")
    d["kommentare_liste"] = [{"von": c["user"]["login"], "zeit": c["created_at"], "text": c["body"]}
                             for c in api("GET", f"/repos/{REPO}/issues/{n}/comments")]
    return d


def t_neu(a):
    body = {"title": a["titel"], "body": a.get("text", "")}
    ids = _label_ids(a.get("labels"))
    if ids:
        body["labels"] = ids
    if a.get("zugewiesen"):
        body["assignees"] = [a["zugewiesen"]]
    return _short(api("POST", f"/repos/{REPO}/issues", body))


def t_kommentar(a):
    c = api("POST", f"/repos/{REPO}/issues/{int(a['nummer'])}/comments", {"body": a["text"]})
    return {"ok": True, "kommentar_id": c.get("id")}


def t_aendern(a):
    body = {}
    for k_in, k_out in (("titel", "title"), ("text", "body"), ("status", "state")):
        if a.get(k_in) is not None:
            body[k_out] = a[k_in]
    if a.get("zugewiesen") is not None:
        body["assignees"] = [a["zugewiesen"]] if a["zugewiesen"] else []
    res = api("PATCH", f"/repos/{REPO}/issues/{int(a['nummer'])}", body) if body else api("GET", f"/repos/{REPO}/issues/{int(a['nummer'])}")
    if a.get("labels") is not None:
        api("PUT", f"/repos/{REPO}/issues/{int(a['nummer'])}/labels", {"labels": _label_ids(a["labels"]) or []})
        res = api("GET", f"/repos/{REPO}/issues/{int(a['nummer'])}")
    return _short(res)


def t_pr(a):
    head = a.get("head") or ""
    if FORK and ":" not in head and not a.get("im_hauptrepo"):
        head = f"{FORK.split('/')[0]}:{head}"      # Branch aus dem Harness-Fork
    body = {"title": a["titel"], "body": a.get("text", ""), "head": head, "base": a.get("base", "main")}
    p = api("POST", f"/repos/{REPO}/pulls", body)
    return {"nummer": p["number"], "url": p.get("html_url", ""), "status": p["state"]}


def t_repo(_a):
    r = api("GET", f"/repos/{REPO}")
    return {"repo": REPO, "url": r.get("html_url"), "clone_url": r.get("clone_url"), "standard_branch": r.get("default_branch"),
            "offene_tickets": r.get("open_issues_count"), "harness": HARNESS, "fork": FORK or None,
            "fork_clone_url": f"{URL}/{FORK}.git" if FORK else None,
            "hinweis": "Git-Remotes im Projekt: 'gitea' (Hauptrepo) und 'gitea-<harness>' (Fork)."}


TOOLS = [
    ("ticket_liste", "Tickets (Issues) des Projekts auflisten.",
     {"status": {"type": "string", "enum": ["open", "closed", "all"]}, "suche": STR, "labels": LST, "zugewiesen": STR, "max": INT}, [], t_liste, True),
    ("ticket_lesen", "Ein Ticket mit Text und allen Kommentaren lesen.", {"nummer": INT}, ["nummer"], t_lesen, True),
    ("ticket_neu", "Neues Ticket anlegen.", {"titel": STR, "text": STR, "labels": LST, "zugewiesen": STR}, ["titel"], t_neu, False),
    ("ticket_kommentar", "Kommentar zu einem Ticket schreiben (Fortschritt, Ergebnis, Rückfrage).",
     {"nummer": INT, "text": STR}, ["nummer", "text"], t_kommentar, False),
    ("ticket_aendern", "Ticket ändern: status ('open'/'closed'), titel, text, labels (ersetzt), zugewiesen.",
     {"nummer": INT, "status": {"type": "string", "enum": ["open", "closed"]}, "titel": STR, "text": STR, "labels": LST, "zugewiesen": STR},
     ["nummer"], t_aendern, False),
    ("pull_request_neu", "Pull Request aus einem Branch (standardmäßig aus dem Harness-Fork) ins Hauptrepo.",
     {"titel": STR, "head": {"type": "string", "description": "Branchname im Fork"}, "base": STR, "text": STR,
      "im_hauptrepo": {"type": "boolean", "description": "true = head ist ein Branch im Hauptrepo selbst"}}, ["titel", "head"], t_pr, False),
    ("repo_info", "Repository dieses Projekts: URL, Branch, Fork des Harness, offene Tickets.", {}, [], t_repo, True),
]
BY = {t[0]: t for t in TOOLS}
_out = None


def send(o):
    print(json.dumps(o, ensure_ascii=False), flush=True)


def handle(req):
    m, rid = req.get("method"), req.get("id")
    if rid is None:
        return
    if m == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": (req.get("params") or {}).get("protocolVersion") or "2024-11-05",
            "capabilities": {"tools": {}}, "serverInfo": {"name": "gitea", "version": "1.0.0"}}})
    elif m == "ping":
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif m == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": [
            {"name": n, "description": d, "inputSchema": {"type": "object", "properties": p, "required": r},
             **({"annotations": {"readOnlyHint": True}} if ro else {})} for n, d, p, r, _f, ro in TOOLS]}})
    elif m == "tools/call":
        p = req.get("params") or {}
        t = BY.get(p.get("name"))
        if not t:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": f"Unbekanntes Tool: {p.get('name')}"}})
            return
        try:
            res, is_err = t[4](p.get("arguments") or {}), False
        except Exception as e:  # noqa: BLE001
            res, is_err = {"fehler": str(e)}, True
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=1)}], "isError": is_err}})
    else:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"Unbekannte Methode: {m}"}})


def main():
    for line in sys.stdin:
        line = line.strip()
        if line:
            try:
                handle(json.loads(line))
            except json.JSONDecodeError:
                continue


if __name__ == "__main__":
    main()
