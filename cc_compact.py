#!/usr/bin/env python3
"""
cc_compact.py — Custom Compact für ccclau.

Liest die aktuelle claude-CLI Session, fasst sie chunked zusammen
(Standard-Modell: owl:120 = PropellerA 97k), und schreibt eine neue
Session-JSONL die mit `claude --resume <id>` fortgesetzt werden kann.

Defaults:
  - Summary-Modell:    owl:120 (PropellerA, lokal, schnell)
  - Chunk-Limit:       70_000 Tokens Input pro Chunk (97k - Reserve)
  - Output-Ziel:       68_000 Tokens (User-Wunsch)
  - User:              opencode (QuiteQue-User)

Verwendung:
  cc_compact.py [--model <owl_id>] [--target-tokens N] [--user <name>]
                [--session <path/to/session.jsonl>]
"""

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
import uuid as uuidlib
from pathlib import Path


# -------------------------------------------------------------------
# Defaults / Config
# -------------------------------------------------------------------

DEFAULTS = {
    "qq_url": "http://11.0.0.13:7077",
    "qq_user": "opencode",
    "summary_model": "120",  # QuiteQue nutzt numerische IDs (nicht "owl:120")
    "chunk_input_tokens": 70_000,
    "target_output_tokens": 68_000,
    "min_chunk_tokens": 20_000,
}

# Reserve pro Chunk: System-Prompt + Summary-Prompt + Output
# 97_000 - 70_000 = 27_000 reserve sollte reichen
RESERVE_TOKENS = 27_000


# -------------------------------------------------------------------
# Token-Schätzung (grob aber OK)
# -------------------------------------------------------------------

