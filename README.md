# ccclau

Wrapper für Claude Code und eigene Modelle via QuiteQue (opencode wird mitinstalliert).

## Features

- **Modell pro Projektordner** in `.clau.conf` speichern
- **Session-Auswahl** beim Start (Resume-Picker, neue Session, feste Session-ID)
- **Zwei Backends**:
  - **Claude Code** (agentisch) — `haiku` (4.5), `sonnet` (5), `opus` (5), `fable` (5)
  - **QuiteQue** (lokale/cloud-Modelle) — `owl:<ID>` (z.B. `owl:120` = PropellerA)
- **Standard**: Modell `sonnet` (Sonnet 5), Autonomie-Level `0` (vollautomatisch/durchlaufen)
- **opencode** wird beim `--install` automatisch mitinstalliert (eigenständiges Tool, spricht QuiteQue direkt im OpenAI-Format)
- **Pre-Flight-Check**: Session-Größe vs. Modell-Context-Window vor Start
- **Auto-Compact**: Konfigurierbarer Threshold (Prozent oder festes Token-Limit)
- **Token-Optimierung**: Tools deaktivieren, Artifacts/Agent View ausschalten
- **Custom Compact** (`cc_compact.py`): Session-Chunking + Summary via QuiteQue
- **Headless-Modus** für CI/Automation
- **Git-Helfer**: `--git-up` (commit + push), `--git-down` (pull / klonen)
- **Auto-Update-Check**: prüft beim Start (max. 1×/Tag) gegen GitHub und bietet `--self-update` an
- **Bot-Einstellungen**: Autonomie-Level (0-2), sudo NOPASSWD, Effort-Level
- **Team-Modus** (`CLAU_TEAM=1`): 27B-Teamleiter verteilt an bis zu 5 Ausführer-Agenten auf dem 176B, je nach freien Slots
- **Fernsteuerung** (`clau --api`, Default aus): HTTP-Schnittstelle für Rollen-Sessions (teamleiter/planer/tester)
- **Offline-Betrieb** (`CLAU_OFFLINE=1`): kein Update-Check, keine Websuche, keine Netz-Installation

## Installation

```bash
clau --install
```

`--install` legt den Symlink `~/.local/bin/clau` an **und** installiert fehlende
Abhängigkeiten automatisch: `claude-code` und `opencode` (native Installer, npm-Fallback).
Der Schritt ist idempotent — bereits vorhandene Tools werden übersprungen.

Falls `~/.local/bin` nicht im PATH:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

### Frisches Zielsystem

Einzeiler (klont + installiert, HTTPS — keine SSH-Keys nötig):

```bash
curl -fsSL https://raw.githubusercontent.com/DavidFroe/ccclau/main/install.sh | bash
```

Oder manuell (SSH, bei ausgetauschten SSH-Keys):

```bash
git clone git@github.com:DavidFroe/ccclau.git ~/ccclau
~/ccclau/clau.sh --install
```

## Verwendung

```bash
clau                          # Interaktiver Start: Session/Modell wählen
clau --new                    # Neue Session
clau --list                   # Resume-Picker
clau --resume ID              # Bestimmte Session fortsetzen (ohne ID = Picker)
clau --compact                # Session extern komprimieren (QuiteQue) + fortsetzen
clau -m fable                 # Mit Claude Fable 5 starten
clau -m opus                  # Mit Claude Opus 5 starten
clau -m owl:120               # Mit eigenem Modell (QuiteQue) starten
clau --headless -p "Prompt"   # Headless-Modus
clau --current                # Aktuelle Config anzeigen
clau --git-up                 # Commit & Push
clau --git-down               # Pull von origin
```

### Hauptmenü

```
clau — mario  [owl:120, Engine: claude]
  Letzte Sessions hier:
       Name                         Modell         Zuletzt     Tokens
   1)  Mario-Game mit Python        owl:120        vor 3 Min      54k
   2)  Super Marius leveldesign     qwen3.8-flash  vor 1 Std      36k
   3)  Grafik für Super Marius      opus           gestern        28k

   n) Neue Session                 [Enter]
   s) Weitere Sessions …           (alle hier / alle auf dem System / laufende)
   m) Modell wechseln
   i) Markdown importieren         (neue Session aus Datei)
   f) Fernsteuerung …              (Telegram/Handy, API)
   e) Einstellungen …              (Engine, Qwen-Key, Bot, Team, Update)
```

