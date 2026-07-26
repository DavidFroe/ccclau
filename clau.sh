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
    if sudo visudo -cf "$SUDO_FILE" &>/dev/null; then
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
CC_COMPACT_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/cc_compact.py"
OWL_BASE_URL="http://11.0.0.13:7077"
QQ_USER="opencode"

# Telegram-Integration (lokale Config außerhalb des Repos)
CLAU_TG_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/clau/telegram.conf"
CLAU_TG_STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/clau/telegram"

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

# ── Effective Context Window (alle Modell-Typen) ─────────────────────────────
# Gibt das Context-Window für ein beliebiges Modell zurück.
# owl:X → OWL_CONTEXT_WINDOWS lookup
# Claude-Modelle → bekannte Werte
# Gibt leer zurück, wenn nicht gefunden.
effective_context_window() {
  local model="${1:-}"
  [[ -n "$model" ]] || return 0

  local owl_id=""

  if [[ "$model" == owl:* ]]; then
    owl_id="${model#owl:}"
  elif [[ "$model" == "haiku" || "$model" == "claude-haiku"* ]]; then
    echo "200000"
    return
  elif [[ "$model" == "sonnet" || "$model" == "claude-sonnet"* ]]; then
    echo "1000000"   # Sonnet 5: 1M Kontext
    return
  elif [[ "$model" == "opus" || "$model" == "claude-opus"* ]]; then
    echo "1000000"   # Opus 5: 1M Kontext
    return
  elif [[ "$model" == "fable" || "$model" == "claude-fable"* ]]; then
    echo "1000000"   # Fable 5: 1M Kontext
    return
  fi

  if [[ -n "$owl_id" ]]; then
    owl_context_window "$owl_id"
  fi
}

# ── Timeout-Presets pro Modell ──────────────────────────────────────────────
# Default/Max Timeout in ms pro Modell-ID. Langsame Modelle brauchen mehr Zeit.
# Format: DEFAULT_MAX_TIMEOUT_MS (Default) : MAX_MAX_TIMEOUT_MS (Maximum)
# Kleine Modelle (CPU, <10B): 10 Min Default, 30 Min Max
# Mittlere Modelle (10-30B): 30 Min Default, 60 Min Max
# Große Modelle (30B+): 30 Min Default, 120 Min Max
# 1M-Context-Modelle: 60 Min Default, 180 Min Max
declare -gA TIMEOUT_PRESET_DEFAULT=(
  ["50"]="600000"    # SkinnyJoe T79: Qwen3 4B (CPU) → 10 Min
  ["51"]="600000"    # SkinnyJoe T77: Dolphin3 3B (CPU) → 10 Min
  ["52"]="600000"    # SkinnyJoe T78: L3.1 Dark-Planet 8B (CPU) → 10 Min
  ["120"]="1800000"  # PropellerA: Qwen3.6 27B → 30 Min
  ["317"]="3600000"  # OpenRouter Owl Alpha (1M ctx) → 60 Min
  ["350"]="3600000"  # DeepSeek V4 Pro (1M ctx) → 60 Min
  ["351"]="3600000"  # MiniMax M3 (1M ctx) → 60 Min
  ["360"]="1800000"  # MoonshotAI Kimi K2.7 Code (262k) → 30 Min
  ["361"]="3600000"  # Qwen3.7 Max (1M ctx) → 60 Min
  ["362"]="3600000"  # Qwen3.7 Plus (1M ctx) → 60 Min
  ["367"]="1800000"  # Z.ai GLM 4.7 Flash (203k) → 30 Min
  ["368"]="1800000"  # Z.ai GLM 4.7 (203k) → 30 Min
  ["379"]="3600000"  # DeepSeek V4 Flash (1M ctx) → 60 Min
  ["380"]="3600000"  # Xiaomi MiMo V2.5 (1M ctx) → 60 Min
  ["381"]="3600000"  # Qwen3 Coder Plus (1M ctx) → 60 Min
  ["382"]="3600000"  # Z.ai GLM 5.2 (1M ctx) → 60 Min
  ["383"]="1800000"  # Amazon Nova Micro 1.0 (128k) → 30 Min
  ["384"]="3600000"  # Qwen3 Coder 480B (1M ctx) → 60 Min
  ["385"]="1800000"  # Qwen3.6 27B (262k) → 30 Min
  ["386"]="3600000"  # Meta Llama 4 Maverick (1M ctx) → 60 Min
)
declare -gA TIMEOUT_PRESET_MAX=(
  ["50"]="1800000"   # SkinnyJoe → 30 Min
  ["51"]="1800000"
  ["52"]="1800000"
  ["120"]="3600000"  # PropellerA → 60 Min
  ["317"]="10800000" # OpenRouter Owl Alpha → 180 Min
  ["350"]="10800000" # DeepSeek V4 Pro → 180 Min
  ["351"]="10800000" # MiniMax M3 → 180 Min
  ["360"]="3600000"  # Kimi K2.7 → 60 Min
  ["361"]="10800000" # Qwen3.7 Max → 180 Min
  ["362"]="10800000" # Qwen3.7 Plus → 180 Min
  ["367"]="3600000"  # GLM 4.7 Flash → 60 Min
  ["368"]="3600000"  # GLM 4.7 → 60 Min
  ["379"]="10800000" # DeepSeek V4 Flash → 180 Min
  ["380"]="10800000" # Xiaomi MiMo → 180 Min
  ["381"]="10800000" # Qwen3 Coder Plus → 180 Min
  ["382"]="10800000" # GLM 5.2 → 180 Min
  ["383"]="3600000"  # Nova Micro → 60 Min
  ["384"]="10800000" # Qwen3 Coder 480B → 180 Min
  ["385"]="3600000"  # Qwen3.6 27B → 60 Min
  ["386"]="10800000" # Llama 4 Maverick → 180 Min
)