def estimate_tokens(text: str) -> int:
    """Grobe Token-Schätzung: ~3.5 chars/token für Deutsch/Englisch Mix."""
    if not text:
        return 0
    return max(1, len(text) // 3)


def text_from_content(content) -> str:
    """Extrahiert Text aus content (str oder list-of-blocks)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for b in content:
            if isinstance(b, dict):
                t = b.get("text")
                if isinstance(t, str):
                    out.append(t)
                elif b.get("type") == "tool_use":
                    name = b.get("name", "?")
                    inp = b.get("input", {})
                    out.append(f"[Tool: {name}({json.dumps(inp)[:300]})]")
                elif b.get("type") == "tool_result":
                    out.append(f"[Tool-Result: {str(b.get('content',''))[:500]}]")
                elif b.get("type") == "thinking":
                    out.append(f"[Thinking: {str(t)[:300]}]")
        return "\n".join(out)
    return str(content)


# -------------------------------------------------------------------
# Session-Lesen
# -------------------------------------------------------------------

def load_session(path: Path) -> list[dict]:
    """Lädt Messages aus Session-JSONL. Gibt Liste von {role, content, ts} zurück."""
    msgs = []
    seen_uuids = set()
    for line in open(path):
        try:
            d = json.loads(line)
        except Exception:
            continue
        msg = d.get("message")
        if not isinstance(msg, dict):
            continue
        if d.get("isMeta"):
            continue
        if d.get("isSidechain"):
            continue
        role = msg.get("role")
        if role not in ("user", "assistant"):
            continue
        u = d.get("uuid")
        if u and u in seen_uuids:
            continue
        if u:
            seen_uuids.add(u)
        text = text_from_content(msg.get("content"))
        if not text.strip():
            continue
        msgs.append({
            "role": role,
            "content": text,
            "ts": d.get("timestamp", ""),
            "model": msg.get("model", ""),
        })
    return msgs


def chunk_messages(msgs: list[dict], max_tokens: int) -> list[list[dict]]:
    """Teilt Messages in Chunks die je max_tokens nicht überschreiten."""
    chunks = []
    cur = []
    cur_tokens = 0
    for m in msgs:
        mt = estimate_tokens(m["content"])
        if cur and cur_tokens + mt > max_tokens:
            chunks.append(cur)
            cur = []
            cur_tokens = 0
        cur.append(m)
        cur_tokens += mt
    if cur:
        chunks.append(cur)
    return chunks


# -------------------------------------------------------------------
# QuiteQue-Client
# -------------------------------------------------------------------

def normalize_model_id(model: str) -> str:
    """QuiteQue akzeptiert nur numerische IDs, nicht 'owl:120'."""
    m = model.strip()
    if m.startswith("owl:"):
        m = m[4:]
    return m


def call_quiteque(
    qq_url: str, user: str, model: str, system: str, user_msg: str,
    max_tokens: int, timeout: int = 600
) -> str:
    """Sendet einen Chat-Completion-Request an QuiteQue und gibt den Text zurück."""
    model = normalize_model_id(model)
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user_msg},
        ],
        "max_tokens": max_tokens,
        "temperature": 0.3,
    }
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{qq_url}/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-OwlTrail-User": user,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data["choices"][0]["message"]["content"]


# -------------------------------------------------------------------
# Summarization
# -------------------------------------------------------------------

SYSTEM_PROMPT = """Du bist ein präziser, technischer Zusammenfasser. Deine Aufgabe:
- Erhalte die wichtigsten Informationen, Tasks, Code-Snippets, Entscheidungen
- Behalte Pfade, Dateinamen, Funktionsnamen, Fehlermeldungen wortgenau
- Streiche Höflichkeiten, Wiederholungen, redundante Erklärungen
- Strukturiere mit Überschriften und Bullet-Points
- KEINE Kommentare zur Aufgabe, nur die Zusammenfassung
- Behalte das Wissen, das man braucht um die Arbeit fortzusetzen"""


def build_chunk_prompt(chunk_idx: int, total_chunks: int, msgs: list[dict], is_partial: bool) -> str:
    """Baut den User-Prompt für einen Chunk."""
    label = f"Teil {chunk_idx+1}/{total_chunks}"
    if is_partial:
        suffix = (
            f"\n\nDas ist {label} einer längeren Konversation. "
            "Fasse NUR diesen Teil zusammen. Erwähne am Ende kurz "
            "'(Fortsetzung im nächsten Teil)' damit klar ist dass dies nicht das Ende ist."
        )
    else:
        suffix = (
            f"\n\nDas ist {label} (gleichzeitig die gesamte Konversation). "
            "Fasse sie komplett zusammen."
        )

    lines = ["Konversation:\n"]
    for m in msgs:
        role = "User" if m["role"] == "user" else "Assistant"
        text = m["content"]
        # harte Kürzung falls einzelne Message zu lang
        if len(text) > 8000:
            text = text[:4000] + "\n... [gekürzt] ...\n" + text[-4000:]
        lines.append(f"### {role}:\n{text}\n")
    lines.append(suffix)
    return "\n".join(lines)


def build_combine_prompt(chunk_summaries: list[str]) -> str:
    """Baut den User-Prompt um mehrere Chunk-Zusammenfassungen zu kombinieren."""
    out = [
        "Du hast mehrere Teil-Zusammenfassungen einer langen Konversation erhalten. ",
        "Kombiniere sie zu EINER kohärenten Gesamt-Zusammenfassung. ",
        "Wichtig: keine Informationen doppelt, behalte chronologische Reihenfolge, ",
        "strukturiere mit klaren Überschriften. Max ~5000 Wörter.\n\n",
    ]
    for i, s in enumerate(chunk_summaries, 1):
        out.append(f"### Teil-Zusammenfassung {i}:\n{s}\n\n")
    return "".join(out)


def summarize_session(
    msgs: list[dict], qq_url: str, user: str, model: str, target_tokens: int
) -> str:
    """Fasst die Session zusammen. Chunked falls nötig. Liefert finale Zusammenfassung."""
    model = normalize_model_id(model)
    total_input_tokens = sum(estimate_tokens(m["content"]) for m in msgs)
    chunks = chunk_messages(msgs, DEFAULTS["chunk_input_tokens"])
    print(f"[cc_compact] {len(msgs)} Messages, {total_input_tokens} Tokens Input, {len(chunks)} Chunk(s)", file=sys.stderr)

    chunk_summaries = []
    for i, chunk in enumerate(chunks):
        prompt = build_chunk_prompt(i, len(chunks), chunk, is_partial=(len(chunks) > 1))
        print(f"[cc_compact] Summarizing chunk {i+1}/{len(chunks)}...", file=sys.stderr)
        # Reserve für Summary-Output: max was geht, aber gedeckelt
        out_tokens = min(target_tokens, 20_000)
        try:
            s = call_quiteque(qq_url, user, model, SYSTEM_PROMPT, prompt, out_tokens)
        except urllib.error.HTTPError as e:
            err = e.read().decode("utf-8", errors="replace")[:500]
            print(f"[cc_compact] HTTP error on chunk {i+1}: {e.code} {err}", file=sys.stderr)
            raise
        chunk_summaries.append(s)
        print(f"[cc_compact] Chunk {i+1} summary: {estimate_tokens(s)} Tokens", file=sys.stderr)

    if len(chunks) == 1:
        return chunk_summaries[0]

    # Mehrere Chunks → kombinieren
    print(f"[cc_compact] Combining {len(chunk_summaries)} chunk summaries...", file=sys.stderr)
    combined_prompt = build_combine_prompt(chunk_summaries)
    out_tokens = min(target_tokens, 20_000)
    final = call_quiteque(qq_url, user, model, SYSTEM_PROMPT, combined_prompt, out_tokens)
    print(f"[cc_compact] Final summary: {estimate_tokens(final)} Tokens", file=sys.stderr)
    return final


# -------------------------------------------------------------------
# Session-Schreiben
# -------------------------------------------------------------------

def write_new_session(
    summary: str,
    project_dir: Path,
    cwd: str,
    original_session: dict,
    summary_model: str,
) -> str:
    """Schreibt eine neue Session-JSONL mit System+User(summary)+Assistant. Gibt ID zurück."""
    new_id = str(uuidlib.uuid4())
    now = _now_iso()
    version = "2.0"  # claude-CLI version

    lines = []

    # 1. System-Message (kompakt)
    system_msg = {
        "type": "system",
        "subtype": "compact",
        "compactMetadata": {
            "trigger": "ccclau-custom",
            "summaryModel": summary_model,
            "originalSessionId": original_session.get("sessionId", ""),
            "originalMessageCount": original_session.get("messageCount", 0),
        },
        "isMeta": True,
        "uuid": str(uuidlib.uuid4()),
        "timestamp": now,
        "sessionId": new_id,
    }
    lines.append(json.dumps(system_msg))

    # 2. User-Message mit der Zusammenfassung
    user_uuid = str(uuidlib.uuid4())
    user_msg = {
        "type": "user",
        "isMeta": False,
        "isVisibleInTranscriptOnly": False,
        "message": {
            "role": "user",
            "content": [{
                "type": "text",
                "text": (
                    "Hier ist eine Zusammenfassung der vorherigen Session "
                    "(erstellt mit ccclau custom-compact, Modell "
                    f"{summary_model}):\n\n---\n\n{summary}"
                ),
            }],
        },
        "uuid": user_uuid,
        "parentUuid": None,
        "timestamp": now,
        "sessionId": new_id,
        "userType": "external",
        "entrypoint": "sdk-cli",
        "cwd": cwd,
        "version": version,
    }
    lines.append(json.dumps(user_msg))

    # 3. Assistant-Message als Bestätigung
    asst_uuid = str(uuidlib.uuid4())
    asst_msg = {
        "type": "assistant",
        "message": {
            "id": "msg_" + uuidlib.uuid4().hex[:24],
            "type": "message",
            "role": "assistant",
            "content": [{
                "type": "text",
                "text": "Verstanden. Ich habe die Zusammenfassung der vorherigen Session gelesen und bin bereit, auf dieser Grundlage weiterzuarbeiten. Was soll ich als Nächstes tun?",
            }],
            "model": "claude-sonnet-4-6",
            "stop_reason": "end_turn",
            "stop_sequence": None,
            "usage": {
                "input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0,
                "output_tokens": 0,
                "server_tool_use": {"web_search_requests": 0, "web_fetch_requests": 0},
                "service_tier": "standard",
                "cache_creation": {"ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 0},
            },
        },
        "uuid": asst_uuid,
        "parentUuid": user_uuid,
        "isMeta": False,
        "isApiErrorMessage": False,
        "timestamp": now,
        "userType": "external",
        "entrypoint": "sdk-cli",
        "cwd": cwd,
        "sessionId": new_id,
        "version": version,
        "gitBranch": "HEAD",
    }
    lines.append(json.dumps(asst_msg))

    # 4. last-prompt
    last_prompt = {
        "type": "last-prompt",
        "lastPrompt": "Hier ist eine Zusammenfassung der vorherigen Session...",
        "leafUuid": asst_uuid,
        "sessionId": new_id,
    }
    lines.append(json.dumps(last_prompt))

    # Schreiben
    new_file = project_dir / f"{new_id}.jsonl"
    with open(new_file, "w") as f:
        f.write("\n".join(lines) + "\n")

    return new_id


def _now_iso() -> str:
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="ccclau custom compact")
    ap.add_argument("--model", default=DEFAULTS["summary_model"],
                    help=f"QuiteQue-Modell (numerische ID, default: {DEFAULTS['summary_model']}; akzeptiert auch 'owl:120' → 120)")
    ap.add_argument("--user", default=DEFAULTS["qq_user"],
                    help=f"QuiteQue-User (default: {DEFAULTS['qq_user']})")
    ap.add_argument("--qq-url", default=DEFAULTS["qq_url"],
                    help=f"QuiteQue-URL (default: {DEFAULTS['qq_url']})")
    ap.add_argument("--target-tokens", type=int, default=DEFAULTS["target_output_tokens"],
                    help=f"Output-Ziel Tokens (default: {DEFAULTS['target_output_tokens']})")
    ap.add_argument("--session", help="Pfad zur Session-JSONL (default: latest im aktuellen Projekt)")
    ap.add_argument("--dry-run", action="store_true", help="Nur parsen + planen, keine API-Calls")
    args = ap.parse_args()
    args.model = normalize_model_id(args.model)

    home = Path(os.environ.get("HOME", str(Path.home())))
    claude_projects = home / ".claude" / "projects"
    cwd = os.environ.get("PWD", str(Path.cwd()))
    project_hash = cwd.replace("/", "-")
    project_dir = claude_projects / project_hash

    # Session finden
    if args.session:
        session_path = Path(args.session)
    else:
        candidates = sorted(project_dir.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not candidates:
            print(f"FEHLER: Keine Session gefunden in {project_dir}", file=sys.stderr)
            sys.exit(1)
        session_path = candidates[0]
    print(f"[cc_compact] Session: {session_path}", file=sys.stderr)

    # Original-Session-Metadaten lesen
    orig = {}
    for line in open(session_path):
        try:
            d = json.loads(line)
            if d.get("sessionId"):
                orig["sessionId"] = d["sessionId"]
            if d.get("type") == "user":
                orig["messageCount"] = orig.get("messageCount", 0) + 1
            if d.get("type") == "assistant":
                orig["messageCount"] = orig.get("messageCount", 0) + 1
        except Exception:
            pass
    if "messageCount" not in orig:
        orig["messageCount"] = 0

    # Messages parsen
    msgs = load_session(session_path)
    if not msgs:
        print("FEHLER: Keine Messages in Session", file=sys.stderr)
        sys.exit(1)
    total_input_tokens = sum(estimate_tokens(m["content"]) for m in msgs)
    print(f"[cc_compact] {len(msgs)} Messages, ~{total_input_tokens} Tokens Input", file=sys.stderr)
    print(f"[cc_compact] Summary-Model: {args.model} (User: {args.user})", file=sys.stderr)
    print(f"[cc_compact] Output-Ziel:   {args.target_tokens} Tokens", file=sys.stderr)

    if args.dry_run:
        chunks = chunk_messages(msgs, DEFAULTS["chunk_input_tokens"])
        print(f"[cc_compact] Würde {len(chunks)} Chunk(s) an QuiteQue schicken", file=sys.stderr)
        return

    # Summary
    summary = summarize_session(
        msgs, args.qq_url, args.user, args.model, args.target_tokens
    )
    summary_tokens = estimate_tokens(summary)
    print(f"[cc_compact] Finale Zusammenfassung: {summary_tokens} Tokens ({len(summary)} chars)", file=sys.stderr)

    # Neue Session schreiben
    new_id = write_new_session(
        summary, project_dir, cwd, orig, args.model
    )
    print(f"[cc_compact] Neue Session geschrieben: {new_id}", file=sys.stderr)
    print(f"[cc_compact] Datei: {project_dir / (new_id + '.jsonl')}", file=sys.stderr)
    print()
    print(f"=== Fertig ===", file=sys.stderr)
    print(f"Original-Session:   {session_path.name}", file=sys.stderr)
    print(f"Original-Tokens:    ~{total_input_tokens}", file=sys.stderr)
    print(f"Summary-Tokens:     ~{summary_tokens}", file=sys.stderr)
    print(f"Neue Session-ID:    {new_id}", file=sys.stderr)
    print(f"Neue Datei:         {project_dir / (new_id + '.jsonl')}", file=sys.stderr)
    print(f"Summary-Modell:     {args.model}", file=sys.stderr)
    print()
    print(f"Resume mit:    clau --resume {new_id} -m owl:120", file=sys.stderr)
    print(f"Interaktiv:    clau -m owl:120 --resume {new_id}", file=sys.stderr)


if __name__ == "__main__":
    main()