- **Neue Session** braucht einen Namen. clau gibt die Session-ID vor (`--session-id`) und
  setzt den Namen auch in Claude Code (`--name`), dazu merkt es sich das Modell
  (`.clau-session-meta.json` im Projekt-Bucket).
- **Session wählen** → Fortsetzen / Komprimieren (custom-compact, nur auf Wunsch) / Umbenennen /
  Export / Löschen. Lief die Session zuletzt mit einem anderen Modell als eingestellt, fragt clau:
  mit der Voreinstellung oder mit dem alten Modell fortsetzen.
- Bei alten owl-Sessions zeigt die Tabelle `owl:?` (die Modell-ID steht nicht in der Session-Datei).

### Sessions in tmux (gegen Abstürze)

- **Pro Session:** Session wählen → `6) In tmux fixieren`. Fixierte Sessions starten immer in einer
  eigenen tmux-Sitzung `clau-<id8>`.
- **Für alle neuen Sessions:** Einstellungen → `6) Neue Sessions in tmux` (`CLAU_TMUX="1"`).
- Stürzt das Terminal ab, läuft die Session weiter. `clau` zeigt sie mit `⧉` an; Fortsetzen hängt
  sich an die laufende tmux-Sitzung an, statt sie doppelt zu starten. Loslösen: `Strg-b d`.
- Stürzt Claude Code selbst ab, bleibt das tmux-Fenster offen: Enter setzt die Session fort,
  `q` schließt das Fenster.

### Modellwahl (interaktiv, Taste m)

| Taste | Engine | Modell |
|-------|--------|--------|
| 1-4 | Claude Code + Claude-Abo | haiku (4.5) / sonnet (5) / opus (5.5) / fable (5) |
| 5 / 6 / 7 | Claude Code + owlAPI (Preset) | Q27B `owl:120` / Flash-Next `owl:121` (97k) / Flash-Next `owl:126` (262k) |
| 0 | Claude Code + owlAPI (Preset) | QuiteQue Free-Plan `owl:free` (Router) |
| q1-q10 | Claude Code + Qwen Token Plan | qwen3.8-max (Standard), qwen3.8-flash, … glm-5.2, auto |
| owl-ID (z.B. `350`) | Claude Code + owlAPI | alle übrigen Modelle, live aus `/v1/models`, in Spalten nach Anbieter |
| o | Claude Code + owlAPI | ID direkt eingeben |

Die owlAPI-Liste wird live abgefragt und in `~/.cache/clau/owl_models.json` gecacht (1 h);
daraus kommt auch das Kontext-Fenster für Auto-Compact.

## Qwen Token Plan (Engine `qwenplan`)

Claude Code direkt gegen Alibabas Anthropic-kompatiblen Token-Plan-Endpunkt, ohne Proxy.

```bash
clau --qwen-key                  # Key eintragen/erneuern (verdeckt, wird geprüft; auch Hauptmenü 13)
clau --backend qwenplan          # oder Menü 3 → 5-14, oder: clau -m qwen:glm-5.3
clau --qwen-model                # Modell wählen (Default qwen3.8-max, schnell qwen3.8-flash)
```

- Key-Datei muss `chmod 600` haben, sonst startet clau nicht.
- Vor dem Start ein Mini-Request (`max_tokens=1`): Key, Modell und leeres Kontingent werden klar gemeldet
  (`CLAU_QWENPLAN_PREFLIGHT=0` schaltet das ab).
- Prompt-Cache greift auch sessionübergreifend (`CLAUDE_CODE_ATTRIBUTION_HEADER=0`).
- Laut AGB **nur interaktiv**: Headless, MCP/QuiteQue und Telegram-Hooks sind für diese Engine gesperrt.

## Custom Compact

Für Sessions, die nicht mehr in den Kontext eines lokalen Modells passen: `cc_compact.py`
fasst die aktuelle Session chunked über QuiteQue zusammen und schreibt eine neue, kleinere,
resumbare Session-JSONL (Kopie mit Summary statt Vollverlauf).

