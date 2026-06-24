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
- **Auto-Compact**: Threshold auf 80% des echten Context-Windows
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