# Setzt Timeout-Werte basierend auf Modell-Preset oder verwendet Konfig/Default
apply_timeout_for_model() {
  local model="${1:-}"
  [[ -n "$model" ]] || return 0

  local owl_id=""
  if [[ "$model" == owl:* ]]; then
    owl_id="${model#owl:}"
  fi

  if [[ -n "$owl_id" ]]; then
    local preset_default="${TIMEOUT_PRESET_DEFAULT[$owl_id]:-}"
    local preset_max="${TIMEOUT_PRESET_MAX[$owl_id]:-}"
    if [[ -n "$preset_default" ]]; then
      CLAU_TIMEOUT_DEFAULT="$preset_default"
    fi
    if [[ -n "$preset_max" ]]; then
      CLAU_TIMEOUT_MAX="$preset_max"
    fi
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

# ── Telegram-Integration ────────────────────────────────────────────────────
# Ein Bot, eine Supergruppe mit "Themen" (Topics). Pro Claude-Session ein Topic:
# clau legt es beim ersten Event an, meldet dort Status und schließt es am Ende.
# Config liegt LOKAL in ~/.config/clau/telegram.conf (nicht im Git-Repo).

_tg_load() {
  [[ -f "$CLAU_TG_CONF" ]] && source "$CLAU_TG_CONF"
  : "${CLAU_TG_ENABLED:=0}"
  : "${CLAU_TG_EVENTS:=notification,stop,sessionend}"
}

# true, wenn Telegram voll konfiguriert ist (Token + Gruppe + aktiviert)
_tg_ready() {
  _tg_load
  [[ "${CLAU_TG_ENABLED}" == "1" && -n "${CLAU_TG_BOT_TOKEN:-}" && -n "${CLAU_TG_GROUP_ID:-}" ]]
}

# Ruft eine Bot-API-Methode; weitere Args sind curl-Felder (--data-urlencode ...)
_tg_api() {
  local method="$1"; shift
  curl -fsS --max-time 15 \
    "https://api.telegram.org/bot${CLAU_TG_BOT_TOKEN}/${method}" "$@" 2>/dev/null
}

# Setzt/ersetzt einen Schlüssel in der Telegram-Config (behält den Rest)
_tg_conf_set() {
  local k="$1" v="$2"
  mkdir -p "$(dirname "$CLAU_TG_CONF")"
  touch "$CLAU_TG_CONF"; chmod 600 "$CLAU_TG_CONF"
  python3 - "$CLAU_TG_CONF" "$k" "$v" <<'PY'
import sys
f, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(f).read().splitlines()
found = False
out = []
for l in lines:
    if l.startswith(k + "="):
        out.append(f'{k}="{v}"'); found = True
    else:
        out.append(l)
if not found:
    out.append(f'{k}="{v}"')
open(f, "w").write("\n".join(out) + "\n")
PY
}

# Sendet Text; $1 = Topic-Thread-ID (leer = direkt in die Gruppe)
_tg_send() {
  local thread="$1"; local text="$2"
  local args=(--data-urlencode "chat_id=${CLAU_TG_GROUP_ID}" --data-urlencode "text=${text}")
  [[ -n "$thread" ]] && args+=(--data-urlencode "message_thread_id=${thread}")
  _tg_api sendMessage "${args[@]}" >/dev/null 2>&1 || true
}

# Liefert (ggf. neu erstellte) Topic-Thread-ID für eine Session. Leer, wenn die
# Gruppe kein Forum ist (dann gehen Nachrichten ungethreadet in die Gruppe).
_tg_topic_for() {
  local sid="$1" name="$2"
  local reg="${CLAU_TG_STATE_DIR}/topic-${sid}"
  if [[ -f "$reg" ]]; then cat "$reg"; return 0; fi
  local resp tid
  resp="$(_tg_api createForumTopic \
    --data-urlencode "chat_id=${CLAU_TG_GROUP_ID}" \
    --data-urlencode "name=${name}")"
  tid="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["message_thread_id"])
except Exception: pass' 2>/dev/null)"
  if [[ -n "$tid" ]]; then
    mkdir -p "$CLAU_TG_STATE_DIR"
    printf '%s' "$tid" > "$reg"
    echo "$tid"
  fi
}

_tg_close_topic() {
  local sid="$1" thread="$2"
  [[ -n "$thread" ]] || return 0
  _tg_api closeForumTopic \
    --data-urlencode "chat_id=${CLAU_TG_GROUP_ID}" \
    --data-urlencode "message_thread_id=${thread}" >/dev/null 2>&1 || true
  rm -f "${CLAU_TG_STATE_DIR}/topic-${sid}" 2>/dev/null || true
}

# Claude-Code-Hook-Handler: liest Event-JSON von stdin und meldet an Telegram.
# Blockiert NIE die Session (immer exit 0).
tg_hook() {
  # Vom Bot-Modus unterdrückt (sonst würden Headless-Turns Extra-Topics anlegen)
  [[ -n "${CLAU_TG_SUPPRESS:-}" ]] && exit 0
  _tg_ready || exit 0
  local payload; payload="$(cat)"
  [[ -n "$payload" ]] || exit 0
  local parsed
  parsed="$(printf '%s' "$payload" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
def g(k):
    v = d.get(k, "")
    return "" if v is None else str(v)
print("SID=" + g("session_id"))
print("CWD=" + g("cwd"))
print("EV=" + g("hook_event_name"))
msg = str(d.get("message") or "").replace("\n", " ").strip()[:300]
print("MSG=" + msg)
' 2>/dev/null)" || exit 0
  local SID="" CWD="" EV="" MSG="" line
  while IFS= read -r line; do
    case "$line" in
      SID=*) SID="${line#SID=}" ;;
      CWD=*) CWD="${line#CWD=}" ;;
      EV=*)  EV="${line#EV=}" ;;
      MSG=*) MSG="${line#MSG=}" ;;
    esac
  done <<< "$parsed"
  [[ -n "$SID" ]] || exit 0

  local key text
  case "$EV" in
    Notification) key="notification"; text="❓ ${MSG:-Claude braucht deine Eingabe}" ;;
    Stop)         key="stop";         text="🟢 Antwort abgeschlossen." ;;
    SessionEnd)   key="sessionend";   text="✅ Session beendet." ;;
    *) exit 0 ;;
  esac
  # Event-Filter aus CLAU_TG_EVENTS
  [[ ",${CLAU_TG_EVENTS}," == *",${key},"* ]] || exit 0

  local proj; proj="$(basename "${CWD:-$PWD}")"
  local topic_name="📁 ${proj} · ${SID:0:6}"
  local thread; thread="$(_tg_topic_for "$SID" "$topic_name")"
  _tg_send "$thread" "$text"
  [[ "$key" == "sessionend" ]] && _tg_close_topic "$SID" "$thread"
  exit 0
}

# Schreibt die Telegram-Hooks in .claude/settings.json (idempotent)
apply_tg_hooks() {
  _tg_ready || return 0
  local sf=".claude/settings.json"
  mkdir -p .claude
  [[ -f "$sf" ]] || echo '{}' > "$sf"
  local cmd; cmd="$(command -v clau 2>/dev/null || echo clau) --tg-hook"
  python3 - "$sf" "$cmd" <<'PY' 2>/dev/null || true
import sys, json
f, cmd = sys.argv[1], sys.argv[2]
try: s = json.load(open(f))
except Exception: s = {}
hooks = s.setdefault("hooks", {})
def ensure(evt):
    arr = hooks.setdefault(evt, [])
    for grp in arr:
        for h in grp.get("hooks", []):
            if str(h.get("command", "")).endswith("--tg-hook"):
                return
    arr.append({"hooks": [{"type": "command", "command": cmd}]})
for e in ("Notification", "Stop", "SessionEnd"):
    ensure(e)
json.dump(s, open(f, "w"), indent=2)
PY
}

# clau --tg-test : Testnachricht in die Gruppe
tg_test() {
  _tg_load
  [[ -n "${CLAU_TG_BOT_TOKEN:-}" ]] || { echo "Kein Bot-Token in $CLAU_TG_CONF. Erst 'clau --tg-setup'." >&2; exit 1; }
  [[ -n "${CLAU_TG_GROUP_ID:-}" ]] || { echo "Keine Gruppen-ID. Erst 'clau --tg-setup'." >&2; exit 1; }
  local resp
  resp="$(_tg_api sendMessage \
    --data-urlencode "chat_id=${CLAU_TG_GROUP_ID}" \
    --data-urlencode "text=✅ clau-Test von $(hostname): Verbindung steht.")"
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    echo "Testnachricht gesendet an Gruppe ${CLAU_TG_GROUP_ID}."
  else
    echo "Fehler beim Senden: $resp" >&2; exit 1
  fi
}

