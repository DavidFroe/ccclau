# Übergabe: clau Team-Modus + Fernsteuerungs-Schnittstelle

Stand: 2026-10-03 · Auftraggeber: David · Folgeprojekt: **devport** (`/home/david/devport`)

## Warum
devport wird isolierte Entwicklungs-VMs spawnen: kein Internet, nur Gitea, apt-Cache und lokale LLMs.
In jeder VM läuft **clau**. Bevor die VM gebaut wird, bekommt clau selbst die nötigen Fähigkeiten,
damit devport sie nur noch einschalten muss:

1. **Team-Modus:** Ein 27B-Frontend (Teamleiter) verteilt Arbeit an bis zu 5 Ausführer-Subagenten auf dem 178B.
   Wie stark es zerlegt, richtet sich nach der aktuellen Auslastung des 178B.
2. **Fernsteuerung:** Eine HTTP-Schnittstelle, um laufende clau-Sessions (Teamleiter, Planer, Tester) von außen
   zu sehen und anzusprechen. **Standardmäßig deaktiviert.**

Alles soll **ohne Internet** funktionieren. Update-Check, Websuche und Telegram müssen sich sauber abschalten lassen.

## Ist-Zustand (verifiziert am 03.10.)
- `owl_proxy.py` leitet **jede** Anfrage an ein festes Modell weiter: `OWL_MODEL` (Z. 82), `_handle()` Z. 500 ff.,
  `"model": OWL_MODEL`. Der angeforderte Name `req["model"]` wird ignoriert. Deshalb liefen Subagenten bisher immer auf
  demselben Modell wie das Frontend.
- QuiteQue: `OWL_BASE=http://11.0.0.13:7077/v1`, Modell-IDs `120` = Qwen3.6-27B (PropellerA, 97k) und `121` = Qwen3.8-Flash-Next
  (rund 178B MoE).
- Flash-Server: `flash-next.service` → `/mnt/models/qwen38-flash-next/starten.sh`, Parameter aus
  `/home/david/PropellerA/flash_setup.env` (zurzeit `FLASH_CTX=262144 FLASH_PAR=1 FLASH_KV=q5_1`). Das Flash-Tor auf
  **`:8293`** reicht `/slots` durch: JSON-Liste mit `id`, `n_ctx`, **`is_processing`**. Das Modell selbst lauscht auf 127.0.0.1:8294.
- **Zielbetrieb: 3 Slots × ~96k** → `FLASH_CTX=297984 FLASH_PAR=3`. Laut `starten.sh` passt dann **kein** MTP-Kopf mehr.
  262k mit einem Slot ist nur der Ausnahmezustand. (David stellt das selbst um oder gibt es frei, der Neustart unterbricht laufende 121-Anfragen.)
- Wiederverwendbar in `clau.sh`:
  - `_start_owl_proxy` (Z. 476)
  - `apply_tool_blocking` (Z. 1650; `Agent` darf im Team-Modus **nicht** gesperrt sein)
  - Hooks `tg_hook`/`apply_tg_hooks` (Z. 592/650; Notification/Stop/SessionEnd sind der Status-Lieferant)
  - `tg_mirror`/`tg_pump` (Z. 1114/1203; tmux-Session + send-keys = Eingabe in eine laufende interaktive Session)
  - `_tg_claude_turn` (Z. 961; ein Turn per `claude -p --resume`)
  - `websearch_mcp.py` als Vorlage für einen MCP-Server

## Baustein 1: Modell-Routing im owl_proxy
- Kein festes Modell mehr. Das Ziel wird aus `req["model"]` abgeleitet:
  - Name `owl-<ID>` → QuiteQue-Modell `<ID>`
  - alles andere → `OWL_MODEL` (Rückfall, damit das alte Verhalten bleibt)
- clau setzt im Team-Modus für Claude Code:
  `ANTHROPIC_MODEL=owl-120`, `ANTHROPIC_DEFAULT_OPUS_MODEL=owl-120`, `ANTHROPIC_DEFAULT_HAIKU_MODEL=owl-120`,
  `ANTHROPIC_DEFAULT_SONNET_MODEL=owl-121`. Ein Agent mit `model: sonnet` landet so auf dem 178B.
