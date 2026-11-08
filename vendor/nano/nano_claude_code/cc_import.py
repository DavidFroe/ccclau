"""Read-only import of Claude Code sessions (~/.claude/projects/*/<uuid>.jsonl)."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def find_cc_session(arg: str) -> Path | None:
    if arg.endswith(".jsonl") and Path(arg).is_file():
        return Path(arg)
    if not _UUID.match(arg):
        return None
    root = Path.home() / ".claude" / "projects"
    hits = sorted(root.glob(f"*/{arg}.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    return hits[0] if hits else None


def _blocks(content: Any) -> list[dict[str, Any]]:
    if isinstance(content, str):
        return [{"type": "text", "text": content}] if content.strip() else []
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") in ("text", "tool_use", "tool_result"):
            if b["type"] == "text" and not str(b.get("text", "")).strip():
                continue
            out.append(b)
    return out


def load_cc_session(arg: str) -> dict[str, Any] | None:
    path = find_cc_session(arg)
    if path is None:
        return None
    messages: list[dict[str, Any]] = []
    title = ""
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        if obj.get("type") == "ai-title" or obj.get("type") == "summary":
            title = title or str(obj.get("aiTitle") or obj.get("summary") or "")
        if obj.get("type") not in ("user", "assistant") or obj.get("isSidechain") or obj.get("isMeta"):
            continue
        msg = obj.get("message") or {}
        role = msg.get("role") or obj["type"]
        blocks = _blocks(msg.get("content"))
        if not blocks:
            continue
        if messages and messages[-1]["role"] == role:
            messages[-1]["content"].extend(blocks)
        else:
            messages.append({"role": role, "content": blocks})
    # Verwaiste tool_use/tool_result am Rand entfernen, sonst lehnt die API ab
    while messages and messages[0]["role"] != "user":
        messages.pop(0)
    uses = {b.get("id") for m in messages for b in m["content"] if b.get("type") == "tool_use"}
    results = {b.get("tool_use_id") for m in messages for b in m["content"] if b.get("type") == "tool_result"}
    cleaned = []
    for m in messages:
        keep = [b for b in m["content"]
                if not (b.get("type") == "tool_use" and b.get("id") not in results)
                and not (b.get("type") == "tool_result" and b.get("tool_use_id") not in uses)]
        if keep:
            if cleaned and cleaned[-1]["role"] == m["role"]:
                cleaned[-1]["content"].extend(keep)
            else:
                cleaned.append({"role": m["role"], "content": keep})
    return {"title": title or f"[cc] {path.stem[:8]}", "messages": cleaned,
            "turn_count": 0, "total_input_tokens": 0, "total_output_tokens": 0, "model": ""}
