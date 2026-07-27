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