# clau --tg-setup : Gruppen-ID ermitteln (Bot muss in der Gruppe sein + Nachricht)
tg_setup() {
  _tg_load
  if [[ -z "${CLAU_TG_BOT_TOKEN:-}" ]]; then
    printf "Bot-Token (von @BotFather): "; read -r tok
    [[ -n "$tok" ]] || { echo "Kein Token — abgebrochen." >&2; exit 1; }
    CLAU_TG_BOT_TOKEN="$tok"
    _tg_conf_set CLAU_TG_BOT_TOKEN "$tok"
    _tg_conf_set CLAU_TG_ENABLED "1"
  fi
  echo
  echo "Setup Telegram-Gruppe:"
  echo "  1) Erstelle in Telegram eine Gruppe."
  echo "  2) Gruppen-Einstellungen → 'Themen' (Topics) AKTIVIEREN."
  echo "  3) Füge deinen Bot hinzu und mache ihn zum ADMIN"
  echo "     (Rechte: Nachrichten senden + Themen verwalten)."
  echo "  4) Schreibe irgendeine Nachricht in die Gruppe."
  printf "Danach [Enter] drücken zum Auslesen ... "; read -r _
  local resp ids
  resp="$(_tg_api getUpdates)"
  ids="$(printf '%s' "$resp" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
seen = {}
for u in d.get("result", []):
    for key in ("message","edited_message","channel_post","my_chat_member"):
        m = u.get(key) or {}
        c = m.get("chat") or {}
        if c.get("type") in ("group","supergroup"):
            seen[c["id"]] = (c.get("title","?"), c.get("type"), c.get("is_forum", False))
for cid,(t,ty,forum) in seen.items():
    print(f"{cid}\t{t}\t{ty}\tforum={forum}")
' 2>/dev/null)"
  if [[ -z "$ids" ]]; then
    echo "Keine Gruppe gefunden. Ist der Bot in der Gruppe und wurde eine Nachricht geschrieben?" >&2
    echo "(Roh-Antwort: $resp)" >&2
    exit 1
  fi
  echo "Gefundene Gruppen:"
  local -a arr=()
  while IFS= read -r l; do arr+=("$l"); done <<< "$ids"
  local i=1
  for l in "${arr[@]}"; do
    printf "  %d) %s\n" "$i" "$l"; ((i++))
  done
  local gid
  if [[ "${#arr[@]}" -eq 1 ]]; then
    gid="$(printf '%s' "${arr[0]}" | cut -f1)"
    echo "→ Verwende einzige Gruppe: $gid"
  else
    printf "Nummer der Gruppe: "; read -r idx
    [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#arr[@]} )) || { echo "Ungültig." >&2; exit 1; }
    gid="$(printf '%s' "${arr[$((idx-1))]}" | cut -f1)"
  fi
  # Forum-Warnung
  local is_forum; is_forum="$(printf '%s' "$ids" | grep "^${gid}"$'\t' | grep -o 'forum=[A-Za-z]*' | cut -d= -f2)"
  if [[ "$is_forum" != "True" ]]; then
    echo "⚠️  Achtung: Diese Gruppe hat KEINE Themen aktiviert — es gibt dann kein"
    echo "   Topic pro Session, alle Meldungen landen im Haupt-Chat. Aktiviere 'Themen'"
    echo "   in den Gruppen-Einstellungen für die Topic-pro-Session-Ansicht."
  fi
  _tg_conf_set CLAU_TG_GROUP_ID "$gid"
  echo "Gruppen-ID $gid gespeichert in $CLAU_TG_CONF."
  echo "Test mit:  clau --tg-test"
}

# clau --tg-whoami : eigene Telegram-User-ID ermitteln (für CLAU_TG_ALLOWED_USER)
tg_whoami() {
  _tg_load
  [[ -n "${CLAU_TG_BOT_TOKEN:-}" ]] || { echo "Erst 'clau --tg-setup'." >&2; exit 1; }
  echo "Schreibe JETZT eine Nachricht in die Gruppe, dann [Enter] ..."
  read -r _
  local resp
  resp="$(_tg_api getUpdates)"
  printf '%s' "$resp" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
seen = {}
for u in d.get("result", []):
    m = u.get("message") or {}
    fr = m.get("from") or {}
    if fr.get("id"):
        seen[fr["id"]] = fr.get("username") or fr.get("first_name","?")
if not seen:
    print("Keine Nachricht gefunden — nochmal schreiben und erneut versuchen.")
for uid, name in seen.items():
    print(f"User-ID {uid}  ({name})")
'
  echo
  echo "Trag deine ID in ~/.config/clau/telegram.conf ein:  CLAU_TG_ALLOWED_USER=\"<ID>\""
}

# ── Telegram Phase 2: Bot-Poller (vom Handy entwickeln) ─────────────────────
# Läuft dauerhaft (tmux/systemd). Jede Nachricht in einem Topic wird zu einem
# Claude-Code-Headless-Turn im an das Topic gebundenen Verzeichnis; die Antwort
# geht zurück ins Topic. Session wird pro Topic fortgesetzt (Kontext bleibt).

_tg_bot_state() { echo "${CLAU_TG_STATE_DIR}/chat-${1:-0}"; }

_tg_bind_set() {  # $1=thread $2=key $3=val
  local f; f="$(_tg_bot_state "$1")"; mkdir -p "$CLAU_TG_STATE_DIR"; touch "$f"
  python3 - "$f" "$2" "$3" <<'PY'
import sys
f, k, v = sys.argv[1:4]
lines = [l for l in open(f).read().splitlines() if not l.startswith(k + "=")]
lines.append(f"{k}={v}")
open(f, "w").write("\n".join(lines) + "\n")
PY
}

# Sendet Text in Stücken (Telegram-Limit ~4096 Zeichen)
_tg_send_chunked() {
  local thread="$1" text="$2"
  [[ -n "$text" ]] || { _tg_send "$thread" "（keine Ausgabe）"; return; }
  while [[ -n "$text" ]]; do
    _tg_send "$thread" "${text:0:3800}"
    text="${text:3800}"
  done
}

# Führt einen Claude-Headless-Turn aus; gibt die neue Session-ID auf stdout aus
# und schickt die Antwort ins Topic.
_tg_claude_turn() {  # $1=thread $2=dir $3=sid $4=prompt
  local thread="$1" dir="$2" sid="$3" prompt="$4"
  local -a args=(-p "$prompt" --output-format json --dangerously-skip-permissions)
  [[ -n "$sid" ]] && args=(--resume "$sid" "${args[@]}")
  local raw
  raw="$(cd "$dir" && CLAU_TG_SUPPRESS=1 claude "${args[@]}" 2>&1)" || true
  local parsed result newsid
  parsed="$(printf '%s' "$raw" | python3 -c '
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    print((d.get("result") or "") + "\x1e" + (d.get("session_id") or ""))
except Exception:
    print(raw + "\x1e")
' 2>/dev/null)"
  result="${parsed%%$'\x1e'*}"
  newsid="${parsed##*$'\x1e'}"
  _tg_send_chunked "$thread" "$result"
  printf '%s' "$newsid"
}

# Verarbeitet eine eingehende Nachricht in einem Topic
_tg_bot_handle() {
  local th="$1" txt="$2"
  local DIR="" SID="" line
  while IFS= read -r line; do
    case "$line" in DIR=*) DIR="${line#DIR=}" ;; SID=*) SID="${line#SID=}" ;; esac
  done < <(cat "$(_tg_bot_state "$th")" 2>/dev/null)

  case "$txt" in
    /help*|/start*)
      _tg_send "$th" $'clau-Bot Befehle:\n/cd <pfad>  – Projektordner für dieses Topic setzen\n/pwd        – aktuellen Ordner zeigen\n/new        – neue Session (Kontext zurücksetzen)\nsonst: Text = Anweisung an Claude (im gesetzten Ordner)'
      return ;;
    "/cd "*|"/dir "*)
      local p="${txt#* }"; p="${p/#\~/$HOME}"
      [[ -d "$p" ]] || { _tg_send "$th" "❌ Ordner nicht gefunden: $p"; return; }
      _tg_bind_set "$th" DIR "$p"; _tg_bind_set "$th" SID ""
      _tg_send "$th" "📁 Ordner gesetzt: $p (neue Session)"; return ;;
    /pwd*)
      _tg_send "$th" "📁 ${DIR:-<nicht gesetzt – erst /cd /pfad>}"; return ;;
    /new*)
      _tg_bind_set "$th" SID ""
      _tg_send "$th" "🔄 Neue Session im Ordner ${DIR:-<keiner>}"; return ;;
    /*)
      _tg_send "$th" "❓ Unbekannter Befehl. /help"; return ;;
  esac

  [[ -n "$DIR" ]] || { _tg_send "$th" "❌ Erst Ordner setzen:  /cd /pfad/zum/projekt"; return; }
  _tg_send "$th" "⏳ arbeite ..."
  local newsid; newsid="$(_tg_claude_turn "$th" "$DIR" "$SID" "$txt")"
  [[ -n "$newsid" ]] && _tg_bind_set "$th" SID "$newsid"
}

# clau --tg-bot : Dauer-Poller. Idealerweise in tmux oder als systemd-Service.
tg_bot() {
  _tg_ready || { echo "Telegram nicht konfiguriert — erst 'clau --tg-setup'." >&2; exit 1; }
  command -v claude >/dev/null 2>&1 || { echo "claude nicht gefunden." >&2; exit 1; }
  local allowed="${CLAU_TG_ALLOWED_USER:-}"
  echo "clau Telegram-Bot läuft (Gruppe ${CLAU_TG_GROUP_ID}). Strg-C zum Beenden."
  [[ -z "$allowed" ]] && echo "⚠️  CLAU_TG_ALLOWED_USER nicht gesetzt — JEDER in der Gruppe kann Code ausführen! (clau --tg-whoami)"
  _tg_send "" "🤖 clau-Bot online auf $(hostname). In ein Topic schreiben zum Entwickeln. /help für Befehle."
  local offset=0 resp lines uid cid th fr txt
  while true; do
    resp="$(_tg_api getUpdates --data-urlencode "timeout=30" --data-urlencode "offset=${offset}" --data-urlencode 'allowed_updates=["message"]')" || { sleep 3; continue; }
    lines="$(printf '%s' "$resp" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for u in d.get("result", []):
    m = u.get("message") or {}
    ch = m.get("chat") or {}
    th = m.get("message_thread_id") or 0
    fr = (m.get("from") or {}).get("id", "")
    txt = (m.get("text") or "").replace("\t", " ").replace("\n", " ")
    row = [str(u.get("update_id", "")), str(ch.get("id", "")), str(th), str(fr), txt]
    print("\t".join(row))
' 2>/dev/null)"
    [[ -n "$lines" ]] || continue
    while IFS=$'\t' read -r uid cid th fr txt; do
      [[ -n "$uid" ]] && offset=$((uid + 1))
      [[ "$cid" == "${CLAU_TG_GROUP_ID}" ]] || continue
      if [[ -n "$allowed" && "$fr" != "$allowed" ]]; then
        _tg_send "$th" "⛔ Nicht autorisiert (User $fr)."; continue
      fi
      [[ -n "$txt" ]] || continue
      _tg_bot_handle "$th" "$txt"
    done <<< "$lines"
  done
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

  # Auto-Compact-Threshold: konfigurierbar via CLAU_AUTO_COMPACT_WINDOW (fester Wert)
  # oder CLAU_AUTO_COMPACT_PCT (Prozent von Context-Window, Default 80).
  # claude-CLI respektiert CLAUDE_CODE_AUTO_COMPACT_WINDOW ohne DISABLE_COMPACT zu setzen!
  local cw; cw="$(owl_context_window "$owl_id")"
  if [[ -n "$cw" && "$cw" -gt 0 && "$cw" -lt 1000000 ]]; then
    local compact_target; compact_target="$(compute_auto_compact_window "$cw")"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$compact_target"
    if [[ -n "${CLAU_AUTO_COMPACT_WINDOW:-}" && "${CLAU_AUTO_COMPACT_WINDOW:-}" -gt 0 ]]; then
      echo "Auto-Compact-Window: $compact_target Tokens (fester Wert für owl:$owl_id)"
    else
      local pct="${CLAU_AUTO_COMPACT_PCT:-80}"
      echo "Auto-Compact-Window: $compact_target Tokens (${pct}% von $cw für owl:$owl_id)"
    fi
  else
    unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
  fi

  # Token-Fresser deaktivieren
  token_saver_env >/dev/null

  # Tool-Blocking: generiert/aktualisiert .claude/settings.json
  apply_tool_blocking

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
  echo "Claude Code → Proxy :${port} → QuiteQue (Modell $owl_id${cw:+, ctx=$cw})"
  if [[ -n "$cw" && "$cw" -lt 200000 ]]; then
    echo "Hinweis: Modell $owl_id hat nur $cw Token Kontext."
    echo "         Bei langen Sessions regelmäßig /compact aufrufen,"
    echo "         oder ein größeres Modell wählen (z.B. owl:351 oder owl:361)."
  fi

  # Timeout-Konfiguration: verhindert dass claude den Proxy nach 2 Min killt
  export BASH_DEFAULT_TIMEOUT_MS="${CLAU_TIMEOUT_DEFAULT:-1800000}"
  export BASH_MAX_TIMEOUT_MS="${CLAU_TIMEOUT_MAX:-7200000}"

  local extra; extra="$(_interaction_args)"
  # --force-context ist internes Flag — nicht an claude weiterleiten
  local real_args=()
  for arg in "$@"; do
    [[ "$arg" != "--force-context" ]] && real_args+=("$arg")
  done
  # shellcheck disable=SC2086
  ANTHROPIC_BASE_URL="http://127.0.0.1:${port}" \
  ANTHROPIC_API_KEY="sk-ant-api03-owl-dummy-key-not-real" \
  claude --model "claude-sonnet-4-6" $extra "${real_args[@]}" || true

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

  # Auto-Compact-Threshold: konfigurierbar
  local cw; cw="$(owl_context_window "$owl_id")"
  if [[ -n "$cw" && "$cw" -gt 0 && "$cw" -lt 1000000 ]]; then
    local compact_target; compact_target="$(compute_auto_compact_window "$cw")"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$compact_target"
  else
    unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
  fi

  # Token-Fresser deaktivieren
  token_saver_env >/dev/null

  # Tool-Blocking
  apply_tool_blocking

  local port
  port="$(_start_owl_proxy "$owl_id")"
  trap '_kill_owl_proxy' EXIT INT TERM
  sleep 0.6

  # Timeout-Konfiguration
  export BASH_DEFAULT_TIMEOUT_MS="${CLAU_TIMEOUT_DEFAULT:-1800000}"
  export BASH_MAX_TIMEOUT_MS="${CLAU_TIMEOUT_MAX:-7200000}"

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
    # ./-Präfix: sonst durchsucht `source` erst $PATH (sourcepath) und lädt evtl.
    # eine fremde .clau.conf aus einem PATH-Verzeichnis statt der im aktuellen Ordner.
    # shellcheck disable=SC1090
    source "./$CONFIG_FILE"
  fi
  : "${CLAU_MODEL:=sonnet}"
  : "${CLAU_SESSION_ID:=}"
  : "${CLAU_INTERACTION_LEVEL:=0}"
  : "${CLAU_EFFORT:=}"
  : "${CLAU_SESSION_NAME:=}"
  : "${CLAU_AUTO_COMPACT_ENABLED:=1}"
  : "${CLAU_AUTO_COMPACT_WINDOW:=}"
  : "${CLAU_AUTO_COMPACT_PCT:=80}"
  : "${CLAU_DISABLE_TOOLS:=}"
  : "${CLAU_DISABLE_ARTIFACT:=0}"
  : "${CLAU_DISABLE_AGENT_VIEW:=0}"
  # Timeout: in ms, für Claude Code Bash-Tool + Modell-Inferenz
  : "${CLAU_TIMEOUT_DEFAULT:=1800000}"
  : "${CLAU_TIMEOUT_MAX:=7200000}"
  INTERACTION_LEVEL="$CLAU_INTERACTION_LEVEL"
}

_CONFIG_RO_WARNED=0
_warn_config_readonly() {
  [[ "$_CONFIG_RO_WARNED" -eq 1 ]] && return 0
  _CONFIG_RO_WARNED=1
  echo "⚠️  clau: '$CONFIG_FILE' in $(pwd) nicht beschreibbar – Einstellungen werden diesmal nicht gespeichert." >&2
  echo "   (Die Session selbst wird normal in ~/.claude gespeichert und ist per --resume fortsetzbar.)" >&2
  # Nur interaktiv auf Tastendruck warten – im Headless-/CI-Lauf nicht blockieren.
  [[ "${HEADLESS:-0}" -eq 1 ]] && return 0
  printf "   Weiter mit beliebiger Taste ... " >&2
  read -r -n 1 _ 2>/dev/null || true
  echo >&2
}

save_config() {
  # Verzeichnis nicht beschreibbar (z.B. clau in fremdem Home gestartet)?
  # Dann nur einmal warnen und weitermachen – nicht mit rohem Bash-Fehler abbrechen.
  if [[ -e "$CONFIG_FILE" ]]; then
    [[ -w "$CONFIG_FILE" ]] || { _warn_config_readonly; return 0; }
  else
    [[ -w "." ]] || { _warn_config_readonly; return 0; }
  fi
  cat > "$CONFIG_FILE" <<CONF_EOF
CLAU_MODEL="${CLAU_MODEL}"
CLAU_SESSION_ID="${CLAU_SESSION_ID}"
CLAU_INTERACTION_LEVEL="${CLAU_INTERACTION_LEVEL}"
CLAU_EFFORT="${CLAU_EFFORT:-}"
CLAU_SESSION_NAME="${CLAU_SESSION_NAME:-}"
CLAU_AUTO_COMPACT_ENABLED="${CLAU_AUTO_COMPACT_ENABLED:-1}"
CLAU_AUTO_COMPACT_WINDOW="${CLAU_AUTO_COMPACT_WINDOW:-}"
CLAU_AUTO_COMPACT_PCT="${CLAU_AUTO_COMPACT_PCT:-80}"
CLAU_DISABLE_TOOLS="${CLAU_DISABLE_TOOLS:-}"
CLAU_DISABLE_ARTIFACT="${CLAU_DISABLE_ARTIFACT:-0}"
CLAU_DISABLE_AGENT_VIEW="${CLAU_DISABLE_AGENT_VIEW:-0}"
CLAU_TIMEOUT_DEFAULT="${CLAU_TIMEOUT_DEFAULT:-1800000}"
CLAU_TIMEOUT_MAX="${CLAU_TIMEOUT_MAX:-7200000}"
CONF_EOF
}

# ── Auto-Compact-Logik (konfigurierbar) ──────────────────────────────────────
# Gibt das Auto-Compact-Token-Limit zurück.
# Priorität: 1) CLAU_AUTO_COMPACT_WINDOW (fester Wert)  2) CLAU_AUTO_COMPACT_PCT % von CW  3) 80% Fallback
compute_auto_compact_window() {
  local cw="$1"  # context window des Modells
  if [[ -z "$cw" || "$cw" -le 0 ]]; then
    echo ""
    return
  fi

  if [[ -n "${CLAU_AUTO_COMPACT_WINDOW:-}" && "${CLAU_AUTO_COMPACT_WINDOW:-}" -gt 0 ]]; then
    echo "$CLAU_AUTO_COMPACT_WINDOW"
  else
    local pct="${CLAU_AUTO_COMPACT_PCT:-80}"
    echo $(( cw * pct / 100 ))
  fi
}

# Kurzstatus für die Menüleiste
auto_compact_status() {
  if [[ "${CLAU_AUTO_COMPACT_ENABLED:-1}" == "0" ]]; then
    echo "AUS"
  elif [[ -n "${CLAU_AUTO_COMPACT_WINDOW:-}" && "${CLAU_AUTO_COMPACT_WINDOW:-}" -gt 0 ]]; then
    echo "AN (fest: ${CLAU_AUTO_COMPACT_WINDOW} Tokens)"
  else
    echo "AN (${CLAU_AUTO_COMPACT_PCT:-80}% Context-Window)"
  fi
}

# ── Tool-Blocking (settings.json) ─────────────────────────────────────────────
# Generiert/aktualisiert .claude/settings.json mit deny-Liste für CLAU_DISABLE_TOOLS
apply_tool_blocking() {
  local disable_tools="${CLAU_DISABLE_TOOLS:-}"
  [[ -n "$disable_tools" ]] || return 0

  local settings_dir=".claude"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"

  # Tools aus CLAU_DISABLE_TOOLS als JSON-Array
  local tools_json="["
  local first=1
  IFS=',' read -ra TOOL_LIST <<< "$disable_tools"
  for tool in "${TOOL_LIST[@]}"; do
    tool="$(echo "$tool" | xargs)"  # trim whitespace
    [[ -n "$tool" ]] || continue
    if [[ "$first" -eq 1 ]]; then
      tools_json+="\"$tool\""
      first=0
    else
      tools_json+=", \"$tool\""
    fi
  done
  tools_json+="]"

  # Bestehende settings.json lesen und deny-Liste mergen
  local existing="{}"
  if [[ -f "$settings_file" ]]; then
    existing="$(cat "$settings_file")"
  fi

  # Mit python3 JSON mergen (sicherer als jq das nicht installiert sein muss)
  python3 -c "
import json, sys
existing = json.loads('$existing')
deny = json.loads('$tools_json')
perms = existing.setdefault('permissions', {})
existing_deny = perms.get('deny', [])
for t in deny:
    if t not in existing_deny:
        existing_deny.append(t)
perms['deny'] = existing_deny
print(json.dumps(existing, indent=2))
" > "$settings_file" 2>/dev/null || {
    # Fallback: einfache JSON-Generierung ohne python3
    cat > "$settings_file" <<SETTINGS_EOF
{
  "permissions": {
    "deny": $tools_json
  }
}
SETTINGS_EOF
  }

  echo "Tools blockiert: $disable_tools"
}

# ── Token-Fresser Env-Vars ────────────────────────────────────────────────────
# Gibt die Env-Vars für Token-Optimierung zurück (wird vor claude-Call gesetzt)
token_saver_env() {
  local env_args=""
  if [[ "${CLAU_DISABLE_ARTIFACT:-0}" == "1" ]]; then
    export CLAUDE_CODE_DISABLE_ARTIFACT=1
    env_args+="CLAUDE_CODE_DISABLE_ARTIFACT=1 "
  fi
  if [[ "${CLAU_DISABLE_AGENT_VIEW:-0}" == "1" ]]; then
    export CLAUDE_CODE_DISABLE_AGENT_VIEW=1
    env_args+="CLAUDE_CODE_DISABLE_AGENT_VIEW=1 "
  fi
  echo "$env_args"
}

# Räumt tool-blocking deny-Liste wieder auf (für direkte Claude-Modelle)
cleanup_tool_blocking() {
  local disable_tools="${CLAU_DISABLE_TOOLS:-}"
  [[ -n "$disable_tools" ]] || return 0
  local settings_file=".claude/settings.json"
  [[ -f "$settings_file" ]] || return 0

  IFS=',' read -ra TOOL_LIST <<< "$disable_tools"
  local tools_to_remove=""
  for tool in "${TOOL_LIST[@]}"; do
    tool="$(echo "$tool" | xargs)"
    [[ -n "$tool" ]] || continue
    tools_to_remove+="\"$tool\","
  done

  python3 -c "
import json
with open('$settings_file') as f:
    settings = json.load(f)
remove = [t for t in '$tools_to_remove'.split(',') if t.strip().strip('\"')]
deny = settings.get('permissions', {}).get('deny', [])
deny = [t for t in deny if t not in remove]
if deny:
    settings['permissions']['deny'] = deny
else:
    del settings['permissions']['deny']
    if not settings['permissions']:
        del settings['permissions']
with open('$settings_file', 'w') as f:
    json.dump(settings, f, indent=2)
" 2>/dev/null || true
}

# Räumt token-saver Env-Vars wieder auf (für direkte Claude-Modelle)
unset_token_saver_env() {
  unset CLAUDE_CODE_DISABLE_ARTIFACT
  unset CLAUDE_CODE_DISABLE_AGENT_VIEW
}

print_help() {
  cat <<'HELP_EOF'
clau.sh - Interaktiver & Headless-Wrapper für Claude Code mit per-Ordner-Config

Verwendung (interaktiv):
  clau                            Interaktiver Start: Session/Modell auswählen
  clau --list                     Öffnet den Claude-Resume-Picker
  clau --resume [ID]              Setzt eine Session fort (ohne ID = Resume-Picker)
  clau --new                      Startet eine neue Session
  clau --compact                  Custom-Compact: aktuelle Session extern komprimieren (QuiteQue)
  clau --model N                  Setzt das Standardmodell (1=haiku, 2=sonnet, 3=opus, 4=fable)
  clau --take ID                  Merkt sich eine feste Session-ID für dieses Verzeichnis
  clau --forget                   Entfernt die gemerkte Session-ID
  clau --current                  Zeigt aktuelle Session/Model-Config
  clau --clear-model              Entfernt das gespeicherte Modell
  clau --install                  Installiert "clau" + claude-code + opencode nach ~/.local/bin
  clau --uninstall                Entfernt "clau" aus ~/.local/bin
  clau --self-update              Aktualisiert clau auf die neueste Version aus dem Git-Repo

Telegram / Handy:
  clau --tg-setup                 Ermittelt & speichert die Gruppen-ID (Bot muss in der Gruppe sein)
  clau --tg-test                  Sendet eine Testnachricht in die Gruppe
  clau --tg-whoami                Zeigt deine Telegram-User-ID (für CLAU_TG_ALLOWED_USER)
  clau --tg-bot                   Bot-Poller: vom Handy entwickeln (Dauerprozess, tmux/systemd)
                                  In einem Topic: /cd <pfad> setzen, dann Text = Anweisung an Claude.
  Phase 1 (Benachrichtigung): pro Session ein Topic, meldet Rückfrage/Fertig/Ende.
  Config (lokal, geheim): ~/.config/clau/telegram.conf
    CLAU_TG_ENABLED=1  CLAU_TG_BOT_TOKEN=...  CLAU_TG_GROUP_ID=...
    CLAU_TG_EVENTS="notification,stop,sessionend"  (welche Events melden)
    CLAU_TG_ALLOWED_USER="<id>"  (nur diese Telegram-ID darf per Bot Code ausführen)

Headless / Projekt-Modus:
  clau --headless -p "Prompt"
  clau --headless -p "Prompt" --effort high --max-turns 8 --max-budget-usd 1.5
  clau --new -f /pfad             Neues Projektverzeichnis anlegen und dort interaktiv starten
  clau --new --headless -f /pfad -p "Prompt" -m haiku --effort high --max-turns 8

Headless-Optionen:
  --headless                      Claude im print/headless mode (nicht interaktiv)
  -p, --prompt TEXT               Prompt-Text für headless mode (erforderlich bei --headless)
  -f, --folder PATH               Zielverzeichnis für --new
  -m, --mdl MODEL                 Modell: haiku | sonnet | opus | fable | owl:<ID>
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
  Claude Code (agentisch):  1=haiku(4.5)  2=sonnet(5)  3=opus(5)  4=fable(5)
  owlAPI (lokal/gratis):    5=owl:120  6=owl:243  7=owl:113(Grok)  8=owl:38(QwQ)  9=owl:316  0=owl:free
  owlAPI (günstig/stark):   a=owl:35  b=owl:350  c=owl:503  d=owl:21  e=owl:84  ee=owl:501
  owlAPI direkt:            --model owl:35  oder  -m 350

Token-Optimierung (in .clau.conf konfigurierbar):
  CLAU_AUTO_COMPACT_WINDOW="90000"   Festes Auto-Compact-Limit (leer = Prozent-basiert)
  CLAU_AUTO_COMPACT_PCT="80"         Prozent des Context-Windows (Default 80)
  CLAU_DISABLE_TOOLS="WebFetch,Agent"  Tools aus System-Prompt entfernen (kommagetrennt)
  CLAU_DISABLE_ARTIFACT="1"          Artifacts deaktivieren (spart ~2-3K Tokens)
  CLAU_DISABLE_AGENT_VIEW="1"        Hintergrund-Agenten deaktivieren (spart ~1-2K Tokens)
  CLAU_TIMEOUT_DEFAULT="1800000"     Default Bash-Timeout in ms (30 Min = 1800000)
  CLAU_TIMEOUT_MAX="7200000"         Max Bash-Timeout in ms (120 Min = 7200000)
  CLAU_UPDATE_CHECK="1"              Beim Start gegen GitHub auf Updates prüfen (0 = aus)
  CLAU_UPDATE_CHECK_INTERVAL="86400" Prüf-Intervall in Sekunden (Default 1×/Tag)
HELP_EOF
}

model_from_number() {
  case "${1:-}" in
    1) CLAU_MODEL="haiku" ;;
    2) CLAU_MODEL="sonnet" ;;
    3) CLAU_MODEL="opus" ;;
    4) CLAU_MODEL="fable" ;;     # Claude Fable 5
    5) CLAU_MODEL="owl:120" ;;   # PropellerA lokal
    6) CLAU_MODEL="owl:243" ;;   # Qwopus lokal
    7) CLAU_MODEL="owl:113" ;;   # Grok-4.3 gratis
    8) CLAU_MODEL="owl:38" ;;    # QwQ-Plus gratis
    9) CLAU_MODEL="owl:316" ;;   # Qwen3-Coder OR gratis
    0) CLAU_MODEL="owl:free" ;;  # free Router gratis
    *)
      echo "Unbekanntes Modell-Kürzel: $1 (erlaubt: 1-4=Claude CLI, 5-9/0=owlAPI)" >&2
      exit 1
      ;;
  esac
}

normalize_model_name() {
  case "${1:-}" in
    haiku|sonnet|opus|fable)
      CLI_MODEL_OVERRIDE="$1"
      ;;
    owl:*)
      CLI_MODEL_OVERRIDE="$1"
      ;;
    *)
      # Bare Zahl oder ID → als owl-Modell interpretieren
      if [[ "$1" =~ ^[0-9]+$ ]] || [[ "$1" =~ ^[a-z] ]]; then
        CLI_MODEL_OVERRIDE="owl:$1"
      else
        echo "Ungültiges Modell: $1 (erlaubt: haiku|sonnet|opus|fable oder owl:<ID>)" >&2
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

# Übersetzt den internen Claude-Modell-Kurznamen in die volle Modell-ID, die die
# claude-CLI erwartet. Explizit gepinnt auf die aktuelle Generation (Stand 2026-07):
#   haiku=Haiku 4.5, sonnet=Sonnet 5, opus=Opus 5, fable=Fable 5.
# Bei neuer Generation hier einmalig aktualisieren.
claude_cli_model() {
  case "${1:-}" in
    haiku)  echo "claude-haiku-4-5" ;;
    sonnet) echo "claude-sonnet-5" ;;
    opus)   echo "claude-opus-5" ;;
    fable)  echo "claude-fable-5" ;;
    *) echo "$1" ;;
  esac
}

show_current() {
  local mdl="${CLAU_MODEL:-<nicht gesetzt>}"
  local backend="Claude Code (agentisch)"
  if is_owl_model "${CLAU_MODEL:-}"; then
    backend="owlAPI Chat (${OWL_BASE_URL}, Modell $(owl_model_id "${CLAU_MODEL}"))"
  fi
  echo "Aktuelles Verzeichnis : $(pwd)"
  echo "Konfiguriertes Modell : $mdl"
  echo "Backend               : $backend"
  echo "Session-Name          : ${CLAU_SESSION_NAME:-<keiner>}"
  echo "Feste Session-ID      : ${CLAU_SESSION_ID:-<keine>}"
  echo "Autonomie-Level       : $(interaction_label)"
  echo "Effort                : ${CLAU_EFFORT:-medium (Standard)}"
  echo "sudo NOPASSWD         : $(sudo_is_enabled && echo "AN  ($SUDO_FILE)" || echo "AUS")"
  local cw="$(effective_context_window "${CLAU_MODEL:-}")"
  [[ -n "$cw" ]] && echo "Context-Window          : $cw Tokens"
  local trigger="$(compute_auto_compact_window "${cw:-0}")"
  [[ -n "$trigger" && "$trigger" -gt 0 ]] && echo "Compact-Trigger           : $trigger Tokens"
  echo "Auto-Compact          : $(auto_compact_status)"
  echo "Blockierte Tools      : ${CLAU_DISABLE_TOOLS:-<keine>}"
  echo "Artifacts deaktiviert : ${CLAU_DISABLE_ARTIFACT:-0}"
  echo "Agent-View deaktiviert: ${CLAU_DISABLE_AGENT_VIEW:-0}"
  local owl_id_for_preset=""
  if [[ "${CLAU_MODEL:-}" == owl:* ]]; then owl_id_for_preset="${CLAU_MODEL#owl:}"; fi
  local preset_d="${TIMEOUT_PRESET_DEFAULT[$owl_id_for_preset]:-}"
  local preset_m="${TIMEOUT_PRESET_MAX[$owl_id_for_preset]:-}"
  local preset_indicator=""
  if [[ -n "$preset_d" && "$CLAU_TIMEOUT_DEFAULT" == "$preset_d" && "$CLAU_TIMEOUT_MAX" == "$preset_m" ]]; then
    preset_indicator=" (Preset)"
  elif [[ -n "$preset_d" ]]; then
    preset_indicator=" (angepasst, Preset: $(( preset_d / 60000 )) / $(( preset_m / 60000 )) Min)"
  fi
  echo "Timeout Default        : $(( CLAU_TIMEOUT_DEFAULT / 60000 )) Min (${CLAU_TIMEOUT_DEFAULT} ms)${preset_indicator}"
  echo "Timeout Max            : $(( CLAU_TIMEOUT_MAX / 60000 )) Min (${CLAU_TIMEOUT_MAX} ms)"
}

choose_model_interactive() {
  while true; do
    echo
    echo "Modell wählen:"
    echo "  --- Standard Claude (agentisch, Datei-Editing + Shell) ---"
    echo "  1) haiku              Haiku 4.5   schnell, günstig"
    echo "  2) sonnet             Sonnet 5    Standard         [Enter]"
    echo "  3) opus               Opus 5      stärker, teurer"
    echo "  4) fable              Fable 5     stärkstes Modell"
    echo "  --- LiteLLM Modelle (via Proxy, ${OWL_BASE_URL}) ---"
    echo "  5) PropellerA-27B  lokal   tools+vision  GRATIS"
    echo "  6) Qwopus-9B       lokal   tools schnell GRATIS"
    echo "  7) Grok-4.3        xAI     tools 2M ctx  GRATIS"
    echo "  8) QwQ-Plus        Ali     reasoning     GRATIS"
    echo "  9) Qwen3-Coder     OR      tools 1M ctx  GRATIS"
    echo "  0) free (Router)   ---     mix gratis    GRATIS"
    echo "  a) Qwen-Flash      Ali     tools         \$0.05/\$0.15"
    echo "  b) DeepSeek V4 Pro OR      tools 1M ctx  \$0.44/\$0.87"
    echo "  c) Gemini-Flash    Goog    tools         \$0.10/\$0.40"
    echo "  d) Claude-Sonnet   Anth    tools         \$3.00/\$15.00"
    echo "  e) GPT-5           OAI     tools         \$1.25/\$10.00"
    echo "  ee) Gemini-2.5-Pro Goog    tools         \$1.25/\$10.00"
    echo "  o) LiteLLM ID direkt"
    printf "Auswahl [0-9, a-ee, o, Enter=2]: "
    read -r choice

    case "${choice:-2}" in
      1) CLAU_MODEL="haiku"; break ;;
      2) CLAU_MODEL="sonnet"; break ;;
      3) CLAU_MODEL="opus"; break ;;
      4) CLAU_MODEL="fable"; break ;;
      5) CLAU_MODEL="owl:120"; break ;;
      6) CLAU_MODEL="owl:243"; break ;;
      7) CLAU_MODEL="owl:113"; break ;;
      8) CLAU_MODEL="owl:38"; break ;;
      9) CLAU_MODEL="owl:316"; break ;;
      0) CLAU_MODEL="owl:free"; break ;;
      a|A) CLAU_MODEL="owl:35"; break ;;
      b|B) CLAU_MODEL="owl:350"; break ;;
      c|C) CLAU_MODEL="owl:503"; break ;;
      d|D) CLAU_MODEL="owl:21"; break ;;
      e|E) CLAU_MODEL="owl:84"; break ;;
      ee|EE) CLAU_MODEL="owl:501"; break ;;
      o|O)
        printf "LiteLLM/owlAPI Modell-ID: "
        read -r tmp_id
        if [[ -n "$tmp_id" ]]; then
          CLAU_MODEL="owl:${tmp_id}"
          break
        fi
        echo "Abgebrochen."
        ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done

  # Timeout-Preset für das gewählte Modell anwenden
  apply_timeout_for_model "$CLAU_MODEL"
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
    echo "  0) Vollautomatisch – keine Nachfragen, alle Rechte, läuft stundenlang durch  [Enter]"
    echo "  1) Halbautomatisch – fragt nur bei wesentlichen Dingen (Shellbefehle etc.)"
    echo "  2) Standard        – fragt bei Planung & architektonischen Änderungen"
    printf "Auswahl [0-2, Enter=0]: "
    read -r choice
    case "${choice:-0}" in
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

choose_auto_compact_settings() {
  while true; do
    local cw="$(effective_context_window "${CLAU_MODEL:-}")"
    local trigger="$(compute_auto_compact_window "${cw:-0}")"
    local enabled_label="AN"
    [[ "${CLAU_AUTO_COMPACT_ENABLED:-1}" == "0" ]] && enabled_label="AUS"

    echo
    echo "Auto-Compact-Einstellungen:"
    echo "  Modell-Context-Window : ${cw:-<unbekannt>}"
    [[ -n "$trigger" && "$trigger" -gt 0 ]] && echo "  Compact-Trigger         : $trigger Tokens"
    echo
    echo "  1) Auto-Compact        : $enabled_label"
    echo "  2) Festes Token-Limit  : ${CLAU_AUTO_COMPACT_WINDOW:-<prozent-basiert>}"
    echo "  3) Prozent             : ${CLAU_AUTO_COMPACT_PCT:-80}%"
    echo "  0) Zurück"
    printf "Auswahl [0-3]: "
    read -r choice
    case "${choice:-0}" in
      1)
        # Toggle auto-compact on/off
        if [[ "${CLAU_AUTO_COMPACT_ENABLED:-1}" == "1" ]]; then
          CLAU_AUTO_COMPACT_ENABLED="0"
        else
          CLAU_AUTO_COMPACT_ENABLED="1"
        fi
        save_config
        echo "Auto-Compact: $([[ "$CLAU_AUTO_COMPACT_ENABLED" == "1" ]] && echo "AN" || echo "AUS")"
        ;;
      2)
        printf "Festes Token-Limit (leer = prozent-basiert): "
        read -r val
        if [[ -z "$val" ]]; then
          CLAU_AUTO_COMPACT_WINDOW=""
        elif [[ "$val" =~ ^[0-9]+$ ]]; then
          CLAU_AUTO_COMPACT_WINDOW="$val"
        else
          echo "Ungültige Zahl."
          continue
        fi
        save_config
        echo "Token-Limit: ${CLAU_AUTO_COMPACT_WINDOW:-<prozent-basiert>}"
        ;;
      3)
        printf "Prozent des Context-Window [10-99, Default 80]: "
        read -r val
        if [[ -z "$val" || "$val" == "80" ]]; then
          CLAU_AUTO_COMPACT_PCT="80"
        elif [[ "$val" =~ ^[0-9]+$ && "$val" -ge 10 && "$val" -le 99 ]]; then
          CLAU_AUTO_COMPACT_PCT="$val"
        else
          echo "Ungültig. Muss zwischen 10 und 99 sein."
          continue
        fi
        save_config
        echo "Prozent: ${CLAU_AUTO_COMPACT_PCT}%"
        ;;
      0|"") break ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done
}

choose_timeout_settings() {
  while true; do
    local mdl="${CLAU_MODEL:-}"
    local owl_id=""
    if [[ "$mdl" == owl:* ]]; then
      owl_id="${mdl#owl:}"
    fi

    local preset_default="${TIMEOUT_PRESET_DEFAULT[$owl_id]:-}"
    local preset_max="${TIMEOUT_PRESET_MAX[$owl_id]:-}"
    local preset_label="<kein Preset>"
    if [[ -n "$preset_default" ]]; then
      preset_label="$(( preset_default / 60000 )) Min / $(( preset_max / 60000 )) Min"
    fi

    echo
    echo "Timeout-Einstellungen:"
    echo "  Aktuelles Modell : $mdl"
    echo "  Timeout-Preset   : $preset_label"
    echo "  Default-Timeout  : $(( CLAU_TIMEOUT_DEFAULT / 60000 )) Min (${CLAU_TIMEOUT_DEFAULT} ms)"
    echo "  Max-Timeout      : $(( CLAU_TIMEOUT_MAX / 60000 )) Min (${CLAU_TIMEOUT_MAX} ms)"
    echo
    echo "  1) Default-Timeout  — $(( CLAU_TIMEOUT_DEFAULT / 60000 )) Min"
    echo "  2) Max-Timeout      — $(( CLAU_TIMEOUT_MAX / 60000 )) Min"
    echo "  3) Reset auf Preset — ${preset_label}"
    echo "  0) Zurück"
    printf "Auswahl [0-3]: "
    read -r choice
    case "${choice:-0}" in
      1)
        printf "Default-Timeout in Minuten [1-300]: "
        read -r val
        if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 300 ]]; then
          CLAU_TIMEOUT_DEFAULT=$(( val * 60000 ))
          save_config
          echo "Default-Timeout: $(( CLAU_TIMEOUT_DEFAULT / 60000 )) Min"
        else
          echo "Ungültig. Muss zwischen 1 und 300 sein."
        fi
        ;;
      2)
        printf "Max-Timeout in Minuten [1-600]: "
        read -r val
        if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 600 ]]; then
          CLAU_TIMEOUT_MAX=$(( val * 60000 ))
          save_config
          echo "Max-Timeout: $(( CLAU_TIMEOUT_MAX / 60000 )) Min"
        else
          echo "Ungültig. Muss zwischen 1 und 600 sein."
        fi
        ;;
      3)
        if [[ -n "$preset_default" ]]; then
          CLAU_TIMEOUT_DEFAULT="$preset_default"
          CLAU_TIMEOUT_MAX="$preset_max"
          save_config
          echo "Reset auf Preset: $(( CLAU_TIMEOUT_DEFAULT / 60000 )) Min / $(( CLAU_TIMEOUT_MAX / 60000 )) Min"
        else
          echo "Kein Preset für dieses Modell. Verwende Standard (30 Min / 120 Min)."
          CLAU_TIMEOUT_DEFAULT="1800000"
          CLAU_TIMEOUT_MAX="7200000"
          save_config
        fi
        ;;
      0|"") break ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done
}

choose_bot_settings() {
  while true; do
    echo
    echo "Bot-Einstellungen:"
    echo "  1) Autonomie-Level  — ${INTERACTION_LEVEL:-2}: $(interaction_label)"
    echo "  2) sudo NOPASSWD    — $(sudo_is_enabled && echo "AN  [$SUDO_FILE]" || echo "AUS")"
    echo "  3) Effort           — ${CLAU_EFFORT:-medium}  (nur Claude)"
    echo "  4) Auto-Compact     — $(auto_compact_status)"
    echo "  5) Timeout          — $(( CLAU_TIMEOUT_DEFAULT / 60000 )) Min / $(( CLAU_TIMEOUT_MAX / 60000 )) Min"
    echo "  0) Zurück"
    printf "Auswahl [0-5]: "
    read -r choice
    case "${choice:-0}" in
      1) choose_interaction_interactive ;;
      2) toggle_sudo ;;
      3) choose_effort_interactive ;;
      4) choose_auto_compact_settings ;;
      5) choose_timeout_settings ;;
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

_have() { command -v "$1" >/dev/null 2>&1; }

# Installiert claude-code falls nicht vorhanden (native Installer, npm-Fallback)
_ensure_claude_code() {
  if _have claude; then
    echo "  claude-code: bereits vorhanden ($(command -v claude))"
    return 0
  fi
  echo "  claude-code: nicht gefunden — installiere ..."
  if _have curl; then
    if curl -fsSL https://claude.ai/install.sh | bash; then return 0; fi
  fi
  if _have npm; then
    if npm install -g @anthropic-ai/claude-code; then return 0; fi
  fi
  echo "  WARN: claude-code konnte nicht installiert werden (curl/npm fehlen oder Fehler)." >&2
  return 1
}

# Installiert opencode falls nicht vorhanden (native Installer, npm-Fallback)
_ensure_opencode() {
  if _have opencode; then
    echo "  opencode: bereits vorhanden ($(command -v opencode))"
    return 0
  fi
  echo "  opencode: nicht gefunden — installiere ..."
  if _have curl; then
    if curl -fsSL https://opencode.ai/install | bash; then return 0; fi
  fi
  if _have npm; then
    if npm install -g opencode-ai; then return 0; fi
  fi
  echo "  WARN: opencode konnte nicht installiert werden (curl/npm fehlen oder Fehler)." >&2
  return 1
}

install_self() {
  local script_path target_path
  script_path="$(readlink -f "$0")"
  target_path="${INSTALL_DIR}/${INSTALL_NAME}"

  mkdir -p "$INSTALL_DIR"
  chmod +x "$script_path"
  ln -sfn "$script_path" "$target_path"

  echo "Installiert: $target_path -> $script_path"

  # Abhängigkeiten automatisch mitinstallieren (idempotent, überspringt Vorhandenes)
  echo
  echo "Prüfe/Installiere Abhängigkeiten ..."
  _ensure_claude_code || true
  _ensure_opencode || true

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

  echo
  echo "Fertig. 'clau' ist einsatzbereit."
  _have claude   || echo "  Hinweis: 'claude' evtl. erst nach Shell-Neustart im PATH."
  _have opencode || echo "  Hinweis: 'opencode' evtl. erst nach Shell-Neustart im PATH."
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

# ── Update-Check gegen GitHub (throttled, non-blocking) ──────────────────────
# Prüft max. 1×/Tag ob origin/<branch> neuer ist und weist den Nutzer darauf hin.
# Offline/kein-Netz/keine-Berechtigung → stumm ignorieren. Deaktivierbar via
# CLAU_UPDATE_CHECK=0; Intervall via CLAU_UPDATE_CHECK_INTERVAL (Sekunden).
_update_stamp_file() {
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/clau"
  mkdir -p "$cache" 2>/dev/null || true
  echo "$cache/last_update_check"
}

check_for_updates() {
  [[ "${CLAU_UPDATE_CHECK:-1}" == "1" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0

  local repo_dir
  repo_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # Throttle: nur alle CLAU_UPDATE_CHECK_INTERVAL Sekunden (Default 1 Tag)
  local interval="${CLAU_UPDATE_CHECK_INTERVAL:-86400}"
  local stamp now last
  stamp="$(_update_stamp_file)"
  now="$(date +%s)"
  if [[ -f "$stamp" ]]; then
    last="$(cat "$stamp" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last < interval )) && return 0
  fi
  echo "$now" > "$stamp" 2>/dev/null || true

  local branch
  branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || branch="main"

  # Leiser fetch mit hartem Timeout, keine SSH-/Passwort-Prompts (nicht blockieren)
  GIT_TERMINAL_PROMPT=0 timeout 5 git -C "$repo_dir" fetch --quiet origin "$branch" 2>/dev/null || return 0

  local behind
  behind="$(git -C "$repo_dir" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"
  [[ "$behind" =~ ^[0-9]+$ ]] || return 0
  (( behind > 0 )) || return 0

  echo
  echo "🔄 clau: Update verfügbar ($behind neue(r) Commit(s) auf origin/$branch)."
  printf "   Jetzt aktualisieren? [j/N]: "
  local ans; read -r ans
  case "${ans:-N}" in
    j|J|y|Y)
      self_update
      echo
      echo "Bitte 'clau' erneut starten, um die neue Version zu nutzen."
      exit 0
      ;;
    *)
      echo "   Später mit:  clau --self-update"
      echo
      ;;
  esac
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
  echo "Öffne Session-Auswahl (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  cleanup_tool_blocking
  unset_token_saver_env
  apply_tg_hooks
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  exec claude --resume --model "$(claude_cli_model "$mdl")" $extra
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
  echo "Starte feste Session $CLAU_SESSION_ID (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  cleanup_tool_blocking
  unset_token_saver_env
  apply_tg_hooks
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  exec claude --resume "$CLAU_SESSION_ID" --model "$(claude_cli_model "$mdl")" $extra
}

run_new_session() {
  local mdl
  mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if is_owl_model "$mdl"; then
    run_owl_via_claude "$(owl_model_id "$mdl")" --force-context
    return
  fi
  echo "Starte neue Session (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  cleanup_tool_blocking
  unset_token_saver_env
  apply_tg_hooks
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  exec claude --model "$(claude_cli_model "$mdl")" $extra
}

# Setzt eine konkrete Session-ID fort (z.B. nach custom-compact)
run_resume_id() {
  local rid="$1"
  local mdl; mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if is_owl_model "$mdl"; then
    run_owl_via_claude "$(owl_model_id "$mdl")" --resume "$rid"
    return
  fi
  echo "Setze Session $rid fort (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  cleanup_tool_blocking
  unset_token_saver_env
  apply_tg_hooks
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  exec claude --resume "$rid" --model "$(claude_cli_model "$mdl")" $extra
}

# Custom-Compact: komprimiert die aktuelle Session extern via QuiteQue (cc_compact.py)
# und bietet an, die neue (kleinere) Session direkt fortzusetzen. Gedacht für
# Sessions, die nicht mehr in den Kontext eines lokalen Modells passen.
run_compact() {
  if [[ ! -f "$CC_COMPACT_SCRIPT" ]]; then
    echo "Fehler: cc_compact.py nicht gefunden: $CC_COMPACT_SCRIPT" >&2
    exit 1
  fi
  local mdl; mdl="$(effective_model)"
  local sum_id="120"  # Default-Summary-Modell (PropellerA lokal)
  if is_owl_model "$mdl"; then
    sum_id="$(owl_model_id "$mdl")"
  fi
  echo "Starte custom-compact (Summary-Modell: $sum_id) im Projekt $(pwd) ..."
  local tmpf; tmpf="$(mktemp)"
  python3 "$CC_COMPACT_SCRIPT" --model "$sum_id" 2>&1 | tee "$tmpf"
  local rc=${PIPESTATUS[0]}
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmpf"
    echo "custom-compact fehlgeschlagen (Exit $rc)." >&2
    exit 1
  fi
  local new_id
  new_id="$(sed -n 's/.*Neue Session-ID:[[:space:]]*\([0-9a-fA-F-]*\).*/\1/p' "$tmpf" | tail -1)"
  rm -f "$tmpf"
  if [[ -z "$new_id" ]]; then
    echo "Konnte neue Session-ID nicht aus der Ausgabe ermitteln." >&2
    exit 1
  fi
  echo
  echo "Komprimierte Session: $new_id"
  printf "Jetzt fortsetzen? [J/n]: "
  read -r ans
  case "${ans:-J}" in
    n|N) echo "Später fortsetzen mit: clau --resume $new_id" ;;
    *) run_resume_id "$new_id" ;;
  esac
}