Am einfachsten über clau (fragt danach, ob direkt fortgesetzt werden soll):

```bash
clau --compact                # nutzt owl-Modell falls gesetzt, sonst 120 (PropellerA)
```

Oder direkt:

```bash
python3 cc_compact.py [--model 120] [--target-tokens 68000] [--dry-run]
clau --resume <neue-id>       # danach die komprimierte Session fortsetzen
```

## Token-Optimierung

Per-Projekt-Konfiguration in `.clau.conf` um Token-Verbrauch zu reduzieren:

```bash
# Auto-Compact: festes Token-Limit (leer = prozent-basiert)
CLAU_AUTO_COMPACT_WINDOW=""
# Auto-Compact: Prozent des Context-Window (Default 80)
CLAU_AUTO_COMPACT_PCT="80"
# Tools aus System-Prompt entfernen (kommagetrennt)
CLAU_DISABLE_TOOLS="WebFetch,Agent,CronCreate"
# Token-Fresser deaktivieren
CLAU_DISABLE_ARTIFACT="1"
CLAU_DISABLE_AGENT_VIEW="1"
```

| Variable | Wirkung |
|----------|---------|
| `CLAU_AUTO_COMPACT_WINDOW` | Festes Token-Limit (z.B. `90000` für PropellerA 97K) |
| `CLAU_AUTO_COMPACT_PCT` | Prozent-basiert (z.B. `90` = 90% des Context-Window) |
| `CLAU_DISABLE_TOOLS` | Tools aus System-Prompt entfernen (~25K Token sparen) |
| `CLAU_DISABLE_ARTIFACT` | Artifacts deaktivieren (`1` = an) |
| `CLAU_DISABLE_AGENT_VIEW` | Background Agent Views deaktivieren (`1` = an) |
| `CLAU_WEBSEARCH` | Lokale Websuche als MCP-Tool (`1` = an, Default; kostet ~300 Token) |
| `CLAU_TIMEOUT_DEFAULT` | Default-Bash-Timeout in ms (Default `1800000` = 30 Min) |
| `CLAU_TIMEOUT_MAX` | Max-Bash-Timeout in ms (Default `7200000` = 120 Min) |

**Beispiel PropellerA (97K Context):**

```bash
CLAU_AUTO_COMPACT_WINDOW="90000"
CLAU_DISABLE_TOOLS="WebFetch,ToolSearch,DesignSync,CronCreate,CronDelete,CronList,ScheduleWakeup,PushNotification,NotebookEdit"
CLAU_DISABLE_ARTIFACT="1"
CLAU_DISABLE_AGENT_VIEW="1"
```

## Websuche

Über owlAPI gibt es das serverseitige `WebSearch` der Anthropic-API nicht — ein
lokales Modell käme sonst gar nicht ins Netz. `websearch_mcp.py` reicht deshalb
QuiteQues eigene Such-Pipeline (SearXNG + Volltext + Rerank + Citation- und
Halluzinations-Check) als MCP-Tool durch. Bei owl-Modellen ist es per Default an:

```bash
CLAU_WEBSEARCH="1"    # in .clau.conf, "0" schaltet es ab
```

Das Tool heißt in der Session `mcp__websearch__websearch` und nimmt
`query`, `depth` (`speed` ~15s / `balanced` ~25s / `quality` ~40s) und
`max_sources`. Die Antwort enthält nur, was in den Quellen steht, plus die
Quellen-URLs.

**Nicht** über `/v1/chat/completions` mit `model=websearch-*` gehen: das ist der
Chat-Pfad, der die Query nie an die Suche weiterreicht — das Modell antwortet
dann blind aus dem Trainingswissen und erfindet Quellen dazu. Der richtige
Endpoint ist `POST /websearch`.

## Team-Modus

Ein Teamleiter (Claude Code) zerlegt Aufgaben und verteilt sie an Subagenten. Drei Sets
(Einstellungen → Team-Modus, oder `CLAU_TEAM_SET` in `.clau.conf`):