- **Slot-Sperre pro Modell:** höchstens `CLAU_TEAM_SLOTS_121` (Default 3) gleichzeitige Anfragen an 121, der Rest wartet
  im Proxy (Semaphore + Heartbeat, damit Claude Code nicht abbricht). So erzeugen 5 Ausführer bei 3 Slots keine Fehler.
  Achtung: Mehrere clau-Prozesse teilen sich keine Semaphore. Für die Entscheidung zählt deshalb `/slots`, die Sperre ist nur ein Schutz.
- Kontext-Tabellen (Z. 61/62 usw.) gelten jetzt **pro Modell**. Im Zielbetrieb hat 121 rund 96k je Slot, Auto-Compact muss das kleinere Fenster nehmen.
- Im Log immer das tatsächlich genutzte Zielmodell ausgeben.

## Baustein 2: Agent-Definitionen
clau legt im Team-Modus `.claude/agents/` an (oder hält es global vor):
- `ausfuehrer.md`: `model: sonnet` (→ 121). Setzt einen klar abgegrenzten Teilauftrag um, mit eigenem Dateibereich,
  und meldet geänderte Dateien und den Teststatus zurück.
- `tester.md`: `model: opus` (→ 120). Baut, testet und prüft, ändert keinen Produktivcode.
- `planer.md`: `model: opus` (→ 120). Zerlegt Aufträge und schreibt `PLAN.md`.

## Baustein 3: MCP-Tool `llm_status`
Neuer MCP-Server `llm_status_mcp.py` im Stil von `websearch_mcp.py`, nur lesend:
- Liest `CLAU_TEAM_STATUS_URL` (Default `http://127.0.0.1:8293/slots`). Bei 11.0.0.x-Zugriff die passende Adresse, konfigurierbar.
- Antwort zum Beispiel: `{"modell":"121","slots":3,"frei":1,"belegt":2,"ctx_pro_slot":99328}`.
  Bei Fehler oder Timeout: `{"frei":null,"fehler":"..."}`, und das Modell soll dann so arbeiten, als wäre **ein** Slot frei.

## Baustein 4: Team-Anweisung (System-Prompt-Zusatz bzw. CLAUDE.md-Block)
Regeln für den Teamleiter, sinngemäß:
1. Vor jeder Verteilung `llm_status` abfragen.
2. 0–1 Slots frei: einen Ausführer nach dem anderen (oder selbst sequenziell).
   2 frei: bis zu 2–3 Teilaufträge parallel. 3 frei: bis zu `CLAU_TEAM_MAX_AGENTS` (Default 5) Teilaufträge,
   **parallele Agent-Aufrufe in einer Antwort**.
3. Teilaufträge brauchen getrennte Dateibereiche. Danach den Tester aufrufen, bei Fehlern gezielt nachbessern lassen.
4. Nicht selbst groß programmieren, solange Ausführer frei sind.

## Baustein 5: Fernsteuerungs-Schnittstelle (`clau --api`, Default AUS)
Kleiner HTTP-Dienst (Python stdlib oder FastAPI), gestartet per `clau --api` bzw. `CLAU_API="1"`.
- Konfiguration:
  - `CLAU_API_BIND="127.0.0.1:7010"` (devport setzt später z.B. `0.0.0.0:7010` in der VM)
  - `CLAU_API_TOKEN` (Pflicht, sobald nicht an 127.0.0.1 gebunden; Header `Authorization: Bearer …`)
- **Benannte Sessions/Rollen:** `teamleiter`, `planer`, `tester`. Jede Rolle hat einen festen Ordner und eine Session-ID
  (Zustand unter `~/.config/clau/api/`). Jede Rolle läuft in einer tmux-Session (wie beim Mirror), damit man sie auch interaktiv sieht.
