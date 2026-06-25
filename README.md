# ccclau

Wrapper für Claude Code, Aider und eigene Modelle via QuiteQue.

## Features

- **Modell pro Projektordner** in `.clau.conf` speichern
- **Session-Auswahl** beim Start (Resume-Picker, neue Session, feste Session-ID)
- **Drei Backends**:
  - **Claude Code** (agentisch) — `haiku`, `sonnet`, `opus`
  - **QuiteQue** (lokale/cloud-Modelle) — `owl:<ID>` (z.B. `owl:120` = PropellerA)
  - **Aider** (Editor-Modus) — `aider:<ID>` (workspace-lokales venv, Auto-Install)
- **Pre-Flight-Check**: Session-Größe vs. Modell-Context-Window vor Start
- **Auto-Compact**: Konfigurierbarer Threshold (Prozent oder festes Token-Limit)
- **Token-Optimierung**: Tools deaktivieren, Artifacts/Agent View ausschalten
- **Custom Compact** (`cc_compact.py`): Session-Chunking + Summary via QuiteQue
- **Headless-Modus** für CI/Automation
- **Git-Helfer**: `--git-up` (commit + push), `--git-down` (pull / klonen)
- **Bot-Einstellungen**: Autonomie-Level (0-2), sudo NOPASSWD, Effort-Level

## Installation

```bash
clau --install
```

Symlink nach `~/.local/bin/clau`. Falls `~/.local/bin` nicht im PATH:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

## Verwendung

```bash
clau                          # Interaktiver Start: Session/Modell wählen
clau --new                    # Neue Session
clau --list                   # Resume-Picker
clau -m owl:120               # Mit eigenem Modell starten
clau -m aider:120             # Mit Aider + PropellerA starten
clau --headless -p "Prompt"   # Headless-Modus
clau --current                # Aktuelle Config anzeigen
clau --git-up                 # Commit & Push
clau --git-down               # Pull von origin
```

### Modell-Kürzel (interaktiv)

| Taste | Backend | Modell |
|-------|---------|--------|
| 1-3 | Claude | haiku / sonnet / opus |
| 4 | QuiteQue | PropellerA-27B (lokal, gratis) |
| 5 | QuiteQue | Qwopus-9B (lokal, gratis) |
| 6-9 | QuiteQue | Grok, QwQ, Qwen3-Coder, free |
| a-e | QuiteQue | Qwen-Flash, DeepSeek V4, Gemini, Claude, GPT-5 |
| f-k | Aider | PropellerA, DeepSeek, Gemini Flash, GPT-5, MiniMax |

## Custom Compact

`cc_compact.py` fasst eine lange Session chunked zusammen und schreibt eine neue, resumbare Session-JSONL:

```bash
python3 cc_compact.py [--model 120] [--target-tokens 68000] [--dry-run]
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
```