build_headless_cmd() {
  local mdl
  mdl="$(effective_model)"

  CLAUDE_CMD=(claude)

  if [[ -n "$mdl" ]]; then
    CLAUDE_CMD+=(--model "$(claude_cli_model "$mdl")")
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
  build_headless_cmd
  apply_tg_hooks
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
  echo "Projektverzeichnis bereit für headless: $dir"
  (
    cd "$dir"
    build_headless_cmd
    apply_tg_hooks
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
      # ./-Präfix: sonst sucht `source` erst in $PATH (siehe load_config)
      source "./$CONFIG_FILE"
      : "${CLAU_MODEL:=}"
    fi
    if [[ -z "${CLAU_MODEL:-}" ]]; then
      while true; do
        echo
        echo "Bitte Modell wählen:"
        echo "  1) haiku   Haiku 4.5   schnell, günstig"
        echo "  2) sonnet  Sonnet 5    Standard"
        echo "  3) opus    Opus 5      stärker, teurer"
        echo "  4) fable   Fable 5     stärkstes Modell"
        printf "Auswahl [1-4, Enter=2]: "
        read -r choice
        case "${choice:-2}" in
          1) CLAU_MODEL="haiku"; break ;;
          2) CLAU_MODEL="sonnet"; break ;;
          3) CLAU_MODEL="opus"; break ;;
          4) CLAU_MODEL="fable"; break ;;
          *) echo "Ungültige Auswahl." ;;
        esac
      done
      cat > "$CONFIG_FILE" <<EOF