| Set | Teamleiter | Subagenten |
|---|---|---|
| `lokal` (Standard) | owl:120 (Claude Code über owl_proxy) | owl:121 als pi-Prozesse |
| `qwen` | qwen3.8-max (Claude Code über den Token Plan) | qwen3.8-flash als pi-Prozesse |
| `claude` | Opus (Claude-Abo) | Sonnet als Claude-Code-Agenten |

```bash
CLAU_TEAM="1"
CLAU_TEAM_SET="qwen"          # lokal | qwen | claude
CLAU_TEAM_QWEN_LEAD="qwen3.8-max"   CLAU_TEAM_QWEN_EXEC="qwen3.8-flash"
CLAU_TEAM_CLAUDE_LEAD="opus"        CLAU_TEAM_CLAUDE_EXEC="sonnet"
```

Beim Set `claude` laufen die Subagenten bewusst als Claude-Code-Agenten und nicht als pi
(pi mit dem Claude-Abo-Login wäre eine Grauzone). `llm_status` (Slot-Abfrage) gibt es nur
beim Set `lokal`; die anderen verteilen bis `CLAU_TEAM_MAX_AGENTS`.

### Set `lokal` im Detail

Ein kleines Frontend-Modell (Teamleiter, Default `owl:120` = Qwen 27B) zerlegt Aufgaben
und verteilt sie an Ausführer-Subagenten auf dem großen Modell (Default `owl:121` =
Qwen3.8-Flash-Next 176B). Wie viel parallel läuft, richtet sich nach den freien Slots des 176B.

```bash
CLAU_TEAM="1"                 # in .clau.conf oder als Umgebungsvariable
CLAU_TEAM_LEAD_MODEL="120"    # Teamleiter
CLAU_TEAM_EXEC_MODEL="121"    # Ausführer (Agenten mit model: sonnet)
CLAU_TEAM_MAX_AGENTS="5"      # max. parallele Ausführer bei 3 freien Slots
CLAU_TEAM_SLOTS_121="3"       # max. gleichzeitige Anfragen an 121, der Rest wartet im Proxy
CLAU_TEAM_STATUS_URL="http://127.0.0.1:8293/slots"   # Slot-Status (Flash-Tor)
```

### Subagenten als pi-Prozesse (Standard, wenn [pi](https://pi.dev) installiert ist)

Statt Claude-Code-Subagenten (~36k Tokens System-Prompt + Tool-Schema **pro Anfrage**) startet
der Teamleiter schlanke `pi -p`-Prozesse (~1,7k Tokens). Gemessen: erste Anfrage 1.704 statt
~36.000 Tokens.

- **MCP-Tool `pi_team`** (`pi_team_mcp.py`): `auftrag_starten(rolle, auftrag)` startet im
  Hintergrund und kommt sofort mit einer ID zurück, `auftraege_abwarten(ids)` liefert die Berichte.
  So laufen mehrere Ausführer echt parallel (Claude Code würde schreibende MCP-Tools sonst
  nacheinander ausführen), und der Teamleiter muss keine parallelen Aufrufe in eine Antwort packen.
- **Rollen** wie oben (`team/agents/*.md` als Prompt): `ausfuehrer` → 121, `tester`/`planer` → 120.
  Gleichzeitig höchstens `CLAU_TEAM_SLOTS_121` Ausführer, der Rest wartet im MCP-Server.
- **pi-Konfiguration** erzeugt clau in `~/.cache/clau/pi-agent` (Provider `owl` = QuiteQue mit den
  Pflicht-Headern); die persönliche `~/.pi` bleibt unberührt. Volle Ausgaben je Auftrag:
  `~/.cache/clau/team/<zeit>-<pid>-<id>.log`.
- Umschalten: `CLAU_TEAM_SUBAGENTS="pi"` (Default) oder `"claude"` (alte Agent-Variante),
  auch über Menü 12 → 8. Ohne installiertes pi fällt clau automatisch auf `claude` zurück.

Einschalten auch über Menüpunkt 12 im interaktiven Menü; `clau --current` zeigt den Zustand.
Mit `CLAU_TEAM=1` läuft die Session immer über den Teamleiter, egal welches `CLAU_MODEL`
gesetzt ist (`-m` überschreibt weiterhin).

So funktioniert es:

