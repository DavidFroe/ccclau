# Tracker

Status: `neu` → `zugewiesen` → `in Arbeit` → `erledigt (Commit)` | `abgelehnt` | `Rückfrage`.
Agent: `clau` · `qode` · `tui` · `uebersetzung` · `tests` · `doku` · `review` · `maintainer` · `haupt` (keine passende Anweisung: macht die Hauptsitzung).

| ID | Typ | Titel | Bereich | Agent | Status | Notiz |
|---|---|---|---|---|---|---|
| T-001 | Bug | Scrollen nach oben im Terminal funktioniert in Qode nicht (geht in Claude Code) | Qode-Oberfläche | tui | zugewiesen | SSH-Sitzung; Claude Code erlaubt Scrollback, Qode nicht. Auftrag: auftraege/tui-2026-11-20.md |
| T-002 | Wunsch | Subagenten als Standard in ccclau: Einstellungen + S-Menü + subagent_ Markdowns + MCP „subagent" | clau | clau | zugewiesen | aktiv wenn Tool „subagenting" an; Subagent-Einstellungen wie Hauptagent (Dev-Umgebung, Modell); S=neuer Subagent; MCP formuliert Markdowns nach Claude-Subagent-Standards. Auftrag: auftraege/clau-2026-11-20.md |
| T-003 | Wunsch | Fähigkeit „subagent_admin": Hauptagent startet/steuert Subagenten unter tmux | Qode-Verhalten | qode | zugewiesen | Subagenten selbstständig starten (geht erstmal nicht mit Qode), Status prüfen, Befehle einspeisen, Kontext/letzte Aufgabe auslesen. Baut auf T-002 auf. Auftrag: auftraege/qode-2026-11-20.md |
| T-004 | Wunsch | tmux-Tabelle: wieder zeigen ob Session „working" (Agent arbeitet) oder angehalten | Qode-Oberfläche | tui | zugewiesen | war vorher in der tmux-Tabelle; auch für Sessions die nicht auf tmux stehen. Baut auf T-002 auf. Auftrag: auftraege/tui-2026-11-20.md |