- Endpunkte (Vorschlag):
  - `GET  /status`: alle Rollen mit `zustand` (arbeitet | wartet_auf_eingabe | fertig | beendet), `letzte_aktivitaet`, `session_id`,
    `ordner`, dazu der Flash-Slot-Status
  - `GET  /sessions/<rolle>/verlauf?n=50`: die letzten Nachrichten aus dem Session-JSONL (Text, Tool-Aufrufe gekürzt)
  - `GET  /sessions/<rolle>/bildschirm`: tmux `capture-pane` (wie `/screen` im Mirror)
  - `POST /sessions/<rolle>/nachricht {"text": "..."}`: in die laufende Session tippen (send-keys + Enter).
    Läuft keine Session, einen Turn per `claude -p --resume` starten.
  - `POST /sessions/<rolle>/taste {"taste":"esc|enter|ctrl-c"}`
  - `POST /sessions/<rolle>/start {"ordner": "...", "auftrag": "..."}` und `POST /sessions/<rolle>/stop`
  - `GET  /llm`: Durchreiche von `llm_status`
- **Zustand über Hooks:** Die vorhandene Hook-Mechanik (Notification/Stop/SessionEnd, dazu UserPromptSubmit/PreToolUse für „arbeitet“)
  schreibt zusätzlich eine Statusdatei pro Session. Das funktioniert auch ohne Telegram. Die Telegram-Funktion bleibt unverändert und optional.
- Keine Weboberfläche nötig. devport baut das Panel und spricht nur diese API an.

## Offline-Tauglichkeit (für devport)
- `CLAU_UPDATE_CHECK=0`, `CLAU_WEBSEARCH=0`, kein Telegram. clau darf nirgends hängen, wenn kein Netz da ist.
- `OWL_BASE_URL` und `CLAU_TEAM_STATUS_URL` sind frei setzbar. In der VM zeigen sie auf weitergeleitete Adressen
  (z.B. `http://llm.devport:7077/v1`). Dabei muss man unterscheiden: Geht die VM über QuiteQue oder direkt an das Flash-Tor bzw. 8292?
  Kläre, ob QuiteQue `/v1/chat/completions` für 120/121 ohne Internet ausliefert.
- Installation ohne GitHub: `clau --install` muss mit vorinstalliertem `claude` funktionieren
  (wird im VM-Basisimage einmalig mit Internet gebaut).

## Neue Einstellungen (.clau.conf)
```bash
CLAU_TEAM="0"                 # 1 = Team-Modus (owl-120 Frontend, owl-121 Ausführer)
CLAU_TEAM_LEAD_MODEL="120"
CLAU_TEAM_EXEC_MODEL="121"
CLAU_TEAM_MAX_AGENTS="5"
CLAU_TEAM_SLOTS_121="3"
CLAU_TEAM_STATUS_URL="http://127.0.0.1:8293/slots"
CLAU_API="0"                  # 1 = Fernsteuerung an
CLAU_API_BIND="127.0.0.1:7010"
CLAU_API_TOKEN=""
```
Dazu ein Menüpunkt im interaktiven Menü und eine Anzeige in `clau --current`.

## Akzeptanztests
1. Ohne Team-Modus verhält sich alles wie vorher (Regression: `clau -m owl:120`, Headless, Compact).
2. Mit Team-Modus: Im Proxy-Log stehen Frontend-Anfragen mit `model=120` und Agent-Anfragen mit `model=121`.
3. Bei 3 freien Slots setzt das Frontend für eine teilbare Aufgabe (z.B. „5 unabhängige Module mit Tests“) mehrere
   parallele Agent-Aufrufe ab. Es laufen nie mehr als 3 gleichzeitig gegen 121, die übrigen warten ohne Fehler.
4. Bei einem freien Slot (zwei Slots künstlich belegt) arbeitet es sequenziell.
5. `llm_status` meldet bei nicht erreichbarem Tor einen Fehler, ohne dass die Session hängt.
6. `clau --api`:
   - `curl /status` zeigt die drei Rollen mit korrektem Zustand
   - eine Nachricht per `POST` erscheint in der tmux-Session und wird beantwortet
   - ohne Token gibt es bei Nicht-Localhost-Bind `401`
7. Alles läuft mit gekapptem Internet (nur QuiteQue bzw. Flash erreichbar).

## Risiko
Ob das 27B zuverlässig sinnvoll zerlegt und tatsächlich parallele Agent-Aufrufe in einer Antwort absetzt, lässt sich nur messen.
Falls nicht, gibt es einen Plan B: Das Frontend schreibt nur `PLAN.md` mit Teilaufträgen, und clau verteilt sie selbst
(N × `claude -p` mit `owl-121`, N = freie Slots).
