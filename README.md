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

### Frisches Zielsystem (bei ausgetauschten SSH-Keys)

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

### Modell-Kürzel (interaktiv)

| Taste | Backend | Modell |
|-------|---------|--------|
| 1-4 | Claude | haiku (4.5) / sonnet (5) / opus (5) / fable (5) |
| 5 | QuiteQue | PropellerA-27B (lokal, gratis) |
| 6 | QuiteQue | Qwopus-9B (lokal, gratis) |
| 7-9 | QuiteQue | Grok, QwQ, Qwen3-Coder |
| 0 | QuiteQue | free (Router) |
| a-ee | QuiteQue | Qwen-Flash, DeepSeek V4, Gemini, Claude, GPT-5, Gemini-2.5-Pro |

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
| `CLAU_TIMEOUT_DEFAULT` | Default-Bash-Timeout in ms (Default `1800000` = 30 Min) |
| `CLAU_TIMEOUT_MAX` | Max-Bash-Timeout in ms (Default `7200000` = 120 Min) |

**Beispiel PropellerA (97K Context):**

```bash
CLAU_AUTO_COMPACT_WINDOW="90000"
CLAU_DISABLE_TOOLS="WebFetch,ToolSearch,DesignSync,CronCreate,CronDelete,CronList,ScheduleWakeup,PushNotification,NotebookEdit"
CLAU_DISABLE_ARTIFACT="1"
CLAU_DISABLE_AGENT_VIEW="1"
```

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
die clau beim Session-Start in `.claude/settings.json` einträgt. Ist Telegram nicht
konfiguriert, passiert nichts (stiller No-Op). Token geleakt? → @BotFather `/revoke`.

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
