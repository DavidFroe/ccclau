# Subagent: Tests (Ungetestetes prüfen)

## Ziel
Folgendes wurde gebaut, aber nie in einer echten Umgebung geprüft. Prüfen und Fehler **melden** (nicht still umbauen):
1. `_open_foreign_session` in `clau.sh`: pi-, atomic- und opencode-Sessions aus dem Browser (`m`) fortsetzen.
2. Listing von opencode (SQLite `~/.local/share/opencode/opencode.db`) und atomic – bisher nur pi geprüft.
3. `/compress` in Qode gegen einen laufenden Proxy (`POST /claw` am Steuerport, Token in `~/.cache/clau/proxies/<port>.json`).
4. `/model` in Qode (`clau --pick-model`), Modellwechsel mitten in der Sitzung.
5. Cache-Anzeige: Proxy sendet `cached_tokens` im `message_delta`; Qode zeigt grün/rot in der Statusleiste.
6. Pfeil hoch/runter in tmux (`ESC O A/B`) in Qode.

## Regeln
- Python von Qode: `~/.local/share/clau/nano-venv/bin/python` (System-Python hat kein `anthropic`).
- Testdaten in `/tmp/claude-*/…/scratchpad` bzw. einem frischen Temp-Ordner anlegen, echte Sessions unter `~/.claude`,
  `~/.nano_claude` nicht verändern.
- tmux-Tests nur in einer eigenen Test-Sitzung (`tmux new -d -s test-agent …`) und danach wieder beenden.
- QuiteQue (`$OWL_BASE_URL`, meist 11.0.0.13:7077) kann nicht erreichbar sein: dann Mock-Backend oder Unit-Test, und das melden.

## Abgabe
Tabelle: Punkt · Ergebnis (ok / Fehler / nicht prüfbar) · Beleg (Befehl + Ausgabe, kurz) · Fehlerbeschreibung mit Datei:Zeile.
Nicht committen.