- **Routing im owl_proxy:** Fordert Claude Code das Modell `owl-<ID>` an, geht die Anfrage an
  QuiteQue-Modell `<ID>`; alles andere wie bisher an das Session-Modell. clau setzt im Team-Modus
  `--model owl-120` und `ANTHROPIC_DEFAULT_SONNET_MODEL=owl-121` (Opus/Haiku → owl-120).
  Im Proxy-Log steht pro Anfrage `model=120` bzw. `model=121 (angefragt: owl-121)`.
- **Slot-Sperre:** Höchstens `CLAU_TEAM_SLOTS_121` Anfragen gleichzeitig an 121; überzählige warten
  im Proxy (mit SSE-Pings, Claude Code bricht nicht ab). Die Sperre gilt pro clau-Prozess.
- **Agenten** (`team/agents/*.md`, per `--agents` übergeben, nichts landet im Projektordner):
  `ausfuehrer` (model: sonnet → 121, eigener Dateibereich, fester Bericht), `tester` und
  `planer` (model: opus → 120).
- **Tool `llm_status`** (`llm_status_mcp.py`): liefert z.B.
  `{"modell":"121","slots":3,"frei":1,"belegt":2,"ctx_pro_slot":99328,"empfehlung_parallel":1}`;
  bei nicht erreichbarem Tor nach 3 s `{"frei":null,"fehler":"..."}`. Direkt testen:
  `python3 llm_status_mcp.py --once`.
- **Team-Anweisung** (`team/TEAM_ANWEISUNG.md`, als System-Prompt-Zusatz): vor jeder Verteilung
  `llm_status`; 0–1 frei → nacheinander, 2 frei → bis 2, ab 3 frei → bis `CLAU_TEAM_MAX_AGENTS`
  parallele Agent-Aufrufe **in einer Antwort**; danach `tester`, gezielt nachbessern.
- **Auto-Compact** richtet sich nach dem kleineren Kontextfenster von Teamleiter und Ausführer.

Headless im Team-Modus mit `--dangerously-skip-permissions` starten: ohne das Flag schickt Claude
Code für jeden Tool-Schritt eine Klassifikator-Anfrage (~40k Tokens) an das sonnet-Alias, also an
das Ausführer-Modell, und belegt dessen Slots.

```bash
CLAU_TEAM=1 clau --headless --dangerously-skip-permissions -p "Baue 5 Module mit Tests ..."
```

Hinweis zu `owl:126`: Das ist dasselbe 176B hinter demselben Flash-Tor, nur als 262k-Einzelslot-
Variante. Eine Anfrage an 126 lässt das Tor in diese Variante umladen – parallele Ausführer
gibt es dann nicht mehr. Für den Team-Modus deshalb bei 121 bleiben.

## Fernsteuerung (`clau --api`)

HTTP-Schnittstelle, um Rollen-Sessions von außen zu sehen und anzusprechen. **Standardmäßig aus.**

```bash
clau --api                         # Vordergrund (systemd/devport), Rollen-Ordner = aktueller Ordner
CLAU_API="1"                       # oder: beim interaktiven clau-Start im Hintergrund starten
clau --api-stop                    # Hintergrund-Dienst beenden
CLAU_API_BIND="127.0.0.1:7010"
CLAU_API_TOKEN=""                  # Pflicht bei nicht-lokalem Bind (sonst startet der Dienst nicht)
```

Drei feste Rollen: `teamleiter` (Team-Modus), `planer`, `tester`. Jede läuft als interaktive
clau-Session in tmux (`tmux attach -t clau-api-teamleiter`). Zustand unter `~/.config/clau/api/`
(`rollen.json` mit Ordner/Session-ID/Modell, `status/<session>.json` aus den Hooks, `logs/`).
Die Status-Hooks bekommt nur die jeweilige Rollen-Session per `--settings`; globale Settings und
Telegram bleiben unberührt. Jede Rolle hat ein eigenes Proxy-Log (`owl_proxy-<rolle>.log`).

