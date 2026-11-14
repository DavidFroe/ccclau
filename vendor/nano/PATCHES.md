# Lokale Patches zu nano-claude-code

Upstream: Commit 353c33d (siehe `UPSTREAM.md`). Patches klein halten, damit ein
Neu-Vendoring einfach bleibt.

| Datei | Funktion | Zweck | Datum |
|---|---|---|---|
| `pyproject.toml` | `readme`-Feld | `README.md` → `NOTICE-README.md` (README wurde beim Vendoring umbenannt, sonst schlägt `pip install` fehl) | 2026-11-07 |
| `nano_claude_code/agent.py` | `_usage_dict` | `None`-Werte (Proxy liefert kein `cache_creation_input_tokens`) → 0 statt TypeError | 2026-11-08 |
| `nano_claude_code/agent.py`, `openai_compat.py` | `CONTEXT_WINDOW_TOKENS` | Env `NANO_CONTEXT_WINDOW` (Default 200000) für Kontextfenster lokaler Modelle | 2026-11-08 |
| `nano_claude_code/prompts.py` | `build_system_prompt` | Env `NANO_APPEND_SYSTEM_PROMPT_FILE`: Datei wird an den System-Prompt gehängt (QUITEQUE_HINT.md) | 2026-11-08 |
| `nano_claude_code/cc_import.py` (neu) | `load_cc_session` | liest Claude-Code-Sessions (`~/.claude/projects/*/<uuid>.jsonl`) nur lesend und wandelt sie in nano-Nachrichten um | 2026-11-08 |
| `nano_claude_code/cli.py` | `_load_resume_session` | ruft `load_cc_session` auf, wenn das Argument eine CC-UUID/.jsonl ist | 2026-11-08 |
| `nano_claude_code/tools_impl.py` | `anthropic_tool_defs` | Env `NANO_TOOLS` (kommagetrennt) beschränkt die an das Modell gesendeten Tools (Allowlist pro Verzeichnis aus clau) | 2026-11-08 |
| `nano_claude_code/mcp_client.py` (neu), `tools_impl.py` | `anthropic_tool_defs`, `dispatch_tool` | MCP-Client (stdio): Server aus Env `NANO_MCP_CONFIG` (Claude-Code-Format), Tools als `mcp__<server>__<tool>` | 2026-11-08 |
| `nano_claude_code/ui.py` (neu), `cli.py` | `run_repl`, `_ask_permission` | Maskottchen/Banner entfernt (`--mascot` bleibt No-op); neue Oberfläche nach dem Bedienmuster von Claude Code in eigener Optik: Kopfzeile, Eingabe mit Trennlinie + Statusleiste, `●` Antworttext, `▪` Tool-Zeilen mit `└` Ergebnis, Spinner mit Laufzeit, Rückfrage 1/2/3, Markdown-Darstellung (Überschriften, Listen, Zitate, Codeblöcke, fett/kursiv/`code`) | 2026-11-14 |
