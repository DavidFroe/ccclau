#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=".clau.conf"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_NAME="clau"
SUDO_FILE="/etc/sudoers.d/clau-$(whoami)"

sudo_is_enabled() {
  [[ -f "$SUDO_FILE" ]]
}

toggle_sudo() {
  local user; user="$(whoami)"
  if sudo_is_enabled; then
    sudo rm -f "$SUDO_FILE"
    echo "sudo: AUS — ${SUDO_FILE} entfernt"
  else
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$user" | sudo tee "$SUDO_FILE" > /dev/null
    sudo chmod 440 "$SUDO_FILE"
    if sudo visudo -c &>/dev/null; then
      echo "sudo: AN — ${user} hat jetzt NOPASSWD sudo"
    else
      sudo rm -f "$SUDO_FILE" 2>/dev/null || true
      echo "Fehler: sudoers ungültig, rückgängig gemacht" >&2
    fi
  fi
}

# owlAPI-Proxy: claude CLI spricht Anthropic-Format, Proxy übersetzt → QuiteQue
# QuiteQue hier auf 11.0.0.13 (diese Stack) — User "opencode" für vLLM/Claude-Backends
OWL_PROXY_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/owl_proxy.py"
OWL_BASE_URL="http://11.0.0.13:7077"
QQ_USER="opencode"

is_owl_model() {
  [[ "${1:-}" == owl:* ]]
}

owl_model_id() {
  echo "${1#owl:}"
}

# Kontext-Window pro owl-Modell (für CLAUDE_CODE_MAX_CONTEXT_TOKENS).
# Auto-generiert aus QuiteQue /v1/models. Verhindert dass claude-CLI glaubt
# das Modell hätte 200k, obwohl das echte Backend-Modell nur 97k (PropellerA) hat.
declare -gA OWL_CONTEXT_WINDOWS=(
  ["20"]="200000"   # Claude Haiku 4.5
  ["50"]="32000"    # SkinnyJoe T79: Qwen3 4B Instruct (CPU)
  ["51"]="16000"    # SkinnyJoe T77: Dolphin3 3B (CPU)
  ["52"]="8000"     # SkinnyJoe T78: L3.1 Dark-Planet 8B (CPU, RP)
  ["53"]="4000"     # SkinnyJoe W4: Whisper-large-v3 (ASR)
  ["54"]="0"        # SkinnyJoe B3: SD-Turbo (Image-Gen, CPU)
  ["90"]="1048000"  # GPT-5.1
  ["120"]="97000"   # PropellerA: Qwen3.6 27B (Tools+Vision+Thinking)
  ["317"]="1048000" # OpenRouter Owl Alpha (1M ctx, Agentic, FREE)
  ["350"]="1048000" # DeepSeek V4 Pro (1M ctx, Reasoning)
  ["351"]="1048000" # MiniMax M3 (1M ctx)
  ["360"]="262000"  # MoonshotAI Kimi K2.7 Code (262k)
  ["361"]="1000000" # Qwen3.7 Max (1M ctx)
  ["362"]="1000000" # Qwen3.7 Plus (1M ctx)
  ["367"]="202000"  # Z.ai GLM 4.7 Flash (203k)
  ["368"]="202000"  # Z.ai GLM 4.7 (203k)
  ["379"]="1048000" # DeepSeek V4 Flash (1M ctx, MoE)
  ["380"]="1048000" # Xiaomi MiMo V2.5 (1M ctx, Omnimodal)
  ["381"]="1000000" # Qwen3 Coder Plus (1M ctx, 480B A35B Coding-Agent)
  ["382"]="1048000" # Z.ai GLM 5.2 (1M ctx, Reasoning)
  ["383"]="128000"  # Amazon Nova Micro 1.0 (128k)
  ["384"]="1048000" # Qwen3 Coder 480B A35B (1M ctx)
  ["385"]="262000"  # Qwen3.6 27B (262k, Vision)
  ["386"]="1048000" # Meta Llama 4 Maverick (1M ctx, Vision)
)

owl_context_window() {
  local owl_id="${1:-}"
  local cw="${OWL_CONTEXT_WINDOWS[$owl_id]:-}"
  if [[ -n "$cw" && "$cw" -gt 0 ]]; then
    echo "$cw"
  fi
}

# ── Pre-Flight: Session-Größe schätzen (vor claude-CLI Start) ────────────────
# claude-CLI speichert Sessions in ~/.claude/projects/<hash>/<session-id>.jsonl
# wobei hash = pwd mit "/" ersetzt durch "-". Wir lesen die letzte usage-Zeile
# und berechnen die geschätzte aktuelle Kontext-Größe. Wenn die Session zu groß
# für das gewählte Modell ist, lehnen wir ab oder warnen.

_claude_projects_dir() {
  echo "${HOME}/.claude/projects"
}

_project_hash_for() {
  local dir="${1:-$PWD}"
  echo "${dir//\//-}"
}