| Methode | Pfad | Zweck |
|---|---|---|
| GET  | `/status` | Rollen mit `zustand` (arbeitet / wartet_auf_eingabe / fertig / beendet), `letzte_aktivitaet`, `session_id`, `ordner` + Slot-Status |
| GET  | `/llm` | `llm_status` |
| GET  | `/sessions/<rolle>/verlauf?n=50` | letzte Nachrichten aus dem Session-JSONL (Tool-Aufrufe gekürzt) |
| GET  | `/sessions/<rolle>/bildschirm` | tmux `capture-pane` |
| POST | `/sessions/<rolle>/start` | `{"ordner": "...", "auftrag": "...", "modell": "owl:120"}` – alles optional, setzt vorhandene Session fort |
| POST | `/sessions/<rolle>/nachricht` | `{"text": "..."}` – tippt in die laufende Session; läuft keine, ein Headless-Turn |
| POST | `/sessions/<rolle>/taste` | `{"taste": "esc"}` (esc, enter, ctrl-c, tab, shift-tab, up, down, left, right, y, n, 1–3) |
| POST | `/sessions/<rolle>/stop` | Session beenden (Doppel-Strg-C, nach 8 s hart) |

```bash
curl -s localhost:7010/status
curl -s -XPOST localhost:7010/sessions/planer/start -d '{"modell":"owl:120","auftrag":"Lies README.md und schreibe PLAN.md"}'
curl -s -XPOST localhost:7010/sessions/planer/nachricht -d '{"text":"Fasse PLAN.md in 3 Sätzen zusammen"}'
curl -s -H "Authorization: Bearer $TOKEN" http://vm:7010/status     # mit Token
```

## Offline-Betrieb

Für Umgebungen ohne Internet (devport-VMs: nur Gitea, apt-Cache, lokale LLMs):

```bash
CLAU_OFFLINE="1"    # kein Update-Check, keine Websuche, --install installiert nichts aus dem Netz,
                    # Claude Code ohne Telemetrie/Auto-Update (CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)
OWL_BASE_URL / CLAU_TEAM_STATUS_URL   # auf die erreichbaren Adressen zeigen lassen
CLAU_OWL_ROUTES="120=http://host:8292/v1,121=http://host:8293/v1#qwen3.8-flash-next"
                    # optional: Modelle direkt an die llama-server statt über QuiteQue
```

`clau --install` funktioniert mit vorinstalliertem `claude` (Symlink; fehlende Tools werden mit
`CLAU_OFFLINE=1` nur gemeldet). Telegram ist ohnehin nur aktiv, wenn es eingerichtet ist.
Die Team- und API-Einstellungen sowie `CLAU_OFFLINE`, `CLAU_UPDATE_CHECK`, `CLAU_WEBSEARCH` und
`CLAU_OWL_ROUTES` dürfen als Umgebungsvariablen kommen und schlagen dann die `.clau.conf`.

## Timeout-Konfiguration

Problem: Claude Code killt den Proxy nach ~2 Minuten, aber langsame Modelle (PropellerA etc.) brauchen länger für die Inferenz. Das führt zu „Modell hat nicht geantwortet"-Fehlern obwohl die Inferenz auf dem Server noch läuft.

Lösung: Timeout über `.clau.conf` erhöhen:

```bash
# Default: 30 Min, Maximum: 120 Min
CLAU_TIMEOUT_DEFAULT="1800000"
CLAU_TIMEOUT_MAX="7200000"
```

Dies setzt `BASH_DEFAULT_TIMEOUT_MS` und `BASH_MAX_TIMEOUT_MS` für Claude Code und erhöht das owl_proxy Timeout von 120s auf 600s.

| Variable | Claude-Code-Var | Default | Wirkung |
|----------|----------------|---------|---------|
| `CLAU_TIMEOUT_DEFAULT` | `BASH_DEFAULT_TIMEOUT_MS` | `1800000` (30 Min) | Standard-Timeout für Bash-Befehle |
| `CLAU_TIMEOUT_MAX` | `BASH_MAX_TIMEOUT_MS` | `7200000` (120 Min) | Maximales erlaubtes Timeout |

## Telegram-Benachrichtigung (Handy)

clau kann per Telegram-Bot aufs Handy melden, wenn eine Session eine Rückfrage hat,
fertig ist oder endet — ideal für autonome „durchlaufen"-Läufe (Autonomie 0).