CLAU_MODEL="${CLAU_MODEL}"
CLAU_SESSION_ID=""
CLAU_INTERACTION_LEVEL="${CLAU_INTERACTION_LEVEL:-0}"
EOF
    fi
    echo "Starte neue Session im Projekt mit Modell ${CLAU_MODEL} ..."
    if ! is_owl_model "${CLAU_MODEL}"; then
      cleanup_tool_blocking
      unset_token_saver_env
      apply_tg_hooks
    fi
    exec claude --model "$(claude_cli_model "${CLAU_MODEL}")"
  )
}

interactive_start() {
  ensure_model

  local mdl; mdl="$(effective_model)"
  local tag
  if is_owl_model "$mdl"; then
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
  echo "  5) Session komprimieren (custom-compact via QuiteQue)"
  printf "Auswahl [1-5, Enter=2]: "
  read -r start_choice

  case "${start_choice:-2}" in
    1) run_resume_picker ;;
    2) run_new_session_named ;;
    3) choose_model_interactive; interactive_start ;;
    4) choose_bot_settings; interactive_start ;;
    5) run_compact ;;
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
          echo "--model erwartet eine Zahl (1=haiku, 2=sonnet, 3=opus, 4=fable)" >&2
          exit 1
        fi
        model_from_number "$2"
        save_config
        echo "Standardmodell gesetzt auf: $CLAU_MODEL"
        exit 0
        ;;
      -m|--mdl)
        if [[ -z "${2:-}" ]]; then
          echo "-m/--mdl erwartet ein Modell: haiku|sonnet|opus|fable|owl:<ID>" >&2
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
      --resume)
        if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
          ACTION="list"   # ohne ID → Resume-Picker
          shift
        else
          ACTION="resume"
          RESUME_SESSION_ID="$2"
          shift 2
        fi
        ;;
      --compact)
        ACTION="compact"
        shift
        ;;
      --tg-setup)
        ACTION="tg-setup"
        shift
        ;;
      --tg-test)
        ACTION="tg-test"
        shift
        ;;
      --tg-whoami)
        ACTION="tg-whoami"
        shift
        ;;
      --tg-bot)
        ACTION="tg-bot"
        shift
        ;;
      --tg-hook)
        ACTION="tg-hook"
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
RESUME_SESSION_ID=""

load_config
parse_args "$@"

# Telegram-Hook: sofort abarbeiten (kein Update-Check, kein Menü) — muss schnell sein
if [[ "${ACTION}" == "tg-hook" ]]; then
  tg_hook
  exit 0
fi

# Update-Check nur für interaktive Läufe (nicht headless/CI/tg)
case "${ACTION}" in
  tg-setup|tg-test|tg-whoami|tg-bot) : ;;
  *) [[ "${HEADLESS:-0}" -eq 1 ]] || check_for_updates ;;
esac

case "${ACTION}" in
  list)
    ensure_model
    run_resume_picker
    ;;
  resume)
    ensure_model
    run_resume_id "$RESUME_SESSION_ID"
    ;;
  compact)
    run_compact
    ;;
  tg-setup)
    tg_setup
    ;;
  tg-test)
    tg_test
    ;;
  tg-whoami)
    tg_whoami
    ;;
  tg-bot)
    tg_bot
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