_latest_session_file() {
  local dir="${1:-$PWD}"
  local ph; ph="$(_project_hash_for "$dir")"
  local proj_dir; proj_dir="$(_claude_projects_dir)/${ph}"
  [[ -d "$proj_dir" ]] || return 1
  # neueste .jsonl nach mtime
  ls -1t "$proj_dir"/*.jsonl 2>/dev/null | head -1
}

_estimate_session_tokens() {
  # Liest die letzte usage-Zeile und gibt geschätzte Kontext-Tokens zurück
  # (= input_tokens + cache_read_input_tokens + cache_creation_input_tokens)
  local sf="${1:-}"
  [[ -f "$sf" ]] || { echo "0"; return 1; }
  # Wir nehmen die letzte Zeile mit non-empty usage
  python3 - "$sf" <<'PYEOF' 2>/dev/null || echo "0"
import json, sys
sf = sys.argv[1]
last_in = 0
last_cache_read = 0
last_cache_creation = 0
found = False
with open(sf) as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        msg = d.get('message', {})
        u = msg.get('usage') or {}
        if u:
            last_in = u.get('input_tokens', 0) or 0
            last_cache_read = u.get('cache_read_input_tokens', 0) or 0
            last_cache_creation = u.get('cache_creation_input_tokens', 0) or 0
            found = True
if not found:
    print("0")
else:
    print(last_in + last_cache_read + last_cache_creation)
PYEOF
}

_pre_flight_check() {
  local owl_id="$1"
  local cw; cw="$(owl_context_window "$owl_id")"
  [[ -n "$cw" && "$cw" -gt 0 ]] || return 0  # kein Check möglich (z.B. Claude direkt)

  local sf; sf="$(_latest_session_file 2>/dev/null)"
  [[ -n "$sf" && -f "$sf" ]] || { echo "✓ Pre-Flight: keine Session gefunden, starte neu"; return 0; }

  local tokens; tokens="$(_estimate_session_tokens "$sf")"
  tokens="${tokens:-0}"
  [[ "$tokens" -eq 0 ]] && { echo "✓ Pre-Flight: leere Session, starte"; return 0; }

  local pct=$(( tokens * 100 / cw ))
  local sf_name; sf_name="$(basename "$sf")"

  if [[ "$tokens" -gt "$cw" ]]; then
    cat >&2 <<EOF
⚠ PRE-FLIGHT FEHLGESCHLAGEN — Session überschreitet Modell-Context-Window

  Modell:      owl:$owl_id
  Kontext:     $cw Tokens
  Session:     $tokens Tokens ($pct%)
  Session-File: $sf

  Diese Session ist zu groß für das gewählte Modell. claude-CLI wird
  beim Start einen API-Error geben, weil das Backend den Input nicht
  verarbeiten kann.

  Empfehlung (eine davon):
    1) Größeres Modell wählen, z.B.:
         clau -m owl:351    (MiniMax M3, 1M ctx)
         clau -m owl:361    (Qwen3.7 Max, 1M ctx)
         clau -m owl:379    (DeepSeek V4 Flash, 1M ctx)
    2) Neue Session starten (alte verwerfen):
         clau --new -m owl:$owl_id
    3) Erst /compact in alter Session, dann hier weitermachen.

  Override mit --force-context, wenn du es trotzdem versuchen willst.
EOF
    return 1
  fi

  if [[ "$pct" -gt 80 ]]; then
    cat >&2 <<EOF
⚠ Pre-Flight: Session hat $tokens Tokens ($pct% von $cw Kontext-Window)
  Modell owl:$owl_id hat nur $cw Kontext-Tokens.
  Empfehlung: /compact aufrufen oder größeres Modell wählen.
EOF
  else
    echo "✓ Pre-Flight: Session $tokens Tokens ($pct% von $cw) — passt zu owl:$owl_id"
  fi
  return 0
}

# Freien TCP-Port finden
_free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}

# Proxy starten: port + pid in Temp-Datei, gibt Port zurück
_OWL_PID_FILE="/tmp/.clau_owl_proxy_$$.pid"

_start_owl_proxy() {
  local owl_id="$1"
  local port
  port="$(_free_port)"
  OWL_PROXY_PORT="$port" OWL_MODEL="$owl_id" OWL_BASE_URL="${OWL_BASE_URL}/v1" OWL_PROXY_USER="$QQ_USER" \
    python3 "$OWL_PROXY_SCRIPT" "$port" >/dev/null 2>&1 &
  echo "$!" > "$_OWL_PID_FILE"
  echo "$port"
}

_kill_owl_proxy() {
  if [[ -f "$_OWL_PID_FILE" ]]; then
    local pid; pid="$(cat "$_OWL_PID_FILE" 2>/dev/null || true)"
    rm -f "$_OWL_PID_FILE"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  fi
  # Claude CLI aktiviert Mouse-Tracking — bei Exit sauber deaktivieren
  printf '\e[?1000l\e[?1002l\e[?1003l\e[?1004l\e[?1006l\e[?1015l\e[?1016l' > /dev/tty 2>/dev/null || true
}

# ── Aider-Integration ─────────────────────────────────────────────────────────

is_aider_model() {
  [[ "${1:-}" == aider:* ]]
}

aider_model_id() {
  echo "${1#aider:}"
}

_find_aider() {
  # Nur workspace-lokal — kein globales Fallback
  [[ -x "./aider/bin/aider" ]] && { echo "./aider/bin/aider"; return 0; }
  return 1
}

_install_aider_local() {
  echo "Aider: kein Binary gefunden — installiere lokal in ${PWD}/aider/ ..." >&2
  if ! command -v python3 &>/dev/null; then
    echo "Fehler: python3 nicht gefunden" >&2; return 1
  fi
  python3 -m venv "./aider" >&2
  "./aider/bin/pip" install --upgrade aider-chat >&2
  # aider/ in .gitignore eintragen wenn noch nicht drin
  if [[ -f ".gitignore" ]] && ! grep -qE "^/?aider/?$" ".gitignore" 2>/dev/null; then
    echo "/aider" >> ".gitignore"
  fi
  echo "./aider/bin/aider"
}

run_aider() {
  local owl_id="$1"
  shift
  local aider_bin
  if ! aider_bin="$(_find_aider)"; then
    aider_bin="$(_install_aider_local)" || exit 1
  fi
  # Aider braucht git-getrackte Dateien für die Repo-Map
  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    local tracked; tracked=$(git ls-files | wc -l)
    if [[ "$tracked" -eq 0 ]]; then
      echo "Aider: git repo hat 0 getrackte Dateien — führe 'git add .' aus..."
      git add .
    fi
  fi
  local extra=()
  [[ "${INTERACTION_LEVEL:-2}" -eq 0 ]] && extra+=(--yes)
  "$aider_bin" \
    --openai-api-base "${OWL_BASE_URL}/v1" \
    --openai-api-key dummy \
    --model "openai/${owl_id}" \
    --no-show-model-warnings \
    --edit-format diff \
    "${extra[@]}" "$@"
}

run_aider_headless() {
  local owl_id="$1"
  local prompt="$2"
  local aider_bin
  if ! aider_bin="$(_find_aider)"; then
    aider_bin="$(_install_aider_local)" || exit 1
  fi
  "$aider_bin" \
    --openai-api-base "${OWL_BASE_URL}/v1" \
    --openai-api-key dummy \
    --model "openai/${owl_id}" \
    --no-show-model-warnings \
    --edit-format diff \
    --yes \
    --message "$prompt"
}

# claude über owlAPI-Proxy starten (interaktiv)
run_owl_via_claude() {
  local owl_id="$1"
  shift
  if [[ ! -f "$OWL_PROXY_SCRIPT" ]]; then
    echo "Fehler: owl_proxy.py nicht gefunden: $OWL_PROXY_SCRIPT" >&2
    exit 1
  fi

  # Pre-Flight: Session-Größe vs. Modell-Context-Window
  local force_ctx=0
  for arg in "$@"; do
    [[ "$arg" == "--force-context" ]] && force_ctx=1
  done
  if [[ "$force_ctx" -eq 0 ]]; then
    _pre_flight_check "$owl_id" || exit 1
  fi

  # Auto-Compact-Threshold: kleiner Modelle brauchen früheren Compact.
  # Wir setzen ihn auf 80% der Modell-Context-Window, damit /compact
  # auch WIRKLICH unter die echte Window kommt. claude-CLI respektiert
  # CLAUDE_CODE_AUTO_COMPACT_WINDOW ohne DISABLE_COMPACT zu setzen!
  local cw; cw="$(owl_context_window "$owl_id")"
  if [[ -n "$cw" && "$cw" -gt 0 && "$cw" -lt 1000000 ]]; then
    local compact_target=$(( cw * 80 / 100 ))
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$compact_target"
    echo "Auto-Compact-Window: $compact_target Tokens (80% von $cw für owl:$owl_id)"
  else
    unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
  fi

  echo "Starte owlAPI-Proxy für Modell $owl_id ..."
  local port
  port="$(_start_owl_proxy "$owl_id")"
  trap '_kill_owl_proxy' EXIT INT TERM
  sleep 0.6

  # Kontext-Window für die Info-Anzeige ausgeben. Wir überschreiben NICHT
  # CLAUDE_CODE_MAX_CONTEXT_TOKENS — das würde Auto-Compact ausschalten
  # (greift nur wenn DISABLE_COMPACT gesetzt ist), und der User will
  # Auto-Compact aktiv lassen. Statt dessen: User alle paar Turns /compact
  # aufrufen lassen, oder ein größeres Modell wählen.
  local cw; cw="$(owl_context_window "$owl_id")"
  echo "Claude Code → Proxy :${port} → QuiteQue (Modell $owl_id${cw:+, ctx=$cw})"
  if [[ -n "$cw" && "$cw" -lt 200000 ]]; then
    echo "Hinweis: Modell $owl_id hat nur $cw Token Kontext."
    echo "         Bei langen Sessions regelmäßig /compact aufrufen,"
    echo "         oder ein größeres Modell wählen (z.B. owl:351 oder owl:361)."
  fi

  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  ANTHROPIC_BASE_URL="http://127.0.0.1:${port}" \
  ANTHROPIC_API_KEY="sk-ant-api03-owl-dummy-key-not-real" \
  claude --model "claude-sonnet-4-6" $extra "$@" || true

  _kill_owl_proxy
  trap - EXIT INT TERM
}

# claude headless über owlAPI-Proxy
run_owl_headless_via_claude() {
  local owl_id="$1"
  local prompt="$2"
  if [[ ! -f "$OWL_PROXY_SCRIPT" ]]; then
    echo "Fehler: owl_proxy.py nicht gefunden: $OWL_PROXY_SCRIPT" >&2
    exit 1
  fi

  # Pre-Flight: Session-Größe vs. Modell-Context-Window
  _pre_flight_check "$owl_id" || exit 1

  # Auto-Compact-Threshold: kleiner Modelle brauchen früheren Compact.
  local cw; cw="$(owl_context_window "$owl_id")"
  if [[ -n "$cw" && "$cw" -gt 0 && "$cw" -lt 1000000 ]]; then
    local compact_target=$(( cw * 80 / 100 ))
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$compact_target"
  else
    unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
  fi

  local port
  port="$(_start_owl_proxy "$owl_id")"
  trap '_kill_owl_proxy' EXIT INT TERM
  sleep 0.6

  echo "Claude Code headless → Proxy :${port} → QuiteQue (Modell $owl_id${cw:+, ctx=$cw})"
  if [[ -n "$cw" && "$cw" -lt 200000 ]]; then
    echo "Hinweis: Modell $owl_id hat $cw Token Kontext."
  fi

  ANTHROPIC_BASE_URL="http://127.0.0.1:${port}" \
  ANTHROPIC_API_KEY="sk-owl" \
  claude -p "$prompt" --model "claude-sonnet-4-6" || true

  _kill_owl_proxy
  trap - EXIT INT TERM
}

# Headless-/Projekt-Optionen
HEADLESS=0
TARGET_DIR=""
PROMPT_TEXT=""
EFFORT_LEVEL=""
MAX_TURNS=""
MAX_BUDGET_USD=""
DANGEROUS_SKIP=0
CLI_MODEL_OVERRIDE=""
INTERACTION_LEVEL=""  # wird aus Config geladen; CLI --interaction überschreibt

# Git-Aktionstypen
GIT_ACTION=""
GIT_REPO_NAME=""

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  : "${CLAU_MODEL:=aider:120}"
  : "${CLAU_SESSION_ID:=}"
  : "${CLAU_INTERACTION_LEVEL:=2}"
  : "${CLAU_EFFORT:=}"
  : "${CLAU_SESSION_NAME:=}"
  INTERACTION_LEVEL="$CLAU_INTERACTION_LEVEL"
}

save_config() {
  cat > "$CONFIG_FILE" <<CONF_EOF
CLAU_MODEL="${CLAU_MODEL}"
CLAU_SESSION_ID="${CLAU_SESSION_ID}"
CLAU_INTERACTION_LEVEL="${CLAU_INTERACTION_LEVEL}"
CLAU_EFFORT="${CLAU_EFFORT:-}"
CLAU_SESSION_NAME="${CLAU_SESSION_NAME:-}"
CONF_EOF
}

print_help() {
  cat <<'HELP_EOF'
clau.sh - Interaktiver & Headless-Wrapper für Claude Code mit per-Ordner-Config

Verwendung (interaktiv):
  clau                            Interaktiver Start: Session/Modell auswählen
  clau --list                     Öffnet den Claude-Resume-Picker
  clau --new                      Startet eine neue Session
  clau --model N                  Setzt das Standardmodell (1=haiku, 2=sonnet, 3=opus)
  clau --take ID                  Merkt sich eine feste Session-ID für dieses Verzeichnis
  clau --forget                   Entfernt die gemerkte Session-ID
  clau --current                  Zeigt aktuelle Session/Model-Config
  clau --clear-model              Entfernt das gespeicherte Modell
  clau --install                  Installiert "clau" nach ~/.local/bin
  clau --uninstall                Entfernt "clau" aus ~/.local/bin
  clau --self-update              Aktualisiert clau auf die neueste Version aus dem Git-Repo

Headless / Projekt-Modus:
  clau --headless -p "Prompt"
  clau --headless -p "Prompt" --effort high --max-turns 8 --max-budget-usd 1.5
  clau --new -f /pfad             Neues Projektverzeichnis anlegen und dort interaktiv starten
  clau --new --headless -f /pfad -p "Prompt" -m haiku --effort high --max-turns 8

Headless-Optionen:
  --headless                      Claude im print/headless mode (nicht interaktiv)
  -p, --prompt TEXT               Prompt-Text für headless mode (erforderlich bei --headless)
  -f, --folder PATH               Zielverzeichnis für --new
  -m, --mdl MODEL                 Modell: haiku | sonnet | opus
      --effort LEVEL              low | medium | high | max
      --max-turns N               Max. agentische Schritte
      --max-budget-usd USD        Kostenlimit
      --dangerously-skip-permissions
                                  Alle Permission-Prompts überspringen
      --interaction N             0 = vollautomatisch (keine Nachfragen, alle Rechte)
                                  1 = halbautomatisch (fragt nur bei Shellbefehlen)
                                  2 = Standard (fragt bei Planung & Architektur)
                                  Wird per-Verzeichnis in .clau.conf gespeichert.

Git-Helfer (aktuelles Repo):
  clau --git-up                   Lokale Änderungen committen & pushen
  clau --git-down                 Änderungen von origin holen (git pull --rebase)

Git-Helfer (Repo aus GitHub via SSH):
  clau --git-down NAME            Klont git@github.com:DavidFroe/NAME.git ins aktuelle Verzeichnis

Model-Mappings:
  Claude Code (agentisch):  1=haiku  2=sonnet  3=opus
  owlAPI (lokal/gratis):    4=owl:120  5=owl:243  6=owl:113(Grok)  7=owl:38(QwQ)  8=owl:316
  owlAPI (günstig/stark):   9=owl:35  a=owl:350  b=owl:503  c=owl:21  d=owl:84  e=owl:501
  Aider (Editor-Modus):     f=aider:120  g=aider:350  i=aider:502(GemFlash)  j=aider:84(GPT-5)  k=aider:351(MiniMax)
  owlAPI direkt:            --model owl:35  oder  -m 350
  Aider direkt:             --model aider:120  oder  -m aider:243
HELP_EOF
}

model_from_number() {
  case "${1:-}" in
    1) CLAU_MODEL="haiku" ;;
    2) CLAU_MODEL="sonnet" ;;
    3) CLAU_MODEL="opus" ;;
    4) CLAU_MODEL="owl:120" ;;   # PropellerA lokal
    5) CLAU_MODEL="owl:243" ;;   # Qwopus lokal
    6) CLAU_MODEL="owl:113" ;;   # Grok-4.3 gratis
    7) CLAU_MODEL="owl:38" ;;    # QwQ-Plus gratis
    8) CLAU_MODEL="owl:316" ;;   # Qwen3-Coder OR gratis
    9) CLAU_MODEL="owl:35" ;;    # Qwen-Flash günstig
    f) CLAU_MODEL="aider:120" ;; # Aider + PropellerA-27B
    g) CLAU_MODEL="aider:350" ;; # Aider + DeepSeek-V4-Pro
    *)
      echo "Unbekanntes Modell-Kürzel: $1 (erlaubt: 1-3=Claude CLI, 4-9/f-g=owlAPI/Aider)" >&2
      exit 1
      ;;
  esac
}

normalize_model_name() {
  case "${1:-}" in
    haiku|sonnet|opus)
      CLI_MODEL_OVERRIDE="$1"
      ;;
    owl:*)
      CLI_MODEL_OVERRIDE="$1"
      ;;
    aider:*)
      CLI_MODEL_OVERRIDE="$1"
      ;;
    *)
      # Bare Zahl oder ID → als owl-Modell interpretieren
      if [[ "$1" =~ ^[0-9]+$ ]] || [[ "$1" =~ ^[a-z] ]]; then
        CLI_MODEL_OVERRIDE="owl:$1"
      else
        echo "Ungültiges Modell: $1 (erlaubt: haiku|sonnet|opus oder owl:<ID>)" >&2
        exit 1
      fi
      ;;
  esac
}

effective_model() {
  if [[ -n "${CLI_MODEL_OVERRIDE:-}" ]]; then
    echo "$CLI_MODEL_OVERRIDE"
  elif [[ -n "${CLAU_MODEL:-}" ]]; then
    echo "$CLAU_MODEL"
  else
    echo ""
  fi
}

show_current() {
  local mdl="${CLAU_MODEL:-<nicht gesetzt>}"
  local backend="Claude Code (agentisch)"
  if is_owl_model "${CLAU_MODEL:-}"; then
    backend="owlAPI Chat (${OWL_BASE_URL}, Modell $(owl_model_id "${CLAU_MODEL}"))"
  elif is_aider_model "${CLAU_MODEL:-}"; then
    backend="Aider direkt (${OWL_BASE_URL}/v1, Modell $(aider_model_id "${CLAU_MODEL}"))"
  fi
  echo "Aktuelles Verzeichnis : $(pwd)"
  echo "Konfiguriertes Modell : $mdl"
  echo "Backend               : $backend"
  echo "Session-Name          : ${CLAU_SESSION_NAME:-<keiner>}"
  echo "Feste Session-ID      : ${CLAU_SESSION_ID:-<keine>}"
  echo "Autonomie-Level       : $(interaction_label)"
  echo "Effort                : ${CLAU_EFFORT:-medium (Standard)}"
  echo "sudo NOPASSWD         : $(sudo_is_enabled && echo "AN  ($SUDO_FILE)" || echo "AUS")"
}

choose_model_interactive() {
  while true; do
    echo
    echo "Modell wählen:"
    echo "  --- Standard Claude (agentisch, Datei-Editing + Shell) ---"
    echo "  1) haiku              schnell, günstig"
    echo "  2) sonnet             Standard                    [Enter]"
    echo "  3) opus               stärker, teurer"
    echo "  --- LiteLLM Modelle (via Proxy, ${OWL_BASE_URL}) ---"
    echo "  4) PropellerA-27B  lokal   tools+vision  GRATIS"
    echo "  5) Qwopus-9B       lokal   tools schnell GRATIS"
    echo "  6) Grok-4.3        xAI     tools 2M ctx  GRATIS"
    echo "  7) QwQ-Plus        Ali     reasoning     GRATIS"
    echo "  8) Qwen3-Coder     OR      tools 1M ctx  GRATIS"
    echo "  9) free (Router)   ---     mix gratis    GRATIS"
    echo "  a) Qwen-Flash      Ali     tools         \$0.05/\$0.15"
    echo "  b) DeepSeek V4 Pro OR      tools 1M ctx  \$0.44/\$0.87"
    echo "  c) Gemini-Flash    Goog    tools         \$0.10/\$0.40"
    echo "  d) Claude-Sonnet   Anth    tools         \$3.00/\$15.00"
    echo "  e) GPT-5           OAI     tools         \$1.25/\$10.00"
    echo "  ee) Gemini-2.5-Pro Goog    tools         \$1.25/\$10.00"
    echo "  o) LiteLLM ID direkt"
    echo "  --- Aider Modelle (Editor-Modus, direkt OpenAI-Format) ---"
    echo "  f) PropellerA-27B  lokal   GRATIS"
    echo "  g) DeepSeek V4 Pro cloud   \$0.44/\$0.87"
    echo "  h) free (Router)           GRATIS"
    echo "  i) Gemini 2.5 Flash cloud  \$0.30/\$2.50"
    echo "  j) GPT-5           OAI     \$1.25/\$10.00"
    echo "  k) MiniMax M3      cloud   1M ctx"
    echo "  p) Aider ID direkt"
    printf "Auswahl [1-9, a-ee, f-k, o, p, Enter=2]: "
    read -r choice

    case "${choice:-2}" in
      1) CLAU_MODEL="haiku"; break ;;
      2) CLAU_MODEL="sonnet"; break ;;
      3) CLAU_MODEL="opus"; break ;;
      4) CLAU_MODEL="owl:120"; break ;;
      5) CLAU_MODEL="owl:243"; break ;;
      6) CLAU_MODEL="owl:113"; break ;;
      7) CLAU_MODEL="owl:38"; break ;;
      8) CLAU_MODEL="owl:316"; break ;;
      9) CLAU_MODEL="owl:free"; break ;;
      a|A) CLAU_MODEL="owl:35"; break ;;
      b|B) CLAU_MODEL="owl:350"; break ;;
      c|C) CLAU_MODEL="owl:503"; break ;;
      d|D) CLAU_MODEL="owl:21"; break ;;
      e|E) CLAU_MODEL="owl:84"; break ;;
      ee|EE) CLAU_MODEL="owl:501"; break ;;
      f|F) CLAU_MODEL="aider:120"; break ;;
      g|G) CLAU_MODEL="aider:350"; break ;;
      h|H) CLAU_MODEL="aider:free"; break ;;
      i|I) CLAU_MODEL="aider:502"; break ;;
      j|J) CLAU_MODEL="aider:84"; break ;;
      k|K) CLAU_MODEL="aider:351"; break ;;
      o|O)
        printf "LiteLLM/owlAPI Modell-ID: "
        read -r tmp_id
        if [[ -n "$tmp_id" ]]; then
          CLAU_MODEL="owl:${tmp_id}"
          break
        fi
        echo "Abgebrochen."
        ;;
      p|P)
        printf "Aider Modell-ID: "
        read -r tmp_id
        if [[ -n "$tmp_id" ]]; then
          CLAU_MODEL="aider:${tmp_id}"
          break
        fi
        echo "Abgebrochen."
        ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done

  save_config
  echo "Modell: $CLAU_MODEL"
}

ensure_model() {
  if [[ -z "$(effective_model)" ]]; then
    choose_model_interactive
  fi
}

interaction_label() {
  case "${INTERACTION_LEVEL:-2}" in
    0) echo "0 – vollautomatisch (keine Nachfragen, alle Rechte)" ;;
    1) echo "1 – halbautomatisch (fragt nur bei Shellbefehlen)" ;;
    2) echo "2 – Standard (fragt bei Planung & Architektur)" ;;
    *) echo "${INTERACTION_LEVEL}" ;;
  esac
}

choose_interaction_interactive() {
  while true; do
    echo
    echo "Autonomie-Level wählen:"
    echo "  0) Vollautomatisch – keine Nachfragen, alle Rechte, läuft stundenlang durch"
    echo "  1) Halbautomatisch – fragt nur bei wesentlichen Dingen (Shellbefehle etc.)"
    echo "  2) Standard        – fragt bei Planung & architektonischen Änderungen"
    printf "Auswahl [0-2, Enter=2]: "
    read -r choice
    case "${choice:-2}" in
      0) CLAU_INTERACTION_LEVEL=0; INTERACTION_LEVEL=0; break ;;
      1) CLAU_INTERACTION_LEVEL=1; INTERACTION_LEVEL=1; break ;;
      2) CLAU_INTERACTION_LEVEL=2; INTERACTION_LEVEL=2; break ;;
      *) echo "Ungültige Auswahl. Bitte 0, 1 oder 2 eingeben." ;;
    esac
  done
  save_config
  echo "Autonomie-Level gesetzt auf: $(interaction_label)"
}

choose_effort_interactive() {
  echo
  echo "Effort-Level (--effort, gilt für Claude):"
  echo "  1) low    — schnell, weniger gründlich"
  echo "  2) medium — Standard"
  echo "  3) high   — gründlicher, mehr Schritte"
  echo "  4) max    — maximal"
  printf "Auswahl [1-4, Enter=2]: "
  read -r choice
  case "${choice:-2}" in
    1) CLAU_EFFORT="low" ;;
    2) CLAU_EFFORT="medium" ;;
    3) CLAU_EFFORT="high" ;;
    4) CLAU_EFFORT="max" ;;
    *) echo "Ungültige Auswahl."; return ;;
  esac
  EFFORT_LEVEL="$CLAU_EFFORT"
  save_config
  echo "Effort: $CLAU_EFFORT"
}

choose_bot_settings() {
  while true; do
    echo
    echo "Bot-Einstellungen:"
    echo "  1) Autonomie-Level  — ${INTERACTION_LEVEL:-2}: $(interaction_label)"
    echo "  2) sudo NOPASSWD    — $(sudo_is_enabled && echo "AN  [$SUDO_FILE]" || echo "AUS")"
    echo "  3) Effort           — ${CLAU_EFFORT:-medium}  (nur Claude)"
    echo "  0) Zurück"
    printf "Auswahl [0-3]: "
    read -r choice
    case "${choice:-0}" in
      1) choose_interaction_interactive ;;
      2) toggle_sudo ;;
      3) choose_effort_interactive ;;
      0|"") break ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done
}

run_new_session_named() {
  printf "Session-Name (optional, Enter=ohne): "
  read -r sname
  if [[ -n "$sname" ]]; then
    CLAU_SESSION_NAME="$sname"
    save_config
  fi
  run_new_session
}

install_self() {
  local script_path target_path
  script_path="$(readlink -f "$0")"
  target_path="${INSTALL_DIR}/${INSTALL_NAME}"

  mkdir -p "$INSTALL_DIR"
  chmod +x "$script_path"
  ln -sfn "$script_path" "$target_path"

  echo "Installiert: $target_path -> $script_path"

  case ":$PATH:" in
    *":${INSTALL_DIR}:"*)
      echo "${INSTALL_DIR} ist bereits im PATH."
      ;;
    *)
      echo
      echo "WICHTIG: ${INSTALL_DIR} ist noch nicht im PATH."
      echo "Füge diese Zeile in ~/.bashrc ein und starte die Shell neu:"
      echo 'export PATH="$HOME/.local/bin:$PATH"'
      ;;
  esac
}

uninstall_self() {
  local target_path
  target_path="${INSTALL_DIR}/${INSTALL_NAME}"

  if [[ -L "$target_path" || -e "$target_path" ]]; then
    rm -f "$target_path"
    echo "Entfernt: $target_path"
  else
    echo "Nichts zu entfernen: $target_path existiert nicht."
  fi
}

self_update() {
  local script_path repo_dir
  script_path="$(readlink -f "$0")"
  repo_dir="$(dirname "$script_path")"

  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Das clau-Verzeichnis ($repo_dir) ist kein Git-Repository." >&2
    exit 1
  fi

  echo "Aktualisiere clau aus $(git -C "$repo_dir" remote get-url origin 2>/dev/null || echo 'origin') ..."
  git -C "$repo_dir" pull --rebase

  chmod +x "$script_path"
  echo "clau wurde aktualisiert."

  # Symlink neu setzen falls vorhanden
  local target_path="${INSTALL_DIR}/${INSTALL_NAME}"
  if [[ -L "$target_path" ]]; then
    ln -sfn "$script_path" "$target_path"
    echo "Symlink aktualisiert: $target_path -> $script_path"
  fi
}

_interaction_args() {
  local parts=()
  if [[ "${INTERACTION_LEVEL:-2}" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    parts+=(--dangerously-skip-permissions)
  fi
  local effort="${EFFORT_LEVEL:-${CLAU_EFFORT:-}}"
  if [[ -n "$effort" && "$effort" != "medium" ]]; then
    parts+=(--effort "$effort")
  fi
  echo "${parts[*]}"
}

run_resume_picker() {
  local mdl
  mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if is_owl_model "$mdl"; then
    run_owl_via_claude "$(owl_model_id "$mdl")" --resume
    return
  fi
  if is_aider_model "$mdl"; then
    run_aider "$(aider_model_id "$mdl")"
    return
  fi
  echo "Öffne Session-Auswahl (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  exec claude --resume --model "$mdl" $extra
}

run_saved_session() {
  local mdl
  mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if is_owl_model "$mdl"; then
    run_owl_via_claude "$(owl_model_id "$mdl")"
    return
  fi
  if is_aider_model "$mdl"; then
    run_aider "$(aider_model_id "$mdl")"
    return
  fi
  echo "Starte feste Session $CLAU_SESSION_ID (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  exec claude --resume "$CLAU_SESSION_ID" --model "$mdl" $extra
}

run_new_session() {
  local mdl
  mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if is_owl_model "$mdl"; then
    run_owl_via_claude "$(owl_model_id "$mdl")"
    return
  fi
  if is_aider_model "$mdl"; then
    run_aider "$(aider_model_id "$mdl")"
    return
  fi
  echo "Starte neue Session (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  exec claude --model "$mdl" $extra
}

build_headless_cmd() {
  local mdl
  mdl="$(effective_model)"

  CLAUDE_CMD=(claude)

  if [[ -n "$mdl" ]]; then
    CLAUDE_CMD+=(--model "$mdl")
  fi

  if [[ -n "${EFFORT_LEVEL:-}" ]]; then
    CLAUDE_CMD+=(--effort "$EFFORT_LEVEL")
  fi

  case "$INTERACTION_LEVEL" in
    0)
      if [[ "$(id -u)" -ne 0 ]]; then
        CLAUDE_CMD+=(--dangerously-skip-permissions)
      fi
      ;;
    1|2) ;;
    *)
      echo "--interaction erwartet 0, 1 oder 2" >&2
      exit 1
      ;;
  esac

  if [[ "$DANGEROUS_SKIP" -eq 1 ]] && [[ "$(id -u)" -ne 0 ]]; then
    CLAUDE_CMD+=(--dangerously-skip-permissions)
  fi

  CLAUDE_CMD+=(-p)

  if [[ -z "${PROMPT_TEXT:-}" ]]; then
    echo "--headless erfordert einen Prompt mit -p/--prompt." >&2
    exit 1
  fi

  if [[ -n "${MAX_TURNS:-}" ]]; then
    CLAUDE_CMD+=(--max-turns "$MAX_TURNS")
  fi

  if [[ -n "${MAX_BUDGET_USD:-}" ]]; then
    CLAUDE_CMD+=(--max-budget-usd "$MAX_BUDGET_USD")
  fi

  CLAUDE_CMD+=("$PROMPT_TEXT")
}

run_headless_here() {
  local mdl; mdl="$(effective_model)"
  if is_owl_model "$mdl"; then
    if [[ -z "${PROMPT_TEXT:-}" ]]; then
      echo "--headless erfordert einen Prompt mit -p/--prompt." >&2
      exit 1
    fi
    run_owl_headless_via_claude "$(owl_model_id "$mdl")" "$PROMPT_TEXT"
    return
  fi
  if is_aider_model "$mdl"; then
    if [[ -z "${PROMPT_TEXT:-}" ]]; then
      echo "--headless erfordert einen Prompt mit -p/--prompt." >&2
      exit 1
    fi
    run_aider_headless "$(aider_model_id "$mdl")" "$PROMPT_TEXT"
    return
  fi
  build_headless_cmd
  echo "Starte headless im Verzeichnis: $(pwd)"
  exec "${CLAUDE_CMD[@]}"
}

run_headless_in_dir() {
  local dir="$1"
  mkdir -p "$dir"
  local mdl; mdl="$(effective_model)"
  if is_owl_model "$mdl"; then
    if [[ -z "${PROMPT_TEXT:-}" ]]; then
      echo "--headless erfordert einen Prompt mit -p/--prompt." >&2
      exit 1
    fi
    (cd "$dir"; run_owl_headless_via_claude "$(owl_model_id "$mdl")" "$PROMPT_TEXT")
    return
  fi
  if is_aider_model "$mdl"; then
    if [[ -z "${PROMPT_TEXT:-}" ]]; then
      echo "--headless erfordert einen Prompt mit -p/--prompt." >&2
      exit 1
    fi
    (cd "$dir"; run_aider_headless "$(aider_model_id "$mdl")" "$PROMPT_TEXT")
    return
  fi
  echo "Projektverzeichnis bereit für headless: $dir"
  (
    cd "$dir"
    build_headless_cmd
    echo "Starte headless in: $dir"
    exec "${CLAUDE_CMD[@]}"
  )
}

run_new_project_interactive() {
  local dir="$1"
  mkdir -p "$dir"
  echo "Projektverzeichnis bereit: $dir"
  (
    cd "$dir"
    if [[ -f "$CONFIG_FILE" ]]; then
      source "$CONFIG_FILE"
      : "${CLAU_MODEL:=}"
    fi
    if [[ -z "${CLAU_MODEL:-}" ]]; then
      while true; do
        echo
        echo "Bitte Modell wählen:"
        echo "  1) haiku   - schnell, günstig"
        echo "  2) sonnet  - Standard"
        echo "  3) opus    - stärker, teurer"
        printf "Auswahl [1-3, Enter=2]: "
        read -r choice
        case "${choice:-2}" in
          1) CLAU_MODEL="haiku"; break ;;
          2) CLAU_MODEL="sonnet"; break ;;
          3) CLAU_MODEL="opus"; break ;;
          *) echo "Ungültige Auswahl." ;;
        esac
      done
      cat > "$CONFIG_FILE" <<EOF
CLAU_MODEL="${CLAU_MODEL}"
CLAU_SESSION_ID=""
CLAU_INTERACTION_LEVEL="${CLAU_INTERACTION_LEVEL:-2}"
EOF
    fi
    echo "Starte neue Session im Projekt mit Modell ${CLAU_MODEL} ..."
    exec claude --model "${CLAU_MODEL}"
  )
}

interactive_start() {
  ensure_model

  local mdl; mdl="$(effective_model)"
  local tag
  if is_aider_model "$mdl"; then
    tag="Aider:$(aider_model_id "$mdl")"
  elif is_owl_model "$mdl"; then
    tag="LiteLLM:$(owl_model_id "$mdl")"
  else
    tag="Claude:$mdl"
  fi

  echo
  echo "clau — $(basename "$(pwd)")  [$tag]"
  [[ -n "${CLAU_SESSION_NAME:-}" ]] && echo "  Session: ${CLAU_SESSION_NAME}"
  echo "  1) Verfügbare Sessions auswählen"
  echo "  2) Neue Session beginnen        [Enter]"
  echo "  3) Modell wechseln"
  echo "  4) Bot-Einstellungen"
  printf "Auswahl [1-4, Enter=2]: "
  read -r start_choice

  case "${start_choice:-2}" in
    1) run_resume_picker ;;
    2) run_new_session_named ;;
    3) choose_model_interactive; interactive_start ;;
    4) choose_bot_settings; interactive_start ;;
    *) echo "Ungültige Auswahl."; exit 1 ;;
  esac
}

# --- Git-Helfer ---

ensure_git_repo() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Dieses Verzeichnis ist kein Git-Repository." >&2
    exit 1
  fi
}

git_has_changes() {
  [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

ask_yes_no() {
  local prompt="$1"
  # Bei Autonomie-Level 0: immer automatisch ja
  if [[ "${INTERACTION_LEVEL:-2}" -eq 0 ]]; then
    echo "${prompt} [auto-ja bei Level 0]"
    return 0
  fi
  local answer
  while true; do
    printf "%s [j/n]: " "$prompt"
    read -r answer
    case "${answer,,}" in
      j|ja|y|yes) return 0 ;;
      n|nein|no) return 1 ;;
      *) echo "Bitte j oder n eingeben." ;;
    esac
  done
}

run_git_up() {
  ensure_git_repo

  echo "Git-Status:"
  git status --short || true
  echo

  if git_has_changes; then
    if ask_yes_no "Uncommitted Änderungen vorhanden. Commit & Push?"; then
      local msg
      if [[ "${INTERACTION_LEVEL:-2}" -eq 0 ]]; then
        msg="Update via clau --git-up"
      else
        printf "Commit-Message: "
        read -r msg
        if [[ -z "$msg" ]]; then
          msg="Update via clau --git-up"
        fi
      fi
      git add -A
      git commit -m "$msg"
    else
      echo "Abgebrochen."
      exit 1
    fi
  else
    echo "Keine lokalen Änderungen zu committen."
  fi

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

  echo
  echo "Hole aktuellen Stand von origin/$branch (git pull --rebase)..."
  git pull --rebase || echo "Hinweis: git pull --rebase fehlgeschlagen, bitte manuell prüfen."

  echo
  echo "Push zu origin/$branch..."
  if git push; then
    echo "Push erfolgreich."
  else
    echo "Normaler Push fehlgeschlagen."
    if ask_yes_no "Soll 'git push --force-with-lease' versucht werden?"; then
      git push --force-with-lease
      echo "Force-Push (mit lease) ausgeführt."
    else
      echo "Kein Force-Push durchgeführt."
      exit 1
    fi
  fi
}

run_git_down_local() {
  ensure_git_repo

  if git_has_changes; then
    echo "WARNUNG: Es gibt lokale uncommitted Änderungen:"
    git status --short || true
    if ! ask_yes_no "Trotzdem von origin holen (git pull --rebase)?"; then
      echo "Abgebrochen."
      exit 1
    fi
  fi

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

  echo "Hole aktuellen Stand von origin/$branch (git pull --rebase)..."
  git pull --rebase
}

run_git_down_repo() {
  local repo_name="$1"

  if [[ -z "$repo_name" ]]; then
    echo "--git-down NAME erwartet einen Repository-Namen (z.B. owlAPI)" >&2
    exit 1
  fi

  local github_user="DavidFroe"
  local repo_url="git@github.com:${github_user}/${repo_name}.git"

  echo "Ziel-Repository (SSH): $repo_url"
  echo

  if [[ -d ".git" ]]; then
    echo "Hinweis: Dieses Verzeichnis ist bereits ein Git-Repository:"
    git status --short 2>/dev/null || true
    if ! ask_yes_no "Bestehendes Repository durch $repo_url ersetzen?"; then
      echo "Abgebrochen."
      exit 1
    fi
  fi

  echo "Aktueller Inhalt von $(pwd):"
  ls -A

  if ! ask_yes_no "Alle bestehenden Dateien entfernen und $repo_url hierher klonen?"; then
    echo "Abgebrochen."
    exit 1
  fi

  local ts backup_name
  ts="$(date +%Y%m%d_%H%M%S)"
  backup_name="../backup_$(basename "$(pwd)")_${ts}.tar.gz"

  echo "Erstelle Backup in: $backup_name"
  tar -czf "$backup_name" . || echo "Hinweis: Backup möglicherweise unvollständig."

  echo "Lösche aktuellen Inhalt..."
  find . -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null

  echo "Initialisiere Git-Repository..."
  git init -b main

  git remote add origin "$repo_url"

  echo "Hole Daten von origin..."
  git fetch origin

  echo "Checkout von origin/main..."
  git checkout -t origin/main 2>/dev/null || git checkout main || git checkout -b main origin/main

  echo "Fertig: $repo_url ist jetzt in $(pwd) ausgecheckt."
  echo "Backup des alten Inhalts liegt in: $backup_name"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        print_help
        exit 0
        ;;
      --install)
        install_self
        exit 0
        ;;
      --uninstall)
        uninstall_self
        exit 0
        ;;
      --self-update)
        self_update
        exit 0
        ;;
      --model)
        if [[ -z "${2:-}" ]]; then
          echo "--model erwartet eine Zahl (1=haiku, 2=sonnet, 3=opus)" >&2
          exit 1
        fi
        model_from_number "$2"
        save_config
        echo "Standardmodell gesetzt auf: $CLAU_MODEL"
        exit 0
        ;;
      -m|--mdl)
        if [[ -z "${2:-}" ]]; then
          echo "-m/--mdl erwartet ein Modell: haiku|sonnet|opus" >&2
          exit 1
        fi
        normalize_model_name "$2"
        shift 2
        ;;
      --take)
        if [[ -z "${2:-}" ]]; then
          echo "--take erwartet eine Session-ID" >&2
          exit 1
        fi
        CLAU_SESSION_ID="$2"
        save_config
        echo "Feste Session-ID gesetzt auf: $CLAU_SESSION_ID"
        exit 0
        ;;
      --forget)
        CLAU_SESSION_ID=""
        save_config
        echo "Feste Session-ID entfernt."
        exit 0
        ;;
      --clear-model)
        CLAU_MODEL=""
        save_config
        echo "Gespeichertes Modell entfernt."
        exit 0
        ;;
      --current)
        show_current
        exit 0
        ;;
      --sudo)
        toggle_sudo
        exit 0
        ;;
      --list)
        ACTION="list"
        shift
        ;;
      --new)
        ACTION="new"
        shift
        ;;
      --headless)
        HEADLESS=1
        shift
        ;;
      -p|--prompt)
        PROMPT_TEXT="${2:-}"
        if [[ -z "$PROMPT_TEXT" ]]; then
          echo "--prompt erwartet einen Text" >&2
          exit 1
        fi
        shift 2
        ;;
      -f|--folder)
        TARGET_DIR="${2:-}"
        if [[ -z "$TARGET_DIR" ]]; then
          echo "--folder erwartet einen Pfad" >&2
          exit 1
        fi
        shift 2
        ;;
      --effort)
        EFFORT_LEVEL="${2:-}"
        case "$EFFORT_LEVEL" in
          low|medium|high|max) ;;
          *) echo "--effort erwartet low|medium|high|max" >&2; exit 1 ;;
        esac
        shift 2
        ;;
      --max-turns)
        MAX_TURNS="${2:-}"
        [[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || { echo "--max-turns erwartet eine Zahl" >&2; exit 1; }
        shift 2
        ;;
      --max-budget-usd)
        MAX_BUDGET_USD="${2:-}"
        if [[ -z "$MAX_BUDGET_USD" ]]; then
          echo "--max-budget-usd erwartet einen Wert" >&2
          exit 1
        fi
        shift 2
        ;;
      --dangerously-skip-permissions)
        DANGEROUS_SKIP=1
        shift
        ;;
      --interaction)
        INTERACTION_LEVEL="${2:-}"
        case "$INTERACTION_LEVEL" in
          0|1|2) CLAU_INTERACTION_LEVEL="$INTERACTION_LEVEL" ;;
          *) echo "--interaction erwartet 0, 1 oder 2" >&2; exit 1 ;;
        esac
        shift 2
        ;;
      --git-up)
        ACTION="git-up"
        shift
        ;;
      --git-down)
        if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
          GIT_ACTION="remote-down"
          GIT_REPO_NAME="$2"
          shift 2
        else
          ACTION="git-down-local"
          shift
        fi
        ;;
      *)
        echo "Unbekannte Option: $1" >&2
        echo
        print_help
        exit 1
        ;;
    esac
  done
}

ACTION="interactive"

load_config
parse_args "$@"

case "${ACTION}" in
  list)
    ensure_model
    run_resume_picker
    ;;
  new)
    if [[ "$HEADLESS" -eq 1 ]]; then
      if [[ -n "${TARGET_DIR:-}" ]]; then
        run_headless_in_dir "$TARGET_DIR"
      else
        run_headless_here
      fi
    else
      if [[ -n "${TARGET_DIR:-}" ]]; then
        run_new_project_interactive "$TARGET_DIR"
      else
        run_new_session
      fi
    fi
    ;;
  git-up)
    run_git_up
    ;;
  git-down-local)
    run_git_down_local
    ;;
  interactive)
    if [[ "$GIT_ACTION" == "remote-down" ]]; then
      run_git_down_repo "$GIT_REPO_NAME"
    elif [[ "$HEADLESS" -eq 1 ]]; then
      if [[ -n "${TARGET_DIR:-}" ]]; then
        run_headless_in_dir "$TARGET_DIR"
      else
        run_headless_here
      fi
    else
      interactive_start
    fi
    ;;
  *)
    echo "Unbekannte Aktion: $ACTION" >&2
    exit 1
    ;;
esac