**Modell: ein Bot, eine Supergruppe mit „Themen" (Topics), ein Topic pro Session.**
clau legt das Topic beim ersten Event automatisch an, meldet dort den Status und
schließt es am Session-Ende. So bleiben auch 1000 parallele Sessions sauber getrennt
(jedes Topic ist selbstbeschriftet mit `📁 <projekt> · <session-id>`).

**Einmal-Setup:**

1. In Telegram bei **@BotFather** → `/newbot` → Token holen.
2. Gruppe anlegen, in den Einstellungen **„Themen" aktivieren**, Bot als **Admin**
   hinzufügen (Rechte: Nachrichten + Themen verwalten), eine Nachricht schreiben.
3. Token in `~/.config/clau/telegram.conf` eintragen (lokal, `chmod 600`, **nicht** im Repo).
4. `clau --tg-setup` → ermittelt die Gruppen-ID.  `clau --tg-test` → Testnachricht.

```bash
# ~/.config/clau/telegram.conf
CLAU_TG_ENABLED="1"
CLAU_TG_BOT_TOKEN="123456:ABC-..."
CLAU_TG_GROUP_ID="-100..."                       # via clau --tg-setup
CLAU_TG_EVENTS="notification,stop,sessionend"    # welche Events melden
```

Die Benachrichtigung läuft über Claude-Code-Hooks (`Notification`/`Stop`/`SessionEnd`),
die clau in die **globalen** User-Settings `~/.claude/settings.json` einträgt. Global
statt pro Projekt, damit es auch in Ordnern ohne Schreibrecht funktioniert (z.B. in
einem fremden Home) — und damit jede Claude-Session meldet, nicht nur die per clau
gestartete. Wieder loswerden: `clau --tg-hooks-off`. Ist Telegram nicht konfiguriert,
passiert nichts (stiller No-Op). Token geleakt? → @BotFather `/revoke`.

**Ordner ohne Schreibrecht:** Kann clau die `.clau.conf` im Projektordner nicht
anlegen, merkt es die Einstellungen stattdessen unter
`~/.config/clau/dirs/<pfad>.conf` — Modell/Autonomie bleiben also auch dort erhalten.

### LIVE-Session: Bildschirm und Telegram parallel (`clau --mirror`)

Die eine Session, gleichzeitig an beiden Enden — kein Hin- und Herschalten:

```bash
clau --mirror        # startet die Session in tmux und hängt dich dran
#   Strg-b d         → loslösen (Session läuft weiter)
#   clau --mirror    → wieder dran (im gleichen Ordner)
```

- **Ausgabe** geht auf den Bildschirm **und** ins Telegram-Topic `🖥️ <projekt> · live`
  (ANSI/Spinner werden gefiltert, Zeilen gebündelt alle ~4s gesendet).
- **Eingabe** funktioniert von beiden Seiten: was du im Topic schreibst, wird direkt
  in die laufende Session getippt — als hättest du es auf der Tastatur eingegeben.

Extra-Befehle im Live-Topic:

| Befehl | Wirkung |
|--------|---------|
| *(Text)* | wird in die Session getippt + Enter |
| `/screen` | aktuellen Bildschirminhalt als Text schicken |
| `/enter`, `/esc`, `/ctrl c` | einzelne Tasten senden |
| `/stop` | Live-Session beenden |

Braucht `tmux` (wird von `clau --install` mitinstalliert). Nur für Claude-Modelle,
nicht für `owl:*`.

**Mirror vs. Bot:** Der Mirror spiegelt eine *interaktive* Session (du siehst das
echte TUI-Geschehen). Der Bot-Modus unten arbeitet auftragsweise (saubere
Frage/Antwort-Paare, kein tmux nötig). Beides lässt sich parallel nutzen.

### Vom Handy entwickeln (`clau --tg-bot`)

Ein Dauer-Poller macht aus jeder Telegram-Nachricht einen Claude-Code-Turn im
Projektordner auf dem Server — die Antwort kommt zurück ins Topic. So entwickelst du
vom Handy: im Topic `/cd <pfad>` setzen, dann einfach Anweisungen tippen. Der Kontext
(Session) bleibt pro Topic erhalten.

```bash
# 1) Sicherheit: nur DEINE Telegram-ID darf Befehle ausführen (Bot kann Code laufen lassen!)
clau --tg-whoami                 # zeigt deine User-ID
#   → CLAU_TG_ALLOWED_USER="<id>" in ~/.config/clau/telegram.conf eintragen

# 2) Bot starten (am besten in tmux, damit er weiterläuft):
tmux new -d -s clau-bot 'clau --tg-bot'
```

**Der Bot hat ein eigenes Hirn (Concierge).** Du musst dir keine Befehle merken —
schreib einfach normal. Ein kleines Modell auf der vorhandenen QuiteQue-Infrastruktur
(Default `gemma-12b-chat`, lokal & DE-optimiert) plaudert mit dir, listet Projekte,
wechselt Ordner, holt deine PC-Session — und reicht **echte Coding-Aufträge an den
großen Claude weiter**. So kostet das Navigieren nichts.

```
Du:  „was hab ich für projekte“      → Concierge antwortet direkt
Du:  „lass uns im ccclau weiter“     → wechselt Ordner / holt PC-Session
Du:  „füge Backups in die README“    → geht an Claude Code (echte Arbeit)
```

Konfigurierbar (auch im Menü unter *Telegram → Concierge-Modell*):

```bash
CLAU_TG_BRAIN="1"                      # 0 = aus, dann geht alles direkt an Claude
CLAU_TG_BRAIN_MODEL="gemma-12b-chat"   # jede QuiteQue-Modell-ID, z.B. free, claude-opus-5
CLAU_TG_PROJECT_ROOT="$HOME"           # wo nach Projekten gesucht wird
```

Bot-Befehle im Topic:

| Befehl | Wirkung |
|--------|---------|
| `/cd <pfad>` | Projektordner für dieses Topic setzen (neue Session) |
| `/weiter` | die zuletzt am PC gelaufene Session in diesem Ordner **übernehmen** |
| `/pwd` | aktuellen Ordner zeigen |
| `/new` | Session zurücksetzen (frischer Kontext) |
| `/projekte` | gefundene Projektordner auflisten |
| `/opus <text>` | direkt an Claude (Concierge überspringen) |
| *(Text)* | geht an den Concierge — der antwortet oder reicht an Claude weiter |

**Am PC anfangen, auf dem Handy weiter:** clau merkt sich bei jeder PC-Session
(über die Hooks) die Session-ID pro Ordner. Unterwegs im Topic `/cd <ordner>` →
`/weiter` → der Bot setzt **genau deine PC-Unterhaltung** fort (via `claude --resume`).
Wichtig: die PC-Session vorher beenden (nicht zwei Prozesse gleichzeitig auf einer
Session).

Als systemd-User-Service (läuft nach Reboot automatisch):

```ini
# ~/.config/systemd/user/clau-bot.service
[Unit]
Description=clau Telegram Bot
[Service]
ExecStart=%h/.local/bin/clau --tg-bot
Restart=always
[Install]
WantedBy=default.target
```
```bash
systemctl --user enable --now clau-bot   # (loginctl enable-linger $USER für Start ohne Login)
```

⚠️ Der Bot läuft mit `--dangerously-skip-permissions` (autonom). Setze unbedingt
`CLAU_TG_ALLOWED_USER`, sonst könnte jeder in der Gruppe Code auf dem Server ausführen.

## Auto-Update-Check

Beim interaktiven Start prüft clau (throttled, max. 1×/Tag) per `git fetch`, ob
`origin/<branch>` neuer ist. Falls ja, wird ein Hinweis angezeigt und optional direkt
`--self-update` ausgeführt. Offline / ohne Netz / ohne Zugriff wird der Check stumm
übersprungen (5s-Timeout, keine SSH-/Passwort-Prompts). Headless-Läufe prüfen nie.

```bash
CLAU_UPDATE_CHECK="1"              # 0 = ausschalten
CLAU_UPDATE_CHECK_INTERVAL="86400" # Prüf-Intervall in Sekunden (Default 1 Tag)
```

Zeitstempel des letzten Checks: `${XDG_CACHE_HOME:-~/.cache}/clau/last_update_check`.
