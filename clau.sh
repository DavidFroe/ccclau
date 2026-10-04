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
WEBSEARCH_MCP_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/websearch_mcp.py"
LLM_STATUS_MCP_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/llm_status_mcp.py"
CLAU_TEAM_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/team"
PI_TEAM_MCP_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pi_team_mcp.py"
CLAU_API_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/clau_api.py"
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
  ["121"]="97000"   # Qwen3.8-Flash-Next: 176B MoE, Tools+Vision+Reasoning (3 Slots à 99k)
  ["126"]="262000"  # Qwen3.8-Flash-Next: 176B MoE, 262k, nur 1 Session
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

# ── Live-Modellliste der owlAPI ──────────────────────────────────────────────
# /v1/models liefert ID, Name, Kontext, Anbieter, Status und Preis. Gecacht in
# $OWL_MODELS_CACHE; älter als OWL_MODELS_TTL Sekunden → neu holen (3 s Timeout).
# Ist die owlAPI nicht erreichbar, gilt der alte Cache, danach die Tabelle oben.
OWL_MODELS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/clau/owl_models.json"
OWL_MODELS_TTL="${OWL_MODELS_TTL:-3600}"

# $1 = "force" → Cache ignorieren. Rückgabe 0, wenn ein (evtl. alter) Cache da ist.
_owl_models_refresh() {
  local age=999999
  if [[ -f "$OWL_MODELS_CACHE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$OWL_MODELS_CACHE" 2>/dev/null || echo 0) ))
  fi
  if [[ "${1:-}" == "force" || "$age" -gt "$OWL_MODELS_TTL" ]]; then
    mkdir -p "$(dirname "$OWL_MODELS_CACHE")" 2>/dev/null
    local tmp="${OWL_MODELS_CACHE}.tmp.$$"
    if curl -sf -m 3 "${OWL_BASE_URL}/v1/models" \
         -H "X-User: ${CLAU_USER_TAG:-$(whoami)}" \
         -H "X-Agent-Tool: ${CLAU_AGENT_TOOL:-ccclau-$(whoami)}" -o "$tmp" 2>/dev/null \
       && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["data"]' "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$OWL_MODELS_CACHE"
    else
      rm -f "$tmp"
    fi
  fi
  [[ -f "$OWL_MODELS_CACHE" ]]
}

# Chat-taugliche Modelle als TSV: id status anbieter ctx preis name
# Sortiert: lokal → gratis → nach Anbieter, darin nach Eingabepreis. Ohne Bild/Audio/Suche.
_owl_models_tsv() {
  _owl_models_refresh "${1:-}" || return 1
  python3 - "$OWL_MODELS_CACHE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["data"]
skip_owner = {"searchllm", "ohrwurm"}
rows = []
for m in data:
    ctx = m.get("context_window") or 0
    st = m.get("status") or ""
    if ctx <= 0 or st == "DISABLED" or m.get("owned_by") in skip_owner:
        continue
    p = m.get("pricing") or {}
    free = bool(p.get("is_free"))
    price = "GRATIS" if free else "$%.2f/$%.2f" % (p.get("input_per_mtok", 0), p.get("output_per_mtok", 0))
    order = {"alibaba": 2, "openrouter": 3, "deepseek": 4, "xai": 5, "claude": 6, "anthropic": 6}
    own = m.get("owned_by")
    grp = 0 if own == "propellera" else (1 if free else order.get(own, 7))
    rows.append((grp, p.get("input_per_mtok", 0) or 0, str(m["numerical_id"]), st,
                 m.get("owned_by", ""), str(ctx), price, (m.get("name") or "").replace("\t", " ")))
rows.sort(key=lambda r: (r[0], r[1]))
for r in rows:
    print("\t".join(r[2:]))
PY
}

owl_context_window() {
  local owl_id="${1:-}"
  local cw=""
  if _owl_models_refresh 2>/dev/null; then
    cw="$(python3 -c '
import json, sys
for m in json.load(open(sys.argv[1]))["data"]:
    if str(m.get("numerical_id")) == sys.argv[2]:
        print(m.get("context_window") or ""); break' "$OWL_MODELS_CACHE" "$owl_id" 2>/dev/null)"
  fi
  [[ -n "$cw" && "$cw" -gt 0 ]] 2>/dev/null || cw="${OWL_CONTEXT_WINDOWS[$owl_id]:-}"
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
    echo "1000000"   # Opus 5.5: 1M Kontext
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
  ["121"]="1800000"  # Qwen3.8-Flash-Next (176B MoE, 97k) → 30 Min
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
  ["121"]="3600000"  # Qwen3.8-Flash-Next → 60 Min
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
    if [[ -z "$preset_default" ]]; then
      # Nicht in der Tabelle (z.B. neues Modell aus der Live-Liste): nach Kontext.
      local cw; cw="$(owl_context_window "$owl_id")"
      if [[ -n "$cw" && "$cw" -ge 500000 ]]; then
        preset_default="3600000"; preset_max="10800000"   # 60 / 180 Min
      elif [[ -n "$cw" ]]; then
        preset_default="1800000"; preset_max="3600000"    # 30 / 60 Min
      fi
    fi
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

# Session-Datei zu einer konkreten Session-ID im Projekt-Bucket von $PWD.
_session_file_for_id() {
  local sid="${1:-}"
  [[ -n "$sid" ]] || return 1
  local ph; ph="$(_project_hash_for "${2:-$PWD}")"
  local sf; sf="$(_claude_projects_dir)/${ph}/${sid}.jsonl"
  [[ -f "$sf" ]] || return 1
  echo "$sf"
}

# ── User-Session-Titel ───────────────────────────────────────────────────────
# Sidecar-JSON pro Projekt-Bucket ({"<sessionId>": "Titeltext"}) statt neuer
# Zeilentyp in der Claude-Code-JSONL selbst -- das Format liest `claude
# --resume` direkt, ein Sidecar ist risikofrei und leicht aufzuräumen.
_session_titles_file() {
  echo "${1}/.clau-session-titles.json"
}

_get_session_title() {
  local proj_dir="$1" sid="$2"
  local tf; tf="$(_session_titles_file "$proj_dir")"
  [[ -f "$tf" ]] || return 0
  python3 - "$tf" "$sid" <<'PY' 2>/dev/null
import json
import sys

path, sid = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        titles = json.load(f)
except Exception:
    titles = {}
print(titles.get(sid, ""))
PY
}

_set_session_title() {
  local proj_dir="$1" sid="$2" title="$3"
  local tf; tf="$(_session_titles_file "$proj_dir")"
  python3 - "$tf" "$sid" "$title" <<'PY'
import json
import sys

path, sid, title = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        titles = json.load(f)
except Exception:
    titles = {}
if title:
    titles[sid] = title
else:
    titles.pop(sid, None)
with open(path, "w") as f:
    json.dump(titles, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

_delete_session_title() {
  local proj_dir="$1" sid="$2"
  local tf; tf="$(_session_titles_file "$proj_dir")"
  [[ -f "$tf" ]] || return 0
  _set_session_title "$proj_dir" "$sid" ""
}

_estimate_session_tokens() {
  # Liest die letzte usage-Zeile und gibt geschätzte Kontext-Tokens zurück
  # (= input_tokens + cache_read_input_tokens + cache_creation_input_tokens).
  # Meldet das Backend keine input_tokens (alte owl_proxy-Versionen schrieben
  # dort immer 0), wird stattdessen aus der Session-Datei geschätzt — sonst
  # sieht der Pre-Flight-Check eine 100k-Session als "leer" an.
  local sf="${1:-}"
  [[ -f "$sf" ]] || { echo "0"; return 1; }
  # Wir nehmen die letzte Zeile mit non-empty usage
  python3 - "$sf" <<'PYEOF' 2>/dev/null || echo "0"
import json, sys

# Fallback-Schätzung, wenn keine echten usage-Zahlen in der Session stehen.
# System-Prompt + Tool-Definitionen liegen nicht in der Session-Datei, gehen
# aber bei jedem Request mit ans Modell — grober Aufschlag dafür.
OVERHEAD_TOKENS = 20000
CHARS_PER_TOKEN = 3.5

sf = sys.argv[1]
last_in = 0
last_cache_read = 0
last_cache_creation = 0
rows = []
with open(sf) as f:
    for line in f:
        try:
            d = json.loads(line)
        except Exception:
            continue
        rows.append(d)
        u = (d.get('message') or {}).get('usage') or {}
        if u:
            last_in = u.get('input_tokens', 0) or 0
            last_cache_read = u.get('cache_read_input_tokens', 0) or 0
            last_cache_creation = u.get('cache_creation_input_tokens', 0) or 0

total = last_in + last_cache_read + last_cache_creation
if total > 0:
    print(total)
    sys.exit(0)


def block_chars(b):
    # thinking-Blöcke stehen zwar in der Session, werden aber nie wieder ans
    # Modell geschickt — sie zählen nicht zum Kontext des nächsten Requests.
    if isinstance(b, dict) and b.get('type') in ('thinking', 'redacted_thinking'):
        return 0
    return len(json.dumps(b, ensure_ascii=False))


# Alles vor der letzten Compact-Grenze ist bereits zusammengefasst und wird
# nicht mehr mitgeschickt.
start = 0
for i, d in enumerate(rows):
    if d.get('subtype') == 'compact_boundary':
        start = i

chars = 0
for d in rows[start:]:
    if d.get('isSidechain') or d.get('type') not in ('user', 'assistant'):
        continue
    content = (d.get('message') or {}).get('content')
    if isinstance(content, str):
        chars += len(content)
    elif isinstance(content, list):
        chars += sum(block_chars(b) for b in content)

if chars > 0:
    print(int(chars / CHARS_PER_TOKEN) + OVERHEAD_TOKENS)
else:
    print("0")
PYEOF
}

# Komprimiert eine konkrete Session-Datei via cc_compact.py (--session sorgt
# dafür, dass wirklich DIESE Datei komprimiert wird, nicht "die neueste im
# Verzeichnis" — bei vielen parallelen Sessions im selben Projekt-Bucket
# sonst nicht verlässlich). Gibt die neue Session-ID auf stdout aus,
# leer bei Fehler.
_compact_session_file() {
  local sf="$1" target_model="$2"
  local tmpf; tmpf="$(mktemp)"
  _owl_activity_env "compact"
  OWL_HDR_AGENT_TOOL="$OWL_HDR_AGENT_TOOL" OWL_HDR_REQUEST_CONTEXT="$OWL_HDR_REQUEST_CONTEXT" \
  OWL_HDR_PROJECT="$OWL_HDR_PROJECT" OWL_HDR_USER="$OWL_HDR_USER" \
    python3 "$CC_COMPACT_SCRIPT" --session "$sf" --model "$target_model" >"$tmpf" 2>&1
  local rc=$?
  cat "$tmpf" >&2
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmpf"
    return 1
  fi
  local new_id
  new_id="$(sed -n 's/.*Neue Session-ID:[[:space:]]*\([0-9a-fA-F-]*\).*/\1/p' "$tmpf" | tail -1)"
  rm -f "$tmpf"
  [[ -n "$new_id" ]] || return 1
  echo "$new_id"
}

# Wird von _pre_flight_check gesetzt, wenn automatisch komprimiert wurde —
# der Aufrufer soll dann auf diese Session-ID umlenken statt auf der zu
# großen weiterzumachen.
PRE_FLIGHT_RESUME_ID=""

_pre_flight_check() {
  local owl_id="$1"
  local session_id="${2:-}"
  local cw; cw="$(owl_context_window "$owl_id")"
  [[ -n "$cw" && "$cw" -gt 0 ]] || return 0  # kein Check möglich (z.B. Claude direkt)

  # Wird eine bestimmte Session fortgesetzt, muss GENAU die geprüft werden —
  # die neueste Datei im Projekt-Bucket ist bei --resume oft eine andere
  # (und meldete dann fälschlich "leere Session").
  local sf=""
  if [[ -n "$session_id" ]]; then
    sf="$(_session_file_for_id "$session_id" 2>/dev/null)"
  fi
  [[ -n "$sf" ]] || sf="$(_latest_session_file 2>/dev/null)"
  [[ -n "$sf" && -f "$sf" ]] || { echo "✓ Pre-Flight: keine Session gefunden, starte neu"; return 0; }

  local tokens; tokens="$(_estimate_session_tokens "$sf")"
  tokens="${tokens:-0}"
  [[ "$tokens" -eq 0 ]] && { echo "✓ Pre-Flight: leere Session, starte"; return 0; }

  local pct=$(( tokens * 100 / cw ))
  local sf_name; sf_name="$(basename "$sf")"

  if [[ "$tokens" -gt "$cw" ]]; then
    # Kein automatisches eigenes Compact mehr: Claude Code kompaktiert selbst.
    # Lehnt das Backend den Prompt als zu lang ab, übersetzt owl_proxy das in
    # "prompt is too long: N > M" -- darauf reagiert Claude Code mit seiner
    # eigenen Rettung (Notfall-Compact, ältesten Verlauf abschneiden).
    cat >&2 <<EOF
⚠ Pre-Flight: Session hat ~$tokens Tokens ($pct% von $cw) — größer als das Fenster von owl:$owl_id.
  Claude Code startet trotzdem und kompaktiert selbst.
  Eigenes Compact über QuiteQue bei Bedarf: clau → Menüpunkt 5 (oder clau --compact).
EOF
    return 0
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
OWL_PROXY_LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/clau"
OWL_PROXY_LOG_FILE="${OWL_PROXY_LOG_DIR}/owl_proxy.log"

# Modellname, den Claude Code im owl-Pfad bekommt (owl_proxy ignoriert ihn).
# Claude Code traut "claude-sonnet-4-6" nur 200k zu und deckelt die
# Compact-Grenze darauf; mit "[1m]" rechnet es mit 1M, dann greift unser
# CLAUDE_CODE_AUTO_COMPACT_WINDOW auch bei großen owl-Modellen.
# Im Team-Modus heißt das Modell "owl-<ID>" (owl_cli_model) -- für Claude Code
# unbekannt, das Fenster kommt dann über CLAUDE_CODE_MAX_CONTEXT_TOKENS
# (_owl_cc_context_env), "[1m]" bleibt weg, damit der Proxy-Router den Namen
# unverändert sieht.
_owl_cc_model() {
  local cw="${1:-0}" base; base="$(owl_cli_model)"
  if ! team_active && [[ -n "$cw" && "$cw" -gt 200000 ]]; then echo "${base}[1m]"; else echo "$base"; fi
}

_owl_cc_context_env() {
  local cw="${1:-0}"
  if team_active && [[ -n "$cw" && "$cw" -gt 0 ]]; then
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$cw"
  fi
}

_start_owl_proxy() {
  local owl_id="$1"
  local port
  port="$(_free_port)"
  mkdir -p "$OWL_PROXY_LOG_DIR" 2>/dev/null || true
  # Rollen-Sessions der Fernsteuerung laufen parallel -- eigenes Log je Rolle,
  # sonst kappen sie sich gegenseitig die gemeinsame Datei.
  [[ -n "${CLAU_API_ROLE:-}" ]] && OWL_PROXY_LOG_FILE="${OWL_PROXY_LOG_DIR}/owl_proxy-${CLAU_API_ROLE}.log"
  # Log-Datei bei jedem Start kappen statt endlos wachsen zu lassen
  : > "$OWL_PROXY_LOG_FILE" 2>/dev/null || true
  _owl_activity_env "chat"
  # Team-Modus: parallele Agent-Requests durchlassen, aber höchstens
  # CLAU_TEAM_SLOTS_<ID> gleichzeitig ans Ausführer-Modell (Rest wartet im Proxy).
  local threaded=0 slot_limits=""
  if team_active; then
    threaded=1
    slot_limits="$(team_exec_model)=$(_team_exec_slots)"
  fi
  OWL_PROXY_THREADED="$threaded" OWL_SLOT_LIMITS="$slot_limits" OWL_ROUTES="${CLAU_OWL_ROUTES:-}" \
  OWL_PROXY_PORT="$port" OWL_MODEL="$owl_id" OWL_BASE_URL="${OWL_BASE_URL}/v1" OWL_PROXY_USER="$QQ_USER" \
    OWL_PROXY_TIMEOUT="${CLAU_OWL_TIMEOUT:-1800}" OWL_CTX_LIMIT="$(owl_context_window "$owl_id")" \
    OWL_HDR_AGENT_TOOL="$OWL_HDR_AGENT_TOOL" OWL_HDR_REQUEST_CONTEXT="$OWL_HDR_REQUEST_CONTEXT" \
    OWL_HDR_PROJECT="$OWL_HDR_PROJECT" OWL_HDR_USER="$OWL_HDR_USER" \
    python3 "$OWL_PROXY_SCRIPT" "$port" >>"$OWL_PROXY_LOG_FILE" 2>&1 &
  echo "$!" > "$_OWL_PID_FILE"
  echo "$port"
}

_kill_owl_proxy() {
  if [[ -f "$_OWL_PID_FILE" ]]; then
    local pid; pid="$(cat "$_OWL_PID_FILE" 2>/dev/null || true)"
    rm -f "$_OWL_PID_FILE"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  fi
  rm -f "${OWL_PROXY_LOG_DIR}/team_anweisung_$$.md" 2>/dev/null || true
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
  # Concierge ("Bot-Hirn"): kleines Modell auf der vorhandenen QuiteQue-Infrastruktur
  : "${CLAU_TG_BRAIN:=1}"
  : "${CLAU_TG_BRAIN_MODEL:=gemma-12b-chat}"
  : "${CLAU_TG_PROJECT_ROOT:=$HOME}"
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

  # PC-Session pro Ordner merken → Handy kann sie per /weiter übernehmen
  if [[ -n "$CWD" ]]; then
    mkdir -p "$CLAU_TG_STATE_DIR" 2>/dev/null || true
    printf '%s' "$SID" > "${CLAU_TG_STATE_DIR}/lastpc-$(printf '%s' "$CWD" | tr -c 'A-Za-z0-9' '_')" 2>/dev/null || true
  fi

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

# Schreibt die Telegram-Hooks in die GLOBALEN User-Settings (~/.claude/settings.json).
# Global statt pro Projekt: funktioniert dann auch in Ordnern ohne Schreibrecht
# (z.B. fremdes Home) und muss nicht in jedem Projekt neu angelegt werden.
apply_tg_hooks() {
  _tg_ready || return 0
  local sf="${HOME}/.claude/settings.json"
  mkdir -p "${HOME}/.claude" 2>/dev/null || return 0
  [[ -f "$sf" ]] || echo '{}' > "$sf" 2>/dev/null || return 0
  [[ -w "$sf" ]] || return 0
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

# clau --tg-hooks-off : entfernt die globalen clau-Telegram-Hooks wieder
tg_hooks_off() {
  local sf="${HOME}/.claude/settings.json"
  [[ -f "$sf" ]] || { echo "Keine globalen Settings ($sf) — nichts zu tun."; return 0; }
  python3 - "$sf" <<'PY' || { echo "Konnte $sf nicht ändern." >&2; exit 1; }
import sys, json
f = sys.argv[1]
try: s = json.load(open(f))
except Exception: sys.exit(1)
hooks = s.get("hooks", {})
removed = 0
for evt in list(hooks):
    keep = []
    for grp in hooks[evt]:
        hs = [h for h in grp.get("hooks", [])
              if not str(h.get("command", "")).endswith("--tg-hook")]
        removed += len(grp.get("hooks", [])) - len(hs)
        if hs:
            grp["hooks"] = hs; keep.append(grp)
    if keep: hooks[evt] = keep
    else: del hooks[evt]
if not hooks: s.pop("hooks", None)
json.dump(s, open(f, "w"), indent=2)
print(f"{removed} clau-Hook(s) entfernt aus {f}")
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

# clau --tg-token : Bot-Token einfach reinpasten, wird geprüft & gespeichert
tg_token() {
  _tg_load
  printf "Bot-Token von @BotFather hier einfügen: "
  read -r tok
  tok="$(printf '%s' "$tok" | tr -d '[:space:]')"
  [[ -n "$tok" ]] || { echo "Kein Token — abgebrochen." >&2; exit 1; }
  local me
  me="$(curl -fsS --max-time 10 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null)"
  if ! printf '%s' "$me" | grep -q '"ok":true'; then
    echo "❌ Token ungültig oder kein Netz. Antwort: ${me:-<leer>}" >&2; exit 1
  fi
  _tg_conf_set CLAU_TG_BOT_TOKEN "$tok"
  _tg_conf_set CLAU_TG_ENABLED "1"
  local uname
  uname="$(printf '%s' "$me" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["username"])
except Exception: pass' 2>/dev/null)"
  echo "✅ Token gespeichert (Bot @${uname:-?}) in $CLAU_TG_CONF."
  echo "Weiter mit:  clau --tg-setup   (Gruppen-ID ermitteln)"
}

# clau --tg-whoami : eigene Telegram-User-ID ermitteln & optional als Allowlist speichern
tg_whoami() {
  _tg_load
  [[ -n "${CLAU_TG_BOT_TOKEN:-}" ]] || { echo "Erst 'clau --tg-token'." >&2; exit 1; }
  echo "Schreibe JETZT eine Nachricht in die Gruppe, dann [Enter] ..."
  read -r _
  local resp out
  resp="$(_tg_api getUpdates)"
  out="$(printf '%s' "$resp" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
seen = {}
for u in d.get("result", []):
    m = u.get("message") or {}
    fr = m.get("from") or {}
    if fr.get("id"):
        seen[fr["id"]] = fr.get("username") or fr.get("first_name","?")
for uid, name in seen.items():
    print(f"{uid}\t{name}")
' 2>/dev/null)"
  if [[ -z "$out" ]]; then
    echo "Keine Nachricht gefunden — nochmal in die Gruppe schreiben und erneut versuchen." >&2
    exit 1
  fi
  echo "Gefundene Absender:"
  printf '%s\n' "$out" | while IFS=$'\t' read -r uid name; do printf "  %s  (%s)\n" "$uid" "$name"; done
  echo
  printf "Welche ID als erlaubt speichern (CLAU_TG_ALLOWED_USER)? [ID, mehrere mit Komma, Enter=überspringen]: "
  read -r pick
  pick="$(printf '%s' "$pick" | tr -d '[:space:]')"
  if [[ -n "$pick" ]]; then
    _tg_conf_set CLAU_TG_ALLOWED_USER "$pick"
    echo "✅ Gespeichert: CLAU_TG_ALLOWED_USER=\"$pick\""
  else
    echo "Übersprungen. Später: CLAU_TG_ALLOWED_USER in $CLAU_TG_CONF eintragen."
  fi
}

# ── Telegram Phase 2: Bot-Poller (vom Handy entwickeln) ─────────────────────
# Läuft dauerhaft (tmux/systemd). Jede Nachricht in einem Topic wird zu einem
# Claude-Code-Headless-Turn im an das Topic gebundenen Verzeichnis; die Antwort
# geht zurück ins Topic. Session wird pro Topic fortgesetzt (Kontext bleibt).

_tg_bot_state() { echo "${CLAU_TG_STATE_DIR}/chat-${1:-0}"; }

# ── Concierge ("Bot-Hirn") ──────────────────────────────────────────────────
# Kleines Modell auf der vorhandenen QuiteQue-Infrastruktur (Default gemma-12b-chat).
# Es plaudert, navigiert und entscheidet, wann an den grossen Claude uebergeben wird.
# Kein Extra-Stack: gleiche Base-URL/Auth wie alle owl-Modelle.

# Listet Projektordner (mit .clau.conf oder .git) unter CLAU_TG_PROJECT_ROOT
_tg_projects() {
  local root="${CLAU_TG_PROJECT_ROOT:-$HOME}"
  find "$root" -maxdepth 2 \( -name .clau.conf -o -name .git \) -printf '%h\n' 2>/dev/null \
    | sort -u | head -25
}

# Fragt das Concierge-Modell; gibt JSON auf stdout aus (leer bei Fehler)
_tg_brain() {  # $1=userText $2=dir $3=sid
  local user="$1" dir="$2" sid="$3"
  local model="${CLAU_TG_BRAIN_MODEL:-gemma-12b-chat}"
  local projects; projects="$(_tg_projects | paste -sd'; ' -)"
  # QuiteQue verlangt X-Request-Context/X-Agent-Tool/X-Project inzwischen als
  # Pflicht-Header (GPU-Last-Zuordnung) -- ohne die schlägt jede Anfrage mit
  # 400 fehl. Dieser Call ging bisher direkt an QuiteQue, an
  # _owl_activity_env() vorbei.
  _owl_activity_env "tg-brain"
  python3 - "$OWL_BASE_URL" "$QQ_USER" "$model" "$user" "$dir" "$sid" "$projects" \
    "$OWL_HDR_AGENT_TOOL" "$OWL_HDR_REQUEST_CONTEXT" "$OWL_HDR_PROJECT" "$OWL_HDR_USER" <<'PY' 2>/dev/null
import json, sys, urllib.request
base, quser, model, user, cur_dir, sid, projects = sys.argv[1:8]
hdr_agent_tool, hdr_request_context, hdr_project, hdr_user = sys.argv[8:12]
system = (
    "Du bist der clau-Concierge auf einem Entwickler-Server. Du hilfst David per Telegram, "
    "in seine Coding-Sessions zu kommen. Antworte AUSSCHLIESSLICH mit einem JSON-Objekt, "
    "ohne Markdown, ohne Erklaerung drumherum.\n"
    "Felder:\n"
    '  action: "reply" (nur plaudern/erklaeren) | "cd" (Projektordner setzen) | '
    '"resume_pc" (zuletzt am PC gelaufene Session uebernehmen) | "new" (neue Session) | '
    '"opus" (Anweisung an den grossen Claude Code weiterreichen)\n'
    '  dir: absoluter Pfad (nur bei action "cd", sonst "")\n'
    '  text: kurze Antwort auf Deutsch, locker und knapp\n'
    "Regeln: Konkrete Programmier-/Datei-/Analyse-Auftraege -> action 'opus'. "
    "Small Talk, Fragen zu Projekten/Status/Bedienung -> 'reply'. "
    "Nur Ordner nennen ohne Auftrag -> 'cd'. Wenn er dort weitermachen will, wo er am PC "
    "aufgehoert hat -> 'resume_pc'. Frischer Start -> 'new'.\n"
    f"Verfuegbare Projekte: {projects or '(keine gefunden)'}\n"
    f"Aktueller Ordner: {cur_dir or '(keiner gesetzt)'}\n"
    f"Aktive Session: {'ja' if sid else 'nein'}"
)
body = json.dumps({
    "model": model,
    "messages": [{"role": "system", "content": system},
                 {"role": "user", "content": user}],
    "max_tokens": 400, "temperature": 0.3,
}).encode()
headers = {"Content-Type": "application/json", "X-OwlTrail-User": quser}
if hdr_agent_tool:
    headers["X-Agent-Tool"] = hdr_agent_tool
if hdr_request_context:
    headers["X-Request-Context"] = hdr_request_context
if hdr_project:
    headers["X-Project"] = hdr_project
if hdr_user:
    headers["X-User"] = hdr_user
req = urllib.request.Request(
    base.rstrip("/") + "/v1/chat/completions", data=body, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=120) as r:
        c = json.load(r)["choices"][0]["message"]["content"]
except Exception:
    sys.exit(0)
c = c.strip()
if c.startswith("```"):                      # Markdown-Fences abstreifen
    c = c.split("```")[1] if "```" in c[3:] else c.strip("`")
    c = c[4:] if c.lower().startswith("json") else c
i, j = c.find("{"), c.rfind("}")
if i < 0 or j < 0:
    print(json.dumps({"action": "reply", "dir": "", "text": c[:800]})); sys.exit(0)
try:
    d = json.loads(c[i:j+1])
except Exception:
    print(json.dumps({"action": "reply", "dir": "", "text": c[i:j+1][:800]})); sys.exit(0)
print(json.dumps({"action": str(d.get("action") or "reply"),
                  "dir": str(d.get("dir") or ""),
                  "text": str(d.get("text") or "")}))
PY
}

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
_tg_pcfile() { echo "${CLAU_TG_STATE_DIR}/lastpc-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

# Aktionen (von Slash-Befehlen UND vom Concierge genutzt)
_tg_do_cd() {  # $1=thread $2=pfad
  local th="$1" p="${2/#\~/$HOME}"
  [[ -d "$p" ]] || { _tg_send "$th" "❌ Ordner nicht gefunden: $p"; return 1; }
  p="$(cd "$p" 2>/dev/null && pwd)"   # kanonisch (matcht PC-Hook)
  _tg_bind_set "$th" DIR "$p"; _tg_bind_set "$th" SID ""
  local hint=""
  [[ -s "$(_tg_pcfile "$p")" ]] && hint=$'\n▶️ Es gibt eine PC-Session hier — /weiter zum Übernehmen.'
  _tg_send "$th" "📁 Ordner gesetzt: $p${hint}"
}

_tg_do_resume_pc() {  # $1=thread $2=dir → gibt uebernommene SID aus
  local th="$1" dir="$2"
  [[ -n "$dir" ]] || { _tg_send "$th" "❌ Erst Ordner setzen (/cd /pfad)."; return 1; }
  local pcf; pcf="$(_tg_pcfile "$dir")"
  if [[ -s "$pcf" ]]; then
    local pcsid; pcsid="$(cat "$pcf")"
    _tg_bind_set "$th" SID "$pcsid"
    _tg_send "$th" "▶️ PC-Session übernommen ($pcsid). Schreib einfach weiter. (PC-Session vorher beenden!)"
    printf '%s' "$pcsid"
  else
    _tg_send "$th" "Keine PC-Session für $dir gefunden. Arbeite erst am PC oder starte neu."
    return 1
  fi
}

_tg_do_opus() {  # $1=thread $2=dir $3=sid $4=prompt
  local th="$1" dir="$2" sid="$3" prompt="$4"
  [[ -n "$dir" ]] || { _tg_send "$th" "❌ Erst Ordner setzen:  /cd /pfad/zum/projekt"; return 1; }
  _tg_send "$th" "⏳ arbeite ..."
  local newsid; newsid="$(_tg_claude_turn "$th" "$dir" "$sid" "$prompt")"
  [[ -n "$newsid" ]] && _tg_bind_set "$th" SID "$newsid"
}

_tg_bot_handle() {
  local th="$1" txt="$2"
  local DIR="" SID="" TMUXS="" line
  while IFS= read -r line; do
    case "$line" in
      DIR=*)  DIR="${line#DIR=}" ;;
      SID=*)  SID="${line#SID=}" ;;
      TMUX=*) TMUXS="${line#TMUX=}" ;;
    esac
  done < <(cat "$(_tg_bot_state "$th")" 2>/dev/null)

  # Mirror-Topic: direkt in die laufende tmux-Session tippen
  if [[ -n "$TMUXS" ]] && command -v tmux >/dev/null 2>&1 \
     && tmux has-session -t "$TMUXS" 2>/dev/null; then
    case "$txt" in
      /stop*|/quit*)
        tmux kill-session -t "$TMUXS" 2>/dev/null || true
        _tg_bind_set "$th" TMUX ""
        _tg_send "$th" "⏹️ Live-Session beendet."; return ;;
      /esc*)      tmux send-keys -t "$TMUXS" Escape;   _tg_send "$th" "⎋ Escape"; return ;;
      /enter*)    tmux send-keys -t "$TMUXS" Enter;    _tg_send "$th" "⏎";        return ;;
      "/ctrl "*)  tmux send-keys -t "$TMUXS" "C-${txt#/ctrl }"; _tg_send "$th" "Strg-${txt#/ctrl }"; return ;;
      /screen*)   local snap
                  snap="$(tmux capture-pane -p -t "$TMUXS" 2>/dev/null | sed -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' | grep -v '^[[:space:]]*$' | tail -30)"
                  _tg_send_chunked "$th" "🖥️ Aktueller Bildschirm:"$'\n'"${snap:-<leer>}"; return ;;
      /help*)     _tg_send "$th" $'Live-Session (Mirror):\nText = wird direkt getippt + Enter\n/enter /esc /ctrl c – Tasten senden\n/screen – aktuellen Bildschirm zeigen\n/stop – Session beenden'; return ;;
    esac
    tmux send-keys -t "$TMUXS" -l -- "$txt" 2>/dev/null || true
    tmux send-keys -t "$TMUXS" Enter 2>/dev/null || true
    return
  fi
  # tmux-Session verschwunden → Bindung aufräumen, normal weiter
  [[ -n "$TMUXS" ]] && _tg_bind_set "$th" TMUX ""

  case "$txt" in
    /help*|/start*)
      _tg_send "$th" $'clau-Bot:\nEinfach normal schreiben — der Concierge hilft dir rein und reicht Coding-Aufträge an Claude weiter.\n\nShortcuts:\n/cd <pfad>  – Projektordner setzen\n/weiter     – PC-Session in diesem Ordner übernehmen\n/pwd        – aktueller Ordner\n/new        – neue Session\n/opus <txt> – direkt an Claude (Concierge überspringen)\n/projekte   – gefundene Projekte auflisten'
      return ;;
    "/cd "*|"/dir "*)
      _tg_do_cd "$th" "${txt#* }"; return ;;
    /weiter*|/pc*)
      _tg_do_resume_pc "$th" "$DIR" >/dev/null; return ;;
    /pwd*)
      _tg_send "$th" "📁 ${DIR:-<nicht gesetzt>}"; return ;;
    /new*)
      _tg_bind_set "$th" SID ""
      _tg_send "$th" "🔄 Neue Session im Ordner ${DIR:-<keiner>}"; return ;;
    /projekte*|/projects*|/ls*)
      local pl; pl="$(_tg_projects)"
      _tg_send "$th" "📚 Projekte:"$'\n'"${pl:-<keine gefunden>}"; return ;;
    "/opus "*)
      _tg_do_opus "$th" "$DIR" "$SID" "${txt#* }"; return ;;
    /*)
      _tg_send "$th" "❓ Unbekannter Befehl. /help"; return ;;
  esac

  # Kein Slash-Befehl → Concierge entscheidet (falls aktiviert)
  if [[ "${CLAU_TG_BRAIN:-1}" == "1" ]]; then
    local j; j="$(_tg_brain "$txt" "$DIR" "$SID")"
    if [[ -n "$j" ]]; then
      local act bdir btext
      act="$(printf '%s' "$j"  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("action",""))' 2>/dev/null)"
      bdir="$(printf '%s' "$j" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("dir",""))' 2>/dev/null)"
      btext="$(printf '%s' "$j"| python3 -c 'import sys,json;print(json.load(sys.stdin).get("text",""))' 2>/dev/null)"
      case "$act" in
        reply)     _tg_send "$th" "${btext:-…}"; return ;;
        cd)        [[ -n "$btext" ]] && _tg_send "$th" "$btext"
                   [[ -n "$bdir" ]] && _tg_do_cd "$th" "$bdir"; return ;;
        new)       _tg_bind_set "$th" SID ""
                   _tg_send "$th" "${btext:-🔄 Neue Session.}"; return ;;
        resume_pc) [[ -n "$btext" ]] && _tg_send "$th" "$btext"
                   # Ordner mitgeliefert → erst wechseln, dann PC-Session holen
                   if [[ -n "$bdir" && -d "${bdir/#\~/$HOME}" ]]; then
                     _tg_do_cd "$th" "$bdir" >/dev/null && DIR="$(cd "${bdir/#\~/$HOME}" && pwd)"
                   fi
                   local got; got="$(_tg_do_resume_pc "$th" "$DIR")" && SID="$got"; return ;;
        opus)      [[ -n "$btext" ]] && _tg_send "$th" "$btext" ;;   # kurze Ansage, dann durchreichen
        *)         : ;;
      esac
    fi
  fi

  _tg_do_opus "$th" "$DIR" "$SID" "$txt"
}

# ── Mirror-Modus: EINE Session gleichzeitig am Bildschirm und in Telegram ────
# tmux haelt die echte, interaktive Claude-Session. `pipe-pane` spiegelt die
# Ausgabe (ANSI-gefiltert) ins Topic, `send-keys` tippt Telegram-Nachrichten in
# die laufende Session. Beide Seiten sehen und steuern dasselbe.

_tg_mirror_session() { echo "clau-$(pwd | md5sum | cut -c1-10)"; }
_tg_mirror_log()     { echo "${CLAU_TG_STATE_DIR}/mirror-${1}.log"; }

# clau --tg-pump <thread> <logfile> <tmux-session> : intern, spiegelt Log → Topic
tg_pump() {
  _tg_ready || exit 0
  local thread="$1" log="$2" sess="$3"
  mkdir -p "$CLAU_TG_STATE_DIR"
  python3 - "$log" "$thread" "$sess" "$CLAU_TG_BOT_TOKEN" "$CLAU_TG_GROUP_ID" <<'PY'
import os, re, subprocess, sys, time, urllib.parse, urllib.request

log, thread, sess, token, chat = sys.argv[1:6]
API = f"https://api.telegram.org/bot{token}/sendMessage"

ANSI  = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-Z\\-_]")
CTRL  = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
# Zeilen, die nur aus Rahmen/Spinner/Leerzeichen bestehen -> raus
NOISE = re.compile(r"^[\s─-╿⠀-⣿■-◿·▪▫●○◐◓◑◒⠁-⠿|/\\_\-=+*.]*$")
SPIN  = re.compile(r"[⠀-⣿■-◿◐◓◑◒]+")   # Braille-Spinner & Bullets

def send(text):
    if not text.strip():
        return
    data = urllib.parse.urlencode({
        "chat_id": chat, "message_thread_id": thread, "text": text[:3900],
        "disable_notification": "true",
    }).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(API, data=data), timeout=15).read()
    except Exception:
        pass

def alive():
    return subprocess.run(["tmux", "has-session", "-t", sess],
                          capture_output=True).returncode == 0

recent, buf, last_flush = [], [], time.time()
FLUSH_SECS, MAX_CHARS = 4.0, 3000

def flush():
    global buf, last_flush
    if buf:
        send("\n".join(buf))
        buf = []
    last_flush = time.time()

# auf Logdatei warten, dann wie `tail -f` lesen
for _ in range(100):
    if os.path.exists(log):
        break
    time.sleep(0.3)
f = open(log, "r", errors="replace") if os.path.exists(log) else None
if f is None:
    sys.exit(0)

gone_since = None
while True:
    chunk = f.readline()
    if not chunk:
        if buf and time.time() - last_flush > FLUSH_SECS:
            flush()
        if not alive():
            gone_since = gone_since or time.time()
            if time.time() - gone_since > 3:
                flush()
                send("⏹️ Session beendet (tmux weg).")
                break
        else:
            gone_since = None
        time.sleep(0.4)
        continue

    line = CTRL.sub("", ANSI.sub("", chunk)).replace("\r", "").rstrip()
    if not line or NOISE.match(line):
        continue
    line = SPIN.sub("", line)                    # Spinner-Glyphen entfernen
    line = line.strip(" \t│|┃┆┇┊┋╎╏─━═╭╮╯╰┌┐└┘")  # Rahmen an den Raendern weg
    line = re.sub(r"[ \t]{3,}", "  ", line).strip()
    if len(line) < 2:
        continue
    if line in recent:          # TUI-Redraws / Spinner-Wiederholungen unterdruecken
        continue
    recent.append(line)
    del recent[:-80]
    buf.append(line)
    if sum(len(x) + 1 for x in buf) >= MAX_CHARS:
        flush()
    elif time.time() - last_flush > FLUSH_SECS:
        flush()
PY
}

# clau --mirror : Session in tmux starten, parallel am Bildschirm und in Telegram
tg_mirror() {
  _tg_ready || { echo "Telegram nicht konfiguriert — erst 'clau --tg-setup'." >&2; exit 1; }
  command -v tmux >/dev/null 2>&1 || { echo "tmux fehlt. Installieren:  sudo apt install tmux" >&2; exit 1; }
  local sess; sess="$(_tg_mirror_session)"
  local log;  log="$(_tg_mirror_log "$sess")"
  local proj; proj="$(basename "$(pwd)")"
  mkdir -p "$CLAU_TG_STATE_DIR"

  if tmux has-session -t "$sess" 2>/dev/null; then
    echo "Mirror-Session läuft schon — hänge mich dran (Strg-b d zum Loslösen)."
    exec tmux attach -t "$sess"
  fi

  local mdl; mdl="$(effective_model)"
  [[ -n "$mdl" ]] || { ensure_model; mdl="$(effective_model)"; }
  if is_owl_model "$mdl"; then
    echo "Mirror-Modus unterstützt derzeit nur Claude-Modelle (nicht owl:*)." >&2; exit 1
  fi

  # Topic anlegen und an die tmux-Session binden (damit der Bot dorthin tippt)
  local thread; thread="$(_tg_topic_for "mirror-${sess}" "🖥️ ${proj} · live")"
  _tg_bind_set "${thread:-0}" DIR "$(pwd)"
  _tg_bind_set "${thread:-0}" TMUX "$sess"

  : > "$log"
  cleanup_tool_blocking; unset_token_saver_env; apply_tg_hooks
  local extra; extra="$(_interaction_args)"
  # shellcheck disable=SC2086
  tmux new-session -d -s "$sess" -c "$(pwd)" \
    "claude --model '$(claude_cli_model "$mdl")' $extra"
  tmux pipe-pane -t "$sess" -o "cat >> '$log'"

  # Pump losschicken (ueberlebt das Ablegen des Terminals)
  setsid nohup "$0" --tg-pump "${thread:-0}" "$log" "$sess" >/dev/null 2>&1 &
  _tg_send "${thread:-}" "🖥️ Live-Session gestartet in ${proj} (Modell ${mdl}). Schreib hier rein — es wird direkt getippt. /stop beendet."

  echo "Mirror läuft: tmux-Session '$sess', Topic '🖥️ ${proj} · live'."
  echo "Bildschirm + Telegram parallel. Loslösen: Strg-b d   Wieder ran: clau --mirror"
  sleep 1
  exec tmux attach -t "$sess"
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
      # Allowlist: eine oder mehrere IDs (kommagetrennt)
      if [[ -n "$allowed" && ",${allowed//[[:space:]]/}," != *",${fr},"* ]]; then
        _tg_send "$th" "⛔ Nicht autorisiert (User $fr)."; continue
      fi
      [[ -n "$txt" ]] || continue
      _tg_bot_handle "$th" "$txt"
    done <<< "$lines"
  done
}

# ── Schlankes Tool-Set für owlAPI-Sessions ───────────────────────────────────
# CLAU_DISABLE_TOOLS (apply_tool_blocking) setzt nur permissions.deny in
# .claude/settings.json -- das blockiert die AUSFÜHRUNG, aber claude-CLI
# schickt das volle Tool-Schema (inkl. aller MCP-Tools wie Gmail/Calendar/
# Drive) trotzdem in jedem einzelnen Request mit. Bei einem echten 400 vom
# Backend (Request-Payload-Dump zeigte ein riesiges tools-Array mit vollem
# JSON-Schema für praktisch jedes eingebaute Tool + alle MCP-Server) ist das
# ein Verdächtiger: lokale Tool-Calling-Backends (vLLM u.ä.) sind bei so viel
# Schema-Komplexität empfindlich. --tools/--strict-mcp-config wirken dagegen
# auf das tatsächlich gesendete Schema, nicht nur auf Ausführungsrechte.
CLAU_OWL_TOOLS_DEFAULT="Bash,Edit,Write,Read,AskUserQuestion,TaskCreate,TaskGet,TaskList,TaskUpdate,EnterPlanMode,ExitPlanMode"

# MCP-Config für den owlAPI-Pfad. Normalerweise leer (--strict-mcp-config
# blendet damit alle sonstigen MCP-Server aus, spart Tokens). Mit
# CLAU_WEBSEARCH=1 kommt die lokale QuiteQue-Websuche als einziges MCP-Tool
# dazu — das serverseitige WebSearch der Anthropic-API gibt es über owlAPI
# nicht, ein lokales Modell hätte sonst gar keinen Weg ins Netz.
_owl_mcp_config() {
  if team_active && [[ -f "$LLM_STATUS_MCP_SCRIPT" ]]; then
    # Team-Modus: llm_status (Slot-Auslastung des Ausführer-Modells) immer,
    # Websuche wie gehabt nur mit CLAU_WEBSEARCH=1.
    local ws=0
    if [[ "${CLAU_WEBSEARCH:-1}" == "1" && -f "$WEBSEARCH_MCP_SCRIPT" ]]; then
      ws=1; _owl_activity_env "websearch"
    fi
    local pi_bin=""
    if team_pi_active && _team_pi_setup; then pi_bin="$(_team_pi_bin)"; fi
    python3 - "$ws" "$LLM_STATUS_MCP_SCRIPT" "$WEBSEARCH_MCP_SCRIPT" "$pi_bin" "$PI_TEAM_MCP_SCRIPT" <<PY_MCP
import json, sys
ws, llm, web, pi_bin, pi_mcp = sys.argv[1] == "1", sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
servers = {"llm_status": {"type": "stdio", "command": "python3", "args": [llm], "env": {
    "CLAU_TEAM_STATUS_URL": "${CLAU_TEAM_STATUS_URL:-http://127.0.0.1:8293/slots}",
    "CLAU_TEAM_EXEC_MODEL": "$(team_exec_model)",
    "CLAU_TEAM_MAX_AGENTS": "${CLAU_TEAM_MAX_AGENTS:-5}"}}}
if pi_bin:
    servers["pi_team"] = {"type": "stdio", "command": "python3", "args": [pi_mcp], "env": {
        "CLAU_PI_BIN": pi_bin, "PI_CODING_AGENT_DIR": "$TEAM_PI_AGENT_DIR",
        "CLAU_TEAM_DIR": "$CLAU_TEAM_DIR",
        "CLAU_TEAM_EXEC_MODEL": "$(team_exec_model)", "CLAU_TEAM_LEAD_MODEL": "$(team_lead_model)",
        "CLAU_TEAM_PI_SLOTS": "$(team_exec_model)=$(_team_exec_slots)$([[ "$(team_lead_model)" != "$(team_exec_model)" ]] && echo ",$(team_lead_model)=1")",
        "CLAU_TEAM_PI_TIMEOUT": "${CLAU_TEAM_PI_TIMEOUT:-1800}",
        "PATH": "$PATH", "HOME": "$HOME"}}
if ws:
    servers["websearch"] = {"type": "stdio", "command": "python3", "args": [web], "env": {
        "QUITEQUE_URL": "$OWL_BASE_URL", "OWL_PROXY_USER": "$QQ_USER",
        "OWL_HDR_AGENT_TOOL": "${OWL_HDR_AGENT_TOOL:-}", "OWL_HDR_REQUEST_CONTEXT": "${OWL_HDR_REQUEST_CONTEXT:-}",
        "OWL_HDR_PROJECT": "${OWL_HDR_PROJECT:-}", "OWL_HDR_USER": "${OWL_HDR_USER:-}"}}
print(json.dumps({"mcpServers": servers}))
PY_MCP
    return
  fi
  if [[ "${CLAU_WEBSEARCH:-1}" == "1" && -f "$WEBSEARCH_MCP_SCRIPT" ]]; then
    _owl_activity_env "websearch"
    # Zeilenumbruch ist Pflicht: der Aufrufer liest die Argumente mit
    # "while read", und read verwirft die letzte Zeile ohne \n — dann stünde
    # --mcp-config ohne Wert da und würde die folgenden Argumente
    # (--resume <id>) als Config-Dateien schlucken.
    printf '{"mcpServers":{"websearch":{"type":"stdio","command":"python3","args":["%s"],"env":{"QUITEQUE_URL":"%s","OWL_PROXY_USER":"%s","OWL_HDR_AGENT_TOOL":"%s","OWL_HDR_REQUEST_CONTEXT":"%s","OWL_HDR_PROJECT":"%s","OWL_HDR_USER":"%s"}}}}\n' \
      "$WEBSEARCH_MCP_SCRIPT" "$OWL_BASE_URL" "$QQ_USER" \
      "$OWL_HDR_AGENT_TOOL" "$OWL_HDR_REQUEST_CONTEXT" "$OWL_HDR_PROJECT" "$OWL_HDR_USER"
  else
    printf '{"mcpServers":{}}\n'
  fi
}

_owl_minimal_tool_args() {
  [[ "${CLAU_OWL_MINIMAL_TOOLS:-1}" == "1" ]] || return 0
  echo "--tools"
  if team_active && ! team_pi_active; then
    # Ohne Agent-Tool kann der Teamleiter nichts verteilen (pi-Modus: verteilt
    # über das MCP-Tool pi_team, das Agent-Schema spart man sich)
    echo "${CLAU_OWL_TOOLS:-$CLAU_OWL_TOOLS_DEFAULT},Agent"
  else
    echo "${CLAU_OWL_TOOLS:-$CLAU_OWL_TOOLS_DEFAULT}"
  fi
  echo "--strict-mcp-config"
  echo "--mcp-config"
  _owl_mcp_config
}

# ── Team-Modus ───────────────────────────────────────────────────────────────
# Teamleiter (CLAU_TEAM_LEAD_MODEL, 27B) im Frontend, Ausführer-Subagenten
# (model: sonnet → CLAU_TEAM_EXEC_MODEL, 176B) über dasselbe owl_proxy. Der
# Proxy routet nach dem angefragten Modellnamen "owl-<ID>".
team_active() { [[ "${CLAU_TEAM:-0}" == "1" ]]; }
team_lead_model() { echo "${CLAU_TEAM_LEAD_MODEL:-120}"; }
team_exec_model() { echo "${CLAU_TEAM_EXEC_MODEL:-121}"; }

# ── Team-Subagenten als pi-Prozesse ──────────────────────────────────────────
# Statt Claude-Code-Subagenten (~36k Tokens System-Prompt + Tool-Schema pro
# Anfrage) startet der Teamleiter über das MCP-Tool pi_team (pi_team_mcp.py)
# schlanke `pi -p`-Prozesse (~1,7k Tokens). pi spricht OpenAI-kompatibel direkt
# mit QuiteQue; Konfiguration in einem eigenen PI_CODING_AGENT_DIR, die
# persönliche ~/.pi bleibt unberührt.
_team_pi_bin() {
  local b
  for b in "${CLAU_PI_BIN:-}" "$(command -v pi 2>/dev/null)" "$HOME/.npm-global/bin/pi" "$HOME/.local/bin/pi"; do
    [[ -n "$b" && -x "$b" ]] && { echo "$b"; return 0; }
  done
  return 1
}

team_pi_active() {
  team_active && [[ "${CLAU_TEAM_SUBAGENTS:-pi}" == "pi" ]] && [[ -f "$PI_TEAM_MCP_SCRIPT" ]] && _team_pi_bin >/dev/null
}

TEAM_PI_AGENT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/clau/pi-agent"

# Schreibt models.json/settings.json für pi: Provider "owl" = QuiteQue mit den
# Pflicht-Headern, Modelle Teamleiter + Ausführer mit echtem Kontextfenster.
_team_pi_setup() {
  mkdir -p "$TEAM_PI_AGENT_DIR" 2>/dev/null || return 1
  python3 - "$TEAM_PI_AGENT_DIR" "${OWL_BASE_URL}/v1" "$QQ_USER" \
    "${CLAU_AGENT_TOOL:-ccclau-$(whoami)}" "${CLAU_SESSION_NAME:-$(basename "$PWD")}" "${CLAU_USER_TAG:-$(whoami)}" \
    "$(team_lead_model)" "$(owl_context_window "$(team_lead_model)")" \
    "$(team_exec_model)" "$(owl_context_window "$(team_exec_model)")" <<'PY_PI'
import json, os, sys
d, base, user, tool, proj, xuser, lead, lead_cw, exe, exe_cw = sys.argv[1:11]
def model(mid, cw):
    return {"id": mid, "contextWindow": int(cw or 0) or 94000, "maxTokens": 16384, "reasoning": True}
models = [model(lead, lead_cw)] + ([model(exe, exe_cw)] if exe != lead else [])
cfg = {"providers": {"owl": {
    "baseUrl": base, "api": "openai-completions", "apiKey": "owl",
    "headers": {"X-OwlTrail-User": user, "X-Agent-Tool": tool + "-pi",
                "X-Request-Context": "team", "X-Project": proj, "X-User": xuser},
    "models": models}}}
json.dump(cfg, open(os.path.join(d, "models.json"), "w"), indent=1)
json.dump({"defaultProvider": "owl", "defaultModel": exe, "quietStartup": True},
          open(os.path.join(d, "settings.json"), "w"), indent=1)
PY_PI
}

# Slot-Grenze fürs Ausführer-Modell: CLAU_TEAM_SLOTS_<ID>, Default 3 (121 im
# Zielbetrieb: 3 Slots à ~99k) bzw. 1 für das 262k-Einzelslot-Modell 126.
_team_exec_slots() {
  local id; id="$(team_exec_model)"
  local var="CLAU_TEAM_SLOTS_${id//[^A-Za-z0-9_]/_}"
  local def=3
  [[ "$id" == "126" ]] && def=1
  echo "${!var:-$def}"
}

# Kontextfenster für Auto-Compact: im Team-Modus laufen Teamleiter und
# Ausführer im selben claude-Prozess mit EINEM Compact-Schwellwert -- der
# muss zum kleineren Fenster passen.
session_context_window() {
  local owl_id="$1" cw ecw
  cw="$(owl_context_window "$owl_id")"
  if team_active; then
    ecw="$(owl_context_window "$(team_exec_model)")"
    if [[ -n "$ecw" && ( -z "$cw" || "$ecw" -lt "$cw" ) ]]; then cw="$ecw"; fi
  fi
  echo "$cw"
}

# Modellname, den claude CLI anfragt. Normalbetrieb: fester Dummy-Name, der
# Proxy nimmt OWL_MODEL. Team-Modus: owl-<ID>, plus Alias-Zuordnung, damit
# Agenten mit model: sonnet auf dem Ausführer-Modell landen.
owl_cli_model() {
  if team_active; then
    echo "owl-$(team_lead_model)"
  else
    echo "claude-sonnet-4-6"
  fi
}

team_export_env() {
  local lead exe; lead="$(team_lead_model)"; exe="$(team_exec_model)"
  export ANTHROPIC_MODEL="owl-${lead}"
  export ANTHROPIC_DEFAULT_OPUS_MODEL="owl-${lead}"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="owl-${lead}"
  export ANTHROPIC_SMALL_FAST_MODEL="owl-${lead}"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="owl-${exe}"
  # Würde sonst JEDEN Subagenten auf ein Modell zwingen
  unset CLAUDE_CODE_SUBAGENT_MODEL
}

# Agent-Definitionen (team/agents/*.md, Frontmatter wie .claude/agents/) als
# --agents-JSON: so landen sie in der Session, ohne dass clau etwas in den
# Projektordner schreibt. Ein gleichnamiger Agent in .claude/agents/ des
# Projekts wird dabei von der CLI-Definition überdeckt.
_team_agents_json() {
  python3 - "$CLAU_TEAM_DIR/agents" <<'PY_AGENTS'
import json, os, sys
d = sys.argv[1]
agents = {}
for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
    if not fn.endswith(".md"):
        continue
    text = open(os.path.join(d, fn), encoding="utf-8").read()
    meta, body = {}, text
    if text.startswith("---"):
        _, fm, body = text.split("---", 2)
        for line in fm.strip().splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip()
    name = meta.get("name") or fn[:-3]
    a = {"description": meta.get("description", ""), "prompt": body.strip()}
    if meta.get("model"):
        a["model"] = meta["model"]
    if meta.get("tools"):
        a["tools"] = [t.strip() for t in meta["tools"].split(",") if t.strip()]
    agents[name] = a
print(json.dumps(agents, ensure_ascii=False))
PY_AGENTS
}

# Zusätzliche claude-Argumente im Team-Modus, eine pro Zeile (Aufrufer liest
# mit "while read", deshalb einzeiliges JSON und Dateipfad statt Prompt-Text).
_team_claude_args() {
  team_active || return 0
  local tpl="$CLAU_TEAM_DIR/TEAM_ANWEISUNG.md"
  if team_pi_active; then
    tpl="$CLAU_TEAM_DIR/TEAM_ANWEISUNG_PI.md"
  else
    local agents; agents="$(_team_agents_json 2>/dev/null)"
    if [[ -n "$agents" && "$agents" != "{}" ]]; then
      echo "--agents"
      echo "$agents"
    fi
  fi
  # Team-Anweisung mit eingesetztem Agenten-Limit als System-Prompt-Zusatz.
  # Datei pro Prozess, weil der Text Zeilenumbrüche hat.
  if [[ -f "$tpl" ]]; then
    local out="${OWL_PROXY_LOG_DIR}/team_anweisung_$$.md"
    mkdir -p "$OWL_PROXY_LOG_DIR" 2>/dev/null || true
    if sed "s/{{MAX_AGENTS}}/${CLAU_TEAM_MAX_AGENTS:-5}/g" "$tpl" > "$out" 2>/dev/null; then
      echo "--append-system-prompt-file"
      echo "$out"
    fi
  fi
}

# Von der Fernsteuerung (clau_api.py) gestartete Rollen-Sessions: Status-Hooks
# nur für diese Session (--settings) und feste Session-ID, damit die API die
# Session wiederfindet. $1 = interactive|headless. Ohne CLAU_API_SESSION_ID leer.
_api_claude_args() {
  [[ -n "${CLAU_API_SESSION_ID:-}" ]] || return 0
  if [[ -n "${CLAU_API_HOOK_SETTINGS:-}" ]]; then
    echo "--settings"
    echo "$CLAU_API_HOOK_SETTINGS"
  fi
  if [[ "${CLAU_API_RESUME:-0}" == "1" ]]; then
    # interaktiv kommt --resume schon über clau --resume <id>
    if [[ "${1:-}" == "headless" ]]; then echo "--resume"; echo "$CLAU_API_SESSION_ID"; fi
  else
    echo "--session-id"
    echo "$CLAU_API_SESSION_ID"
  fi
}

# Erster Auftrag einer per API gestarteten Session (als Prompt-Argument,
# kann Zeilenumbrüche enthalten, deshalb nicht über _api_claude_args).
_api_prompt_args() {
  API_PROMPT_ARGS=()
  if [[ -n "${CLAU_API_PROMPT_FILE:-}" && -f "${CLAU_API_PROMPT_FILE}" ]]; then
    API_PROMPT_ARGS=("$(cat "$CLAU_API_PROMPT_FILE")")
  fi
}

# ── Fernsteuerung (clau --api, Default aus) ─────────────────────────────────
CLAU_API_STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/clau/api"

_api_env_export() {
  export CLAU_API_BIND="${CLAU_API_BIND:-127.0.0.1:7010}" CLAU_API_TOKEN="${CLAU_API_TOKEN:-}"
  export CLAU_TEAM_STATUS_URL CLAU_TEAM_MAX_AGENTS
  export CLAU_TEAM_EXEC_MODEL="$(team_exec_model)"
  export CLAU_BIN; CLAU_BIN="$(readlink -f "$0")"
  export CLAU_API_ORDNER="${CLAU_API_ORDNER:-$PWD}"
}

# clau --api : HTTP-Dienst im Vordergrund (für systemd/devport)
run_api_server() {
  command -v tmux >/dev/null 2>&1 || { echo "tmux fehlt. Installieren:  sudo apt install tmux" >&2; exit 1; }
  [[ -f "$CLAU_API_SCRIPT" ]] || { echo "clau_api.py nicht gefunden: $CLAU_API_SCRIPT" >&2; exit 1; }
  _api_env_export
  exec python3 "$CLAU_API_SCRIPT" serve
}

# CLAU_API=1: Dienst beim clau-Start im Hintergrund hochziehen, falls er
# nicht schon läuft. Nicht aus einer API-Rollen-Session heraus.
api_daemon_ensure() {
  [[ "${CLAU_API:-0}" == "1" ]] || return 0
  [[ -z "${CLAU_API_SESSION_ID:-}" ]] || return 0
  [[ -f "$CLAU_API_SCRIPT" ]] && command -v tmux >/dev/null 2>&1 || return 0
  local pidf="$CLAU_API_STATE_DIR/server.pid" pid
  pid="$(cat "$pidf" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  mkdir -p "$CLAU_API_STATE_DIR" 2>/dev/null || return 0
  ( _api_env_export
    setsid nohup python3 "$CLAU_API_SCRIPT" serve >>"$CLAU_API_STATE_DIR/server.log" 2>&1 &
    echo "$!" > "$pidf" )
  echo "Fernsteuerung gestartet: http://${CLAU_API_BIND:-127.0.0.1:7010} (Log: $CLAU_API_STATE_DIR/server.log)"
}

api_daemon_stop() {
  local pidf="$CLAU_API_STATE_DIR/server.pid" pid
  pid="$(cat "$pidf" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; then
    rm -f "$pidf"; echo "Fernsteuerung (PID $pid) beendet."
  else
    echo "Keine laufende Fernsteuerung (Hintergrund) gefunden."
  fi
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
    PRE_FLIGHT_RESUME_ID=""
    local resume_id="" prev=""
    for arg in "$@"; do
      if [[ "$prev" == "--resume" ]]; then resume_id="$arg"; break; fi
      prev="$arg"
    done
    _pre_flight_check "$owl_id" "$resume_id" || exit 1
    if [[ -n "$PRE_FLIGHT_RESUME_ID" ]]; then
      # Pre-Flight hat die zu große Session automatisch komprimiert —
      # auf die neue Session umlenken statt auf der alten weiterzumachen.
      # Ein evtl. vorhandenes --resume [id] aus den Original-Args entfernen,
      # damit es nicht mit dem neuen --resume kollidiert.
      local filtered=() skip_next=0 a
      for a in "$@"; do
        if [[ "$skip_next" -eq 1 ]]; then skip_next=0; continue; fi
        if [[ "$a" == "--resume" ]]; then skip_next=1; continue; fi
        filtered+=("$a")
      done
      set -- "${filtered[@]}" --resume "$PRE_FLIGHT_RESUME_ID"
    fi
  fi

  # Auto-Compact-Threshold: konfigurierbar via CLAU_AUTO_COMPACT_WINDOW (fester Wert)
  # oder CLAU_AUTO_COMPACT_PCT (Prozent von Context-Window, Default 80).
  # claude-CLI respektiert CLAUDE_CODE_AUTO_COMPACT_WINDOW ohne DISABLE_COMPACT zu setzen!
  local cw; cw="$(session_context_window "$owl_id")"
  _apply_compact_window "$cw" "owl:$owl_id"
  _owl_cc_context_env "$cw"

  # Token-Fresser deaktivieren
  token_saver_env >/dev/null

  # Tool-Blocking: generiert/aktualisiert .claude/settings.json
  apply_tool_blocking

  echo "Starte owlAPI-Proxy für Modell $owl_id ..."
  if team_active; then
    echo "Team-Modus: Teamleiter owl-$(team_lead_model), Ausführer owl-$(team_exec_model) (max. $(_team_exec_slots) parallel, bis ${CLAU_TEAM_MAX_AGENTS:-5} Agenten, Subagenten: $(team_pi_active && echo "pi ($(_team_pi_bin))" || echo "Claude Code"))"
  fi
  local port
  port="$(_start_owl_proxy "$owl_id")"
  trap '_kill_owl_proxy' EXIT INT TERM
  sleep 0.6

  # Fenster: Claude Code traut "claude-sonnet-4-6" 200k zu, mit "[1m]" 1M
  # (_owl_cc_model); die eigentliche Compact-Grenze kommt aus
  # _apply_compact_window. CLAUDE_CODE_MAX_CONTEXT_TOKENS wirkt bei bekannten
  # Modellnamen nur zusammen mit DISABLE_COMPACT -- hier also nicht nutzbar.
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
  local tool_args=()
  while IFS= read -r line; do tool_args+=("$line"); done < <(_owl_minimal_tool_args; _team_claude_args)
  while IFS= read -r line; do tool_args+=("$line"); done < <(_api_claude_args interactive)
  _api_prompt_args
  team_active && team_export_env
  # shellcheck disable=SC2086
  ANTHROPIC_BASE_URL="http://127.0.0.1:${port}" \
  ANTHROPIC_API_KEY="sk-ant-api03-owl-dummy-key-not-real" \
  claude --model "$(_owl_cc_model "$cw")" $extra "${tool_args[@]}" "${real_args[@]}" "${API_PROMPT_ARGS[@]}" || true

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
  local cw; cw="$(session_context_window "$owl_id")"
  _apply_compact_window "$cw" "owl:$owl_id" >/dev/null
  _owl_cc_context_env "$cw"

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

  local tool_args=()
  while IFS= read -r line; do tool_args+=("$line"); done < <(_owl_minimal_tool_args; _team_claude_args)
  while IFS= read -r line; do tool_args+=("$line"); done < <(_api_claude_args headless)
  local perm_args=()
  [[ -n "${CLAU_API_SESSION_ID:-}" && "${DANGEROUS_SKIP:-0}" -eq 1 ]] && perm_args=(--dangerously-skip-permissions)
  if team_active; then
    team_export_env
    # Ohne Permission-Flag schickt claude für jeden Tool-Schritt eine
    # Klassifikator-Anfrage (~40k Tokens) ans sonnet-Alias = Ausführer-Modell
    # und belegt damit dessen Slots.
    [[ "${DANGEROUS_SKIP:-0}" -eq 1 ]] && perm_args=(--dangerously-skip-permissions)
  fi
  ANTHROPIC_BASE_URL="http://127.0.0.1:${port}" \
  ANTHROPIC_API_KEY="sk-owl" \
  claude -p "$prompt" --model "$(_owl_cc_model "$cw")" "${perm_args[@]}" "${tool_args[@]}" || true

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
CLI_BACKEND_OVERRIDE=""
IMPORT_MD_FILE=""
INTERACTION_LEVEL=""  # wird aus Config geladen; CLI --interaction überschreibt

# Git-Aktionstypen
GIT_ACTION=""
GIT_REPO_NAME=""

# Ausweich-Ablage für Ordner ohne Schreibrecht: pro Verzeichnis eine Datei im Home.
_conf_fallback_file() {
  local d="${XDG_CONFIG_HOME:-$HOME/.config}/clau/dirs"
  echo "${d}/$(pwd | tr -c 'A-Za-z0-9' '_').conf"
}

# Diese Einstellungen dürfen aus der Umgebung kommen und schlagen dann die
# .clau.conf (devport/VM, Fernsteuerung: CLAU_TEAM=1 clau ..., offline ohne
# Update-Check/Websuche).
CLAU_ENV_OVERRIDES=(CLAU_TEAM CLAU_TEAM_LEAD_MODEL CLAU_TEAM_EXEC_MODEL CLAU_TEAM_MAX_AGENTS
  CLAU_TEAM_SLOTS_121 CLAU_TEAM_STATUS_URL CLAU_TEAM_SUBAGENTS CLAU_API CLAU_API_BIND CLAU_API_TOKEN
  CLAU_UPDATE_CHECK CLAU_WEBSEARCH CLAU_OFFLINE CLAU_OWL_ROUTES)

load_config() {
  local _ov _envsave=()
  for _ov in "${CLAU_ENV_OVERRIDES[@]}"; do
    [[ -n "${!_ov+x}" ]] && _envsave+=("$_ov=${!_ov}")
  done
  if [[ -f "$CONFIG_FILE" ]]; then
    # ./-Präfix: sonst durchsucht `source` erst $PATH (sourcepath) und lädt evtl.
    # eine fremde .clau.conf aus einem PATH-Verzeichnis statt der im aktuellen Ordner.
    # shellcheck disable=SC1090
    source "./$CONFIG_FILE"
  else
    # Keine lokale Config → ggf. Ausweich-Config aus dem Home laden
    local fb; fb="$(_conf_fallback_file)"
    # shellcheck disable=SC1090
    [[ -f "$fb" ]] && source "$fb"
  fi
  for _ov in "${_envsave[@]}"; do
    printf -v "${_ov%%=*}" '%s' "${_ov#*=}"
  done
  # Offline (devport-VM ohne Internet): nichts darf ins Netz wollen oder hängen
  : "${CLAU_OFFLINE:=0}"
  if [[ "$CLAU_OFFLINE" == "1" ]]; then
    CLAU_UPDATE_CHECK=0
    CLAU_WEBSEARCH=0
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1
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
  : "${CLAU_WEBSEARCH:=1}"
  # Team-Modus (Teamleiter + Ausführer-Subagenten) und Fernsteuerung, Default aus
  : "${CLAU_TEAM:=0}"
  : "${CLAU_TEAM_LEAD_MODEL:=120}"
  : "${CLAU_TEAM_EXEC_MODEL:=121}"
  : "${CLAU_TEAM_MAX_AGENTS:=5}"
  : "${CLAU_TEAM_SLOTS_121:=3}"
  : "${CLAU_TEAM_STATUS_URL:=http://127.0.0.1:8293/slots}"
  # Subagenten: "pi" (schlanke pi-Prozesse, Default wenn pi installiert) oder "claude"
  : "${CLAU_TEAM_SUBAGENTS:=pi}"
  : "${CLAU_API:=0}"
  : "${CLAU_API_BIND:=127.0.0.1:7010}"
  : "${CLAU_API_TOKEN:=}"
  # CLI-Engine: "claude" (Claude Code, Standard) oder "opencode".
  : "${CLAU_BACKEND:=claude}"
  # Modelle fürs Backend "qwenplan" (Alibaba Token Plan)
  : "${CLAU_QWEN_MODEL:=qwen3.8-max}"
  : "${CLAU_QWEN_FAST_MODEL:=qwen3.8-flash}"
  # Timeout: in ms, für Claude Code Bash-Tool + Modell-Inferenz
  : "${CLAU_TIMEOUT_DEFAULT:=1800000}"
  : "${CLAU_TIMEOUT_MAX:=7200000}"
  # Aktivitäts-Tags fürs PropellerA-Panel (power-activity.jsonl) -- freiwillig,
  # siehe _owl_activity_env().
  : "${CLAU_AGENT_TOOL:=ccclau-$(whoami)}"
  : "${CLAU_USER_TAG:=$(whoami)}"
  INTERACTION_LEVEL="$CLAU_INTERACTION_LEVEL"
}

# Setzt die 4 freiwilligen Aktivitäts-Header (X-Agent-Tool, X-Request-Context,
# X-Project, X-User) als OWL_HDR_*-Env-Vars für den aufrufenden Scope. Werden
# von owl_proxy.py, cc_compact.py und websearch_mcp.py bei jeder Inferenz-
# Anfrage mitgeschickt, damit PropellerAs Panel sieht wer/was/wofür anfragt.
# $1 = Request-Context (chat|compact|websearch)
_owl_activity_env() {
  # Inline-Fallbacks statt reiner Abhängigkeit von load_config(): QuiteQue
  # verlangt diese Header inzwischen als PFLICHT (GPU-Last-Zuordnung) --
  # ein leerer Wert (z.B. weil load_config() für dieses Verzeichnis nie lief,
  # wie im Telegram-Bot-Poller der über viele Projektordner zyklisch läuft)
  # würde denselben 400-Fehler reproduzieren, den wir gerade beheben.
  OWL_HDR_AGENT_TOOL="${CLAU_AGENT_TOOL:-ccclau-$(whoami)}"
  OWL_HDR_REQUEST_CONTEXT="${1:-chat}"
  OWL_HDR_PROJECT="${CLAU_SESSION_NAME:-$(basename "$PWD")}"
  OWL_HDR_USER="${CLAU_USER_TAG:-$(whoami)}"
}

# Prüft, ob im aktuellen Verzeichnis .claude/settings.json schreibbar (anlegbar) ist.
# Gibt 1 zurück und warnt einmalig, wenn nicht (z.B. clau in fremdem Home gestartet).
_CLAUDE_DIR_RO_WARNED=0
_claude_dir_writable() {
  if [[ -e ".claude/settings.json" ]]; then
    [[ -w ".claude/settings.json" ]] && return 0
  elif [[ -d ".claude" ]]; then
    [[ -w ".claude" ]] && return 0
  else
    [[ -w "." ]] && return 0
  fi
  if [[ "$_CLAUDE_DIR_RO_WARNED" -eq 0 ]]; then
    _CLAUDE_DIR_RO_WARNED=1
    echo "⚠️  clau: '.claude/settings.json' in $(pwd) nicht schreibbar – Tool-Blocking wird übersprungen." >&2
  fi
  return 1
}

_CONFIG_RO_WARNED=0
_warn_config_readonly() {
  [[ "$_CONFIG_RO_WARNED" -eq 1 ]] && return 0
  _CONFIG_RO_WARNED=1
  echo "⚠️  clau: '$CONFIG_FILE' in $(pwd) nicht beschreibbar und kein Ausweich-Pfad im Home nutzbar –" >&2
  echo "   Einstellungen werden diesmal nicht gespeichert. (Session selbst läuft normal.)" >&2
}

# Einmaliger, unaufgeregter Hinweis: Config liegt im Home statt im Projektordner
_CONFIG_FB_NOTED=0
_note_config_fallback() {
  [[ "$_CONFIG_FB_NOTED" -eq 1 ]] && return 0
  _CONFIG_FB_NOTED=1
  echo "ℹ️  Ordner nicht beschreibbar – Einstellungen werden stattdessen hier gemerkt:" >&2
  echo "   $1" >&2
}

save_config() {
  # Ziel: normalerweise ./.clau.conf. Ist der Ordner nicht beschreibbar
  # (z.B. clau in fremdem Home), weichen wir auf eine Datei im eigenen Home aus,
  # damit die Einstellungen trotzdem erhalten bleiben.
  local target="$CONFIG_FILE" writable=1
  if [[ -e "$CONFIG_FILE" ]]; then
    [[ -w "$CONFIG_FILE" ]] || writable=0
  else
    [[ -w "." ]] || writable=0
  fi
  if [[ "$writable" -eq 0 ]]; then
    target="$(_conf_fallback_file)"
    mkdir -p "$(dirname "$target")" 2>/dev/null || { _warn_config_readonly; return 0; }
    _note_config_fallback "$target"
  fi
  cat > "$target" <<CONF_EOF
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
CLAU_WEBSEARCH="${CLAU_WEBSEARCH:-1}"
CLAU_TEAM="${CLAU_TEAM:-0}"
CLAU_TEAM_LEAD_MODEL="${CLAU_TEAM_LEAD_MODEL:-120}"
CLAU_TEAM_EXEC_MODEL="${CLAU_TEAM_EXEC_MODEL:-121}"
CLAU_TEAM_MAX_AGENTS="${CLAU_TEAM_MAX_AGENTS:-5}"
CLAU_TEAM_SLOTS_121="${CLAU_TEAM_SLOTS_121:-3}"
CLAU_TEAM_STATUS_URL="${CLAU_TEAM_STATUS_URL:-http://127.0.0.1:8293/slots}"
CLAU_TEAM_SUBAGENTS="${CLAU_TEAM_SUBAGENTS:-pi}"
CLAU_API="${CLAU_API:-0}"
CLAU_API_BIND="${CLAU_API_BIND:-127.0.0.1:7010}"
CLAU_API_TOKEN="${CLAU_API_TOKEN:-}"
CLAU_OFFLINE="${CLAU_OFFLINE:-0}"
CLAU_OWL_ROUTES="${CLAU_OWL_ROUTES:-}"
CLAU_BACKEND="${CLAU_BACKEND:-claude}"
CLAU_QWEN_MODEL="${CLAU_QWEN_MODEL:-qwen3.8-max}"
CLAU_QWEN_FAST_MODEL="${CLAU_QWEN_FAST_MODEL:-qwen3.8-flash}"
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

# Claude Code rechnet die Compact-Schwelle so (2.1.x, aus dem Code gelesen):
#   Fenster  = min(Fenster, das es dem Modell zutraut; CLAUDE_CODE_AUTO_COMPACT_WINDOW)
#   Schwelle = Fenster - min(max_output, 20000) - 13000
# und hebt CLAUDE_CODE_AUTO_COMPACT_WINDOW auf mindestens 100000 an.
# Früher setzten wir die Variable direkt auf 80 % -- dann zog Claude Code die
# 33k noch einmal ab und kompaktierte viel zu früh. Jetzt: gewünschte Schwelle
# + 33000, höchstens das echte Fenster.
CC_COMPACT_RESERVE=33000

# Exportiert CLAUDE_CODE_AUTO_COMPACT_WINDOW für ein Modell mit echtem Fenster $1
# und meldet die tatsächliche Schwelle. $2 = Bezeichnung fürs Log.
_apply_compact_window() {
  local cw="$1" label="$2"
  if [[ -z "$cw" || "$cw" -le 0 ]]; then
    unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
    return 0
  fi
  local want; want="$(compute_auto_compact_window "$cw")"
  local w=$(( want + CC_COMPACT_RESERVE ))
  [[ "$w" -gt "$cw" ]] && w="$cw"
  [[ "$w" -lt 100000 ]] && w=100000     # Claude Codes Untergrenze
  [[ "$w" -gt 1000000 ]] && w=1000000   # und Obergrenze
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$w"
  echo "Auto-Compact: ab ~$(( w - CC_COMPACT_RESERVE )) Tokens (Fenster $cw, $label)"
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
  if team_active && [[ ",${disable_tools// /}," == *",Agent,"* ]]; then
    echo "Team-Modus: 'Agent' bleibt trotz CLAU_DISABLE_TOOLS erlaubt."
    disable_tools="$(echo ",${disable_tools// /}," | sed 's/,Agent,/,/g; s/^,//; s/,$//')"
  fi
  [[ -n "$disable_tools" ]] || return 0
  _claude_dir_writable || return 0

  local settings_dir=".claude"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir" 2>/dev/null || return 0

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
  [[ -w "$settings_file" ]] || return 0

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
  clau --import-md datei.md       Startet eine neue Session mit dem Inhalt von datei.md als erster
                                  Nachricht (Session-Auswahl → Punkt 5 exportiert umgekehrt als .md)
  clau --all-sessions             Alle Claude-Code-Sessions (alle Projekte) auflisten & fortsetzen
  clau --running-sessions         Nur die JETZT laufenden Sessions (andere Terminals/Hintergrund)
  clau --model N                  Setzt das Standardmodell (1=haiku, 2=sonnet, 3=opus5.5, 4=fable)
  clau --take ID                  Merkt sich eine feste Session-ID für dieses Verzeichnis
  clau --forget                   Entfernt die gemerkte Session-ID
  clau --current                  Zeigt aktuelle Session/Model-Config
  clau --api                      Fernsteuerung (HTTP, CLAU_API_BIND) im Vordergrund starten
  clau --api-stop                 Im Hintergrund laufende Fernsteuerung beenden
  clau --clear-model              Entfernt das gespeicherte Modell
  clau --install                  Installiert "clau" + claude-code + opencode nach ~/.local/bin
  clau --uninstall                Entfernt "clau" aus ~/.local/bin
  clau --self-update              Aktualisiert clau auf die neueste Version aus dem Git-Repo

Telegram / Handy:
  clau --tg-token                 Bot-Token reinpasten (wird geprüft & gespeichert)
  clau --tg-setup                 Ermittelt & speichert die Gruppen-ID (Bot muss in der Gruppe sein)
  clau --tg-test                  Sendet eine Testnachricht in die Gruppe
  clau --tg-whoami                Zeigt deine Telegram-User-ID (für CLAU_TG_ALLOWED_USER)
  clau --tg-hooks-off             Entfernt die globalen Telegram-Hooks wieder
  clau --mirror                   LIVE-Modus: Session in tmux, parallel am Bildschirm
                                  UND im Telegram-Topic – in beide Richtungen bedienbar
                                  (Loslösen: Strg-b d, wieder ran: clau --mirror)
  clau --tg-bot                   Bot-Poller: vom Handy entwickeln (Dauerprozess, tmux/systemd)
                                  In einem Topic: /cd <pfad> setzen, dann Text = Anweisung an Claude.
  Phase 1 (Benachrichtigung): pro Session ein Topic, meldet Rückfrage/Fertig/Ende.
  Config (lokal, geheim): ~/.config/clau/telegram.conf
    CLAU_TG_ENABLED=1  CLAU_TG_BOT_TOKEN=...  CLAU_TG_GROUP_ID=...
    CLAU_TG_EVENTS="notification,stop,sessionend"  (welche Events melden)
    CLAU_TG_ALLOWED_USER="<id>"  (nur diese Telegram-ID darf per Bot Code ausführen)
    CLAU_TG_BRAIN=1  CLAU_TG_BRAIN_MODEL="gemma-12b-chat"  (Concierge: kleines Modell,
      das plaudert/navigiert und Coding-Aufträge an Claude weiterreicht; 0 = aus)
    CLAU_TG_PROJECT_ROOT="$HOME"  (wo nach Projekten gesucht wird)

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
      --backend claude|opencode|qwenplan
                                  CLI-Engine für diesen Aufruf (Standard: claude,
                                  per-Verzeichnis in .clau.conf gespeichert via Menü
                                  "CLI-Engine wechseln"). qwenplan = Claude Code mit
                                  Alibaba Qwen Token Plan, nur interaktiv (AGB)
      --qwen-model [MODELL]       Modell für qwenplan setzen (ohne Wert: Auswahlmenü)
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
  Claude Code (agentisch):  1=haiku(4.5)  2=sonnet(5)  3=opus(5.5)  4=fable(5)
  owlAPI (für --model N):   5=owl:120 (Q27B)  6=owl:121 (Flash-Next)  7=owl:126 (Flash-Next 262k)  0=owl:free
  owlAPI direkt:            -m owl:350  oder  -m 350   (interaktiv: Live-Liste der owlAPI)
  Qwen Token Plan:          -m qwen:qwen3.8-max  (setzt Engine qwenplan für diesen Aufruf)

Token-Optimierung (in .clau.conf konfigurierbar):
  CLAU_AUTO_COMPACT_WINDOW="90000"   Festes Auto-Compact-Limit (leer = Prozent-basiert)
  CLAU_AUTO_COMPACT_PCT="80"         Prozent des Context-Windows (Default 80)
  CLAU_DISABLE_TOOLS="WebFetch,Agent"  Tools aus System-Prompt entfernen (kommagetrennt)
  CLAU_DISABLE_ARTIFACT="1"          Artifacts deaktivieren (spart ~2-3K Tokens)
  CLAU_DISABLE_AGENT_VIEW="1"        Hintergrund-Agenten deaktivieren (spart ~1-2K Tokens)
  CLAU_WEBSEARCH="1"                 Lokale QuiteQue-Websuche als MCP-Tool (Default an, ~300 Tokens)
  CLAU_BACKEND="claude"               CLI-Engine: claude (Standard) | opencode | qwenplan
  CLAU_QWEN_MODEL="qwen3.8-max"       Modell für qwenplan (Key: ~/.config/clau/qwenplan.key, chmod 600)
  CLAU_QWEN_FAST_MODEL="qwen3.8-flash" schnelles Modell für qwenplan
  CLAU_QWEN_COMPACT_AT="200000"       qwenplan: Auto-Compact ab so vielen Tokens (Fenster 1M; höher = mehr Credits/Anfrage)
  CLAU_TIMEOUT_DEFAULT="1800000"     Default Bash-Timeout in ms (30 Min = 1800000)
  CLAU_TIMEOUT_MAX="7200000"         Max Bash-Timeout in ms (120 Min = 7200000)
  CLAU_OWL_TIMEOUT="1800"            owlAPI-Request-Timeout in Sekunden (Default 1800 = 30 Min)
  owlAPI-Proxy-Log: ~/.cache/clau/owl_proxy.log (wird bei jedem Start überschrieben)
  CLAU_OWL_MINIMAL_TOOLS="1"         Schlankes Tool-Set + keine MCP-Server für owlAPI (Default an)
  CLAU_OWL_TOOLS="Bash,Edit,..."     Eigene Tool-Allowlist statt des Defaults (s.o.)
  CLAU_UPDATE_CHECK="1"              Beim Start gegen GitHub auf Updates prüfen (0 = aus)
  CLAU_OFFLINE="0"                   1 = ohne Internet: kein Update-Check, keine Websuche, keine Netz-Installation
  CLAU_TEAM="0"                      1 = Team-Modus (Teamleiter owl-120, Ausführer-Agenten owl-121)
  CLAU_TEAM_LEAD_MODEL="120"         Teamleiter-Modell (QuiteQue-ID)
  CLAU_TEAM_EXEC_MODEL="121"         Ausführer-Modell (Agenten mit model: sonnet)
  CLAU_TEAM_MAX_AGENTS="5"           Max. parallele Ausführer bei freien Slots
  CLAU_TEAM_SLOTS_121="3"            Max. gleichzeitige Anfragen an 121 (Rest wartet im Proxy)
  CLAU_TEAM_STATUS_URL="http://127.0.0.1:8293/slots"  Slot-Status für das Tool llm_status
  CLAU_API="0"                       1 = Fernsteuerung beim clau-Start im Hintergrund starten
  CLAU_API_BIND="127.0.0.1:7010"     Adresse der Fernsteuerung
  CLAU_API_TOKEN=""                  Bearer-Token (Pflicht bei nicht-lokalem Bind)
  CLAU_OWL_ROUTES=""                 Modelle direkt statt über QuiteQue, z.B.
                                     "120=http://h:8292/v1,121=http://h:8293/v1#qwen3.8-flash-next"
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
    6) CLAU_MODEL="owl:121" ;;   # Qwen3.8-Flash-Next lokal (97k)
    7) CLAU_MODEL="owl:126" ;;   # Qwen3.8-Flash-Next lokal (262k, 1 Session)
    0) CLAU_MODEL="owl:free" ;;  # free Router gratis
    *)
      echo "Unbekanntes Modell-Kürzel: $1 (erlaubt: 1-4=Claude CLI, 5/6/7/0=owlAPI, sonst -m owl:<ID>)" >&2
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
    qwen:*)
      # Qwen Token Plan: Engine für diesen Aufruf auf qwenplan, Modell setzen
      CLI_BACKEND_OVERRIDE="qwenplan"
      CLAU_QWEN_MODEL="${1#qwen:}"
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
  elif team_active; then
    # Team-Modus läuft immer über den lokalen Teamleiter
    echo "owl:$(team_lead_model)"
  elif [[ -n "${CLAU_MODEL:-}" ]]; then
    echo "$CLAU_MODEL"
  else
    echo ""
  fi
}

# CLI-Engine (nicht zu verwechseln mit dem Modell-Routing owl-vs-Claude):
# "claude" (Claude Code, Standard) oder "opencode".
effective_backend() {
  if [[ -n "${CLI_BACKEND_OVERRIDE:-}" ]]; then
    echo "$CLI_BACKEND_OVERRIDE"
  else
    echo "${CLAU_BACKEND:-claude}"
  fi
}

# Übersetzt den internen Claude-Modell-Kurznamen in die volle Modell-ID, die die
# claude-CLI erwartet. Explizit gepinnt auf die aktuelle Generation (Stand 2026-09):
#   haiku=Haiku 4.5, sonnet=Sonnet 5, opus=Opus 5.5, fable=Fable 5.
# Bei neuer Generation hier einmalig aktualisieren.
claude_cli_model() {
  case "${1:-}" in
    haiku)  echo "claude-haiku-4-5" ;;
    sonnet) echo "claude-sonnet-5" ;;
    opus)   echo "claude-opus-5-5" ;;
    fable)  echo "claude-fable-5" ;;
    *) echo "$1" ;;
  esac
}

show_current() {
  local mdl="${CLAU_MODEL:-<nicht gesetzt>}"
  local route="Claude Code (agentisch)"
  if is_owl_model "${CLAU_MODEL:-}"; then
    route="owlAPI Chat (${OWL_BASE_URL}, Modell $(owl_model_id "${CLAU_MODEL}"))"
  fi
  if team_active; then
    route="Team-Modus über owlAPI (${OWL_BASE_URL}, Teamleiter $(team_lead_model), Ausführer $(team_exec_model))"
  fi
  echo "Aktuelles Verzeichnis : $(pwd)"
  echo "Konfiguriertes Modell : $mdl"
  echo "Modell-Route          : $route"
  echo "CLI-Engine            : $(effective_backend)"
  if [[ "$(effective_backend)" == "qwenplan" ]]; then
    echo "Qwen-Modell           : ${CLAU_QWEN_MODEL} (schnell: ${CLAU_QWEN_FAST_MODEL})"
    echo "Qwen-Key-Datei        : $QWENPLAN_KEY_FILE $([[ -f "$QWENPLAN_KEY_FILE" ]] && echo "(vorhanden)" || echo "(FEHLT)")"
  fi
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
  echo "Websuche (MCP)        : $([[ "${CLAU_WEBSEARCH:-1}" == "1" ]] && echo "an (depth=speed)" || echo "aus")"
  if team_active; then
    echo "Team-Modus            : AN (Teamleiter owl-$(team_lead_model), Ausführer owl-$(team_exec_model), max. $(_team_exec_slots) parallel / ${CLAU_TEAM_MAX_AGENTS:-5} Agenten, Subagenten: $(team_pi_active && echo pi || echo "Claude Code"))"
    echo "Team-Status-URL       : ${CLAU_TEAM_STATUS_URL}"
  else
    echo "Team-Modus            : aus"
  fi
  if [[ "${CLAU_API:-0}" == "1" ]]; then
    echo "Fernsteuerung (API)   : AN (${CLAU_API_BIND}, Token $([[ -n "${CLAU_API_TOKEN:-}" ]] && echo gesetzt || echo "nicht gesetzt"))"
  else
    echo "Fernsteuerung (API)   : aus"
  fi
  local owl_id_for_preset=""
  if [[ "${CLAU_MODEL:-}" == owl:* ]]; then owl_id_for_preset="${CLAU_MODEL#owl:}"; fi
  local preset_d="" preset_m=""
  if [[ -n "$owl_id_for_preset" ]]; then
    preset_d="${TIMEOUT_PRESET_DEFAULT[$owl_id_for_preset]:-}"
    preset_m="${TIMEOUT_PRESET_MAX[$owl_id_for_preset]:-}"
  fi
  local preset_indicator=""
  if [[ -n "$preset_d" && "$CLAU_TIMEOUT_DEFAULT" == "$preset_d" && "$CLAU_TIMEOUT_MAX" == "$preset_m" ]]; then
    preset_indicator=" (Preset)"
  elif [[ -n "$preset_d" ]]; then
    preset_indicator=" (angepasst, Preset: $(( preset_d / 60000 )) / $(( preset_m / 60000 )) Min)"
  fi
  echo "Timeout Default        : $(( CLAU_TIMEOUT_DEFAULT / 60000 )) Min (${CLAU_TIMEOUT_DEFAULT} ms)${preset_indicator}"
  echo "Timeout Max            : $(( CLAU_TIMEOUT_MAX / 60000 )) Min (${CLAU_TIMEOUT_MAX} ms)"
}

# Gibt Zellen spaltenweise aus (füllt Spalte für Spalte, Breite nach Terminal).
# $1 = Zellenbreite, Rest = Zellen
_print_cols() {
  local w="$1"; shift
  local n=$# tw="${COLUMNS:-}"
  [[ -n "$tw" ]] || tw="$(tput cols 2>/dev/null || echo 120)"
  local cols=$(( (tw - 2) / w )); [[ "$cols" -ge 1 ]] || cols=1
  local rows=$(( (n + cols - 1) / cols ))
  local cells=("$@") r c i line
  for ((r = 0; r < rows; r++)); do
    line=""
    for ((c = 0; c < cols; c++)); do
      i=$(( c * rows + r ))
      [[ "$i" -lt "$n" ]] || continue
      line+="$(printf "%-${w}s" "${cells[$i]}")"
    done
    echo "  ${line%"${line##*[![:space:]]}"}"
  done
}

# Feste Presets (auch ohne owlAPI-Verbindung): Taste → owl-ID
declare -gA OWL_PRESETS=( ["5"]="120" ["6"]="121" ["7"]="126" ["0"]="free" )

choose_model_interactive() {
  local nq=${#QWENPLAN_MODELS[@]}
  # owlAPI-Liste (gecacht, 3 s Timeout), ohne Presets und ohne Kleinst-Kontext
  local rows=() line id st own ctx price name
  while IFS= read -r line; do
    IFS=$'\t' read -r id st own ctx price name <<< "$line"
    [[ "$id" == "120" || "$id" == "121" || "$id" == "126" || "$id" == "free" ]] && continue
    [[ "$ctx" -ge 64000 ]] || continue
    rows+=("$line")
  done < <(_owl_models_tsv 2>/dev/null)

  while true; do
    echo
    echo "Modell wählen:"
    echo "  --- Claude Code mit Claude-Abo ---"
    _print_cols 38 "1) haiku   Haiku 4.5" "2) sonnet  Sonnet 5  [Enter]" "3) opus    Opus 5.5" "4) fable   Fable 5"
    echo "  --- Presets: lokal (PropellerA) + QuiteQue Free-Plan, via owlAPI ---"
    _print_cols 38 "5) Q27B         owl:120  94k" "6) Flash-Next   owl:121  97k" \
                   "7) Flash-Next   owl:126  262k" "0) Free-Plan    owl:free (Router)"
    echo "  --- Qwen Token Plan (Alibaba-Abo, nur interaktiv) ---"
    local cells=() i=1 m
    for m in "${QWENPLAN_MODELS[@]}"; do cells+=("q${i}) ${m}"); ((i++)); done
    _print_cols 26 "${cells[@]}"
    if [[ "${#rows[@]}" -gt 0 ]]; then
      echo "  --- owlAPI live (${OWL_BASE_URL}) · Auswahl per ID · Preis \$/MTok ein/aus ---"
      local grp prev="" ctxs short
      cells=()
      for line in "${rows[@]}"; do
        IFS=$'\t' read -r id st own ctx price name <<< "$line"
        case "$own" in
          openrouter) grp="OpenRouter" ;; alibaba) grp="Alibaba" ;; xai) grp="xAI" ;;
          deepseek) grp="DeepSeek" ;; claude|anthropic) grp="Claude" ;;
          *) [[ "$price" == "GRATIS" ]] && grp="gratis" || grp="$own" ;;
        esac
        if [[ "$grp" != "$prev" ]]; then
          [[ "${#cells[@]}" -gt 0 ]] && _print_cols 47 "${cells[@]}"
          echo "  · $grp"
          cells=(); prev="$grp"
        fi
        if [[ "$ctx" -ge 1000000 ]]; then ctxs="$((ctx / 1000000))M"; else ctxs="$((ctx / 1000))k"; fi
        short="${name%% (*}"; short="${short#Anthropic }"; short="${short#Google }"; short="${short#OpenAI }"
        price="${price//\$/}"; [[ "$price" == "GRATIS" ]] && price="gratis"
        short="${short#Meta }"; short="${short#MoonshotAI }"
        cells+=("$(printf '%4s %-23.23s %4s %s' "$id" "$short" "$ctxs" "$price")")
      done
      [[ "${#cells[@]}" -gt 0 ]] && _print_cols 47 "${cells[@]}"
    else
      echo "  (owlAPI nicht erreichbar — Liste fehlt, Presets und 'o' gehen trotzdem)"
    fi
    echo "  o) owlAPI-ID direkt eingeben"
    printf "Auswahl [1-7, 0, q1-q%d, owl-ID, o, Enter=2]: " "$nq"
    local choice; read -r choice
    choice="${choice:-2}"

    if [[ "$choice" =~ ^[qQ]([0-9]+)$ ]]; then
      local qi="${BASH_REMATCH[1]}"
      if [[ "$qi" -ge 1 && "$qi" -le "$nq" ]]; then
        CLAU_QWEN_MODEL="${QWENPLAN_MODELS[$((qi-1))]}"
        CLAU_BACKEND="qwenplan"
        _qwenplan_key >/dev/null || echo "Ohne Key-Datei startet 'qwenplan' nicht." >&2
        save_config
        echo "Engine: qwenplan, Qwen-Modell: $CLAU_QWEN_MODEL"
        return 0
      fi
      echo "Ungültige Auswahl."; continue
    fi
    case "$choice" in
      1) CLAU_MODEL="haiku"; break ;;
      2) CLAU_MODEL="sonnet"; break ;;
      3) CLAU_MODEL="opus"; break ;;
      4) CLAU_MODEL="fable"; break ;;
      5|6|7|0) CLAU_MODEL="owl:${OWL_PRESETS[$choice]}"; break ;;
      o|O)
        printf "owlAPI-Modell-ID: "
        local tmp_id; read -r tmp_id
        if [[ -n "$tmp_id" ]]; then
          CLAU_MODEL="owl:${tmp_id}"
          break
        fi
        echo "Abgebrochen."
        ;;
      *)
        local hit=""
        for line in "${rows[@]}"; do
          [[ "${line%%$'\t'*}" == "$choice" ]] && { hit="$choice"; break; }
        done
        if [[ -n "$hit" ]]; then CLAU_MODEL="owl:${hit}"; break; fi
        echo "Ungültige Auswahl."
        ;;
    esac
  done

  # Claude- oder owl-Modell gewählt: vom Qwen-Plan zurück auf Claude Code
  # (opencode bleibt opencode).
  [[ "${CLAU_BACKEND:-claude}" == "qwenplan" ]] && CLAU_BACKEND="claude"
  # Timeout-Preset für das gewählte Modell anwenden
  apply_timeout_for_model "$CLAU_MODEL"
  save_config
  echo "Modell: $CLAU_MODEL"
}

choose_backend_interactive() {
  echo
  echo "CLI-Engine wählen:"
  echo "  1) claude              Claude Code   Standard         [Enter]"
  echo "  2) opencode            opencode.ai   alternative Engine"
  echo "  3) qwenplan            Claude Code   mit Alibaba Qwen Token Plan (nur interaktiv)"
  printf "Auswahl [1-3, Enter=1]: "
  read -r choice
  case "${choice:-1}" in
    1) CLAU_BACKEND="claude" ;;
    2)
      CLAU_BACKEND="opencode"
      if ! _have opencode; then
        echo "opencode ist noch nicht installiert."
        if ask_yes_no "Jetzt installieren?"; then
          _ensure_opencode || echo "Installation fehlgeschlagen — 'opencode' bleibt vorerst nicht nutzbar." >&2
        fi
      fi
      ;;
    3)
      CLAU_BACKEND="qwenplan"
      _qwenplan_key >/dev/null || echo "Ohne Key-Datei startet 'qwenplan' nicht." >&2
      choose_qwen_model_interactive
      ;;
    *) echo "Ungültige Auswahl."; return ;;
  esac
  save_config
  echo "CLI-Engine: $CLAU_BACKEND"
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

    local preset_default="" preset_max=""
    if [[ -n "$owl_id" ]]; then
      preset_default="${TIMEOUT_PRESET_DEFAULT[$owl_id]:-}"
      preset_max="${TIMEOUT_PRESET_MAX[$owl_id]:-}"
    fi
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

choose_team_settings() {
  while true; do
    echo
    echo "Team-Modus / Fernsteuerung:"
    echo "  1) Team-Modus             : $(team_active && echo AN || echo aus)"
    echo "  2) Teamleiter-Modell      : owl:$(team_lead_model)"
    echo "  3) Ausführer-Modell       : owl:$(team_exec_model) (Slots: $(_team_exec_slots))"
    echo "  4) Max. Agenten           : ${CLAU_TEAM_MAX_AGENTS:-5}"
    echo "  5) Slot-Status-URL        : ${CLAU_TEAM_STATUS_URL}"
    echo "  8) Subagenten             : ${CLAU_TEAM_SUBAGENTS:-pi}$([[ "${CLAU_TEAM_SUBAGENTS:-pi}" == "pi" ]] && ! _team_pi_bin >/dev/null && echo "  (pi nicht gefunden → claude)")"
    echo "  6) Fernsteuerung (API)    : $([[ "${CLAU_API:-0}" == "1" ]] && echo AN || echo aus)  (${CLAU_API_BIND})"
    echo "  7) API-Token              : $([[ -n "${CLAU_API_TOKEN:-}" ]] && echo gesetzt || echo "<leer>")"
    echo "  0) Zurück"
    printf "Auswahl: "
    local c v; read -r c
    case "$c" in
      1) if team_active; then CLAU_TEAM=0; else CLAU_TEAM=1; fi ;;
      2) printf "QuiteQue-ID Teamleiter [%s]: " "$(team_lead_model)"; read -r v; [[ -n "$v" ]] && CLAU_TEAM_LEAD_MODEL="${v#owl:}" ;;
      3) printf "QuiteQue-ID Ausführer [%s]: " "$(team_exec_model)"; read -r v; [[ -n "$v" ]] && CLAU_TEAM_EXEC_MODEL="${v#owl:}"
         if [[ "$(team_exec_model)" == "121" ]]; then
           printf "Slots für 121 [%s]: " "${CLAU_TEAM_SLOTS_121:-3}"; read -r v
           [[ "$v" =~ ^[0-9]+$ ]] && CLAU_TEAM_SLOTS_121="$v"
         fi ;;
      4) printf "Max. Agenten [%s]: " "${CLAU_TEAM_MAX_AGENTS:-5}"; read -r v; [[ "$v" =~ ^[0-9]+$ ]] && CLAU_TEAM_MAX_AGENTS="$v" ;;
      5) printf "Slot-Status-URL [%s]: " "$CLAU_TEAM_STATUS_URL"; read -r v; [[ -n "$v" ]] && CLAU_TEAM_STATUS_URL="$v" ;;
      6) if [[ "${CLAU_API:-0}" == "1" ]]; then CLAU_API=0; else CLAU_API=1; fi
         printf "Bind-Adresse [%s]: " "$CLAU_API_BIND"; read -r v; [[ -n "$v" ]] && CLAU_API_BIND="$v" ;;
      7) printf "API-Token (leer = keiner): "; read -r v; CLAU_API_TOKEN="$v" ;;
      8) if [[ "${CLAU_TEAM_SUBAGENTS:-pi}" == "pi" ]]; then CLAU_TEAM_SUBAGENTS=claude; else CLAU_TEAM_SUBAGENTS=pi; fi ;;
      0|"") return 0 ;;
      *) echo "Ungültige Auswahl." ; continue ;;
    esac
    save_config
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
  if [[ "${CLAU_OFFLINE:-0}" == "1" ]]; then
    echo "  WARN: claude-code fehlt, CLAU_OFFLINE=1 → keine Installation aus dem Netz." >&2
    return 1
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
_ensure_tmux() {
  _have tmux && return 0
  echo "tmux fehlt (für --mirror/Bot im Hintergrund) — installiere ..."
  if _have apt-get; then sudo apt-get install -y tmux >/dev/null 2>&1 || return 1
  elif _have dnf; then sudo dnf install -y tmux >/dev/null 2>&1 || return 1
  elif _have pacman; then sudo pacman -S --noconfirm tmux >/dev/null 2>&1 || return 1
  else echo "  → bitte tmux manuell installieren" >&2; return 1; fi
  _have tmux && echo "tmux installiert."
}

_ensure_opencode() {
  if _have opencode; then
    echo "  opencode: bereits vorhanden ($(command -v opencode))"
    return 0
  fi
  if [[ "${CLAU_OFFLINE:-0}" == "1" ]]; then
    echo "  opencode: fehlt, CLAU_OFFLINE=1 → übersprungen (nur für --backend opencode nötig)."
    return 1
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

# ── opencode-Backend ─────────────────────────────────────────────────────────
# opencode spricht OpenAI-kompatibles Chat-Format nativ (eigenes
# @ai-sdk/openai-compatible Provider-Config) -- für owl/QuiteQue-Modelle
# braucht es KEINEN owl_proxy.py-Umweg, im Gegensatz zu Claude Code (das nur
# die Anthropic Messages API spricht).

# Modell-String, den opencode selbst versteht: "owl/<id>" für lokale/owl-
# Modelle (via selbst geschriebenem Custom-Provider), "anthropic/<id>" für
# echte Claude-Modelle (opencodes eingebauter Anthropic-Provider, Auth läuft
# über Davids eigenes `opencode auth login`, nicht über uns).
_opencode_model_arg() {
  local mdl="$1"
  if is_owl_model "$mdl"; then
    echo "owl/$(owl_model_id "$mdl")"
  else
    echo "anthropic/$(claude_cli_model "$mdl")"
  fi
}

# Schreibt/aktualisiert opencode.json im aktuellen Projektverzeichnis: setzt
# das Default-Modell, und bei owl-Modellen zusätzlich den Custom-Provider-
# Block der direkt auf QuiteQue/PropellerA zeigt. Bestehende opencode.json
# wird gemergt, nicht überschrieben (andere Keys bleiben erhalten).
_opencode_sync_config() {
  local mdl="$1"
  local model_arg; model_arg="$(_opencode_model_arg "$mdl")"
  if is_owl_model "$mdl"; then
    # QuiteQue verlangt X-Request-Context/X-Agent-Tool/X-Project inzwischen
    # als Pflicht-Header (GPU-Last-Zuordnung) -- opencode spricht QuiteQue
    # HIER direkt an (kein owl_proxy.py dazwischen), die Header müssen also
    # in genau diesem Provider-Block stehen, nicht nur beim Claude-Code-Pfad.
    _owl_activity_env "agent"
    python3 - "$model_arg" "${OWL_BASE_URL}/v1" "$(owl_model_id "$mdl")" "$QQ_USER" \
      "$OWL_HDR_AGENT_TOOL" "$OWL_HDR_REQUEST_CONTEXT" "$OWL_HDR_PROJECT" "$OWL_HDR_USER" <<'PY'
import json
import sys

path = "opencode.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
model_arg, base_url, owl_id, qq_user, agent_tool, request_context, project, hdr_user = sys.argv[1:9]
cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg["model"] = model_arg
cfg.setdefault("provider", {})["owl"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "QuiteQue/PropellerA (owl)",
    "options": {
        "baseURL": base_url,
        "headers": {
            "X-OwlTrail-User": qq_user,
            "X-Agent-Tool": agent_tool,
            "X-Request-Context": request_context,
            "X-Project": project,
            "X-User": hdr_user,
        },
    },
    "models": {owl_id: {"name": f"owl:{owl_id}"}},
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  else
    python3 - "$model_arg" <<'PY'
import json
import sys

path = "opencode.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg["model"] = sys.argv[1]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  fi
}

# Stellt sicher dass opencode installiert ist (fragt ggf. nach Installation).
_ensure_opencode_runtime() {
  _have opencode && return 0
  echo "opencode ist nicht installiert." >&2
  if ask_yes_no "Jetzt installieren?"; then
    _ensure_opencode && return 0
  fi
  echo "Kann ohne opencode nicht fortfahren." >&2
  return 1
}

# Interaktive opencode-Session (Analogie zu run_new_session/run_saved_session
# für Claude Code). Resume läuft über opencodes eigenen /sessions-Picker in
# der TUI -- ein von außen scriptbares "--resume <id>" ist für den
# interaktiven Fall nicht belegt.
run_opencode_session() {
  local mdl; mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  _ensure_opencode_runtime || exit 1
  _opencode_sync_config "$mdl"
  local model_arg; model_arg="$(_opencode_model_arg "$mdl")"
  echo "Starte opencode (Modell: $mdl, Autonomie: $(interaction_label)) ..."
  cleanup_tool_blocking
  unset_token_saver_env
  # KEIN --auto hier: die installierte opencode-Version kennt dieses Flag bei
  # der nackten TUI-Invocation nicht (bestätigt am 15.09.2026 -- fiel auf
  # Usage/Help zurück statt zu starten). Level-0-Vollautomatik müsste über
  # den "permission"-Block in opencode.json laufen, nicht über einen
  # CLI-Flag -- noch nicht verifiziert, daher vorerst weggelassen.
  exec opencode --model "$model_arg"
}

# Headless-Kommando für opencode (Analogie zu build_headless_cmd). Füllt
# OPENCODE_CMD als Array.
build_opencode_headless_cmd() {
  local mdl; mdl="$(effective_model)"
  _opencode_sync_config "$mdl"
  local model_arg; model_arg="$(_opencode_model_arg "$mdl")"
  OPENCODE_CMD=(opencode run --model "$model_arg")
  if [[ -z "${PROMPT_TEXT:-}" ]]; then
    echo "--headless erfordert einen Prompt mit -p/--prompt." >&2
    exit 1
  fi
  OPENCODE_CMD+=("$PROMPT_TEXT")
}

# ── Backend "qwenplan": Alibaba Model Studio Token Plan (Qwen-Abo) ───────────
# Claude Code spricht direkt mit Alibabas Anthropic-kompatiblem Endpunkt, ohne
# lokalen Proxy. Laut AGB NUR interaktive Nutzung in Coding-Tools auf diesem
# einen Gerät: kein Headless, keine Automation, nicht über owlAPI/QuiteQue,
# Key nicht teilen. Deshalb verweigern die Headless-Pfade dieses Backend.
# Der Key steht nie im Skript oder in Git, sondern in einer Datei mit chmod 600.
QWENPLAN_BASE_URL="${QWENPLAN_BASE_URL:-https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic}"
QWENPLAN_KEY_FILE="${QWENPLAN_KEY_FILE:-$HOME/.config/clau/qwenplan.key}"
QWENPLAN_MODELS=(qwen3.8-max qwen3.8-flash qwen3.7-max qwen3.7-plus qwen3.6-flash
                 deepseek-v4-pro deepseek-v4.1-flash glm-5.3 glm-5.2 auto)

_qwenplan_model_desc() {
  case "$1" in
    qwen3.8-max)         echo "Standard, 1M Kontext" ;;
    qwen3.8-flash)       echo "schnell, 1M Kontext" ;;
    qwen3.7-max)         echo "Vorgänger Max" ;;
    qwen3.7-plus)        echo "Mittelklasse" ;;
    qwen3.6-flash)       echo "älter, schnell" ;;
    deepseek-v4-pro)     echo "DeepSeek, Reasoning" ;;
    deepseek-v4.1-flash) echo "DeepSeek, schnell" ;;
    glm-5.3|glm-5.2)     echo "Z.ai GLM" ;;
    auto)                echo "Alibaba wählt selbst" ;;
  esac
}

# Gibt den API-Key aus. Quelle: $QWENPLAN_KEY_FILE (muss chmod 600 sein),
# Rückfall: ~/.config/owl/system_config.json → qwenplan.api_key.
_qwenplan_key() {
  local f="$QWENPLAN_KEY_FILE"
  if [[ -f "$f" ]]; then
    local perm; perm="$(stat -c '%a' "$f" 2>/dev/null)"
    if [[ "$perm" != "600" && "$perm" != "400" ]]; then
      echo "Fehler: $f hat Rechte $perm — bitte 'chmod 600 $f'." >&2
      return 1
    fi
    tr -d '[:space:]' < "$f"
    return 0
  fi
  local sc="$HOME/.config/owl/system_config.json"
  if [[ -f "$sc" ]]; then
    local k
    k="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("qwenplan",{}).get("api_key",""))' "$sc" 2>/dev/null)"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  echo "Fehler: Kein Qwen-Token-Plan-Key gefunden." >&2
  echo "  Ablegen mit:  mkdir -p ~/.config/clau && (umask 077; cat > $f)   # Key einfügen, Strg-D" >&2
  return 1
}

# Kurzer Vorab-Request (max_tokens=1, ~60 Tokens): prüft Key, Modell und
# Kontingent und übersetzt Fehler in eine klare Meldung, bevor Claude Code startet.
# CLAU_QWENPLAN_PREFLIGHT=0 schaltet ihn ab.
_qwenplan_preflight() {
  local key="$1" model="$2"
  [[ "${CLAU_QWENPLAN_PREFLIGHT:-1}" == "1" ]] || return 0
  local body http
  body="$(curl -s -m 30 -w $'\n%{http_code}' "${QWENPLAN_BASE_URL}/v1/messages" \
    -H "Authorization: Bearer ${key}" -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -d "{\"model\":\"${model}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>/dev/null)"
  http="${body##*$'\n'}"; body="${body%$'\n'*}"
  [[ "$http" == "200" ]] && return 0
  local code msg
  code="$(printf '%s' "$body" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
e=d.get("error") if isinstance(d.get("error"),dict) else d
print(e.get("code") or e.get("type") or "")' 2>/dev/null)"
  msg="$(printf '%s' "$body" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
e=d.get("error") if isinstance(d.get("error"),dict) else d
print(e.get("message") or "")' 2>/dev/null)"
  echo >&2
  echo "✗ Qwen Token Plan antwortet nicht mit OK (HTTP ${http:-—}${code:+, $code})." >&2
  [[ -n "$msg" ]] && echo "  Server: $msg" >&2
  case "$http:$code:$msg" in
    000:*)              echo "  → Keine Verbindung zu ${QWENPLAN_BASE_URL}." >&2 ;;
    401:*|*InvalidApiKey*) echo "  → API-Key ungültig. Datei prüfen: $QWENPLAN_KEY_FILE" >&2 ;;
    *"Model not exist"*) echo "  → Modell '$model' gibt es im Plan nicht. Anderes wählen: clau --qwen-model" >&2 ;;
    *[Qq]uota*|*[Aa]rrearage*|*[Ii]nsufficient*|*[Ee]xhaust*|*[Ll]imit*|*[Ss]uspend*|*[Pp]ause*|403:*|429:*)
      echo "  → Wahrscheinlich ist das Credit-Kontingent aufgebraucht, der Dienst pausiert." >&2
      echo "    Stand nur in der Model-Studio-Konsole sichtbar. Reset laut Plan: 2026-11-04." >&2 ;;
  esac
  echo "  (Vorab-Check abschalten: CLAU_QWENPLAN_PREFLIGHT=0)" >&2
  return 1
}

choose_qwen_model_interactive() {
  echo
  echo "Qwen-Token-Plan-Modell wählen (aktuell: ${CLAU_QWEN_MODEL}):"
  local i=1 m
  for m in "${QWENPLAN_MODELS[@]}"; do
    printf "  %2d) %-19s %s\n" "$i" "$m" "$(_qwenplan_model_desc "$m")"
    ((i++))
  done
  printf "Auswahl [1-%d, Enter=behalten]: " "${#QWENPLAN_MODELS[@]}"
  local c; read -r c
  [[ -z "$c" ]] && return 0
  if [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le "${#QWENPLAN_MODELS[@]}" ]]; then
    CLAU_QWEN_MODEL="${QWENPLAN_MODELS[$((c-1))]}"
    save_config
    echo "Qwen-Modell: $CLAU_QWEN_MODEL"
  else
    echo "Ungültige Auswahl."
  fi
}

# Startet Claude Code interaktiv gegen den Token Plan. Argumente gehen an
# claude durch (z.B. --resume [id]).
run_qwenplan_session() {
  # Fernsteuerungs-Rollen (clau --api) sind Automation -- laut Token-Plan-AGB verboten.
  [[ -n "${CLAU_API_ROLE:-}${CLAU_API_SESSION_ID:-}" ]] && _qwenplan_refuse_headless
  local key; key="$(_qwenplan_key)" || exit 1
  local model="${CLAU_QWEN_MODEL:-qwen3.8-max}"
  local fast="${CLAU_QWEN_FAST_MODEL:-qwen3.8-flash}"
  _have claude || { echo "claude nicht gefunden." >&2; exit 1; }
  echo "Prüfe Qwen Token Plan (Modell $model) ..."
  _qwenplan_preflight "$key" "$model" || exit 1

  apply_tool_blocking
  token_saver_env >/dev/null
  export BASH_DEFAULT_TIMEOUT_MS="${CLAU_TIMEOUT_DEFAULT:-1800000}"
  export BASH_MAX_TIMEOUT_MS="${CLAU_TIMEOUT_MAX:-7200000}"
  # Claude Code kennt die Qwen-Modelle nicht und rechnet sonst mit 200k.
  # CLAUDE_CODE_MAX_CONTEXT_TOKENS gibt ihm das echte Fenster (1M für die
  # Plan-Modelle, CLAU_QWEN_CONTEXT überschreibt). Kompaktiert wird trotzdem
  # schon bei CLAU_QWEN_COMPACT_AT (Default 200k): jede Anfrage schickt den
  # ganzen Verlauf, bei 800k kostet das auch aus dem Cache ein Vielfaches an
  # Plan-Credits.
  local qcw="${CLAU_QWEN_CONTEXT:-1000000}"
  export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$qcw"
  CLAU_AUTO_COMPACT_WINDOW="${CLAU_QWEN_COMPACT_AT:-200000}" _apply_compact_window "$qcw" "$model"

  echo "Claude Code → Qwen Token Plan (Modell $model, schnell: $fast, Autonomie: $(interaction_label))"
  local extra; extra="$(_interaction_args)"
  # ANTHROPIC_AUTH_TOKEN (Bearer) statt ANTHROPIC_API_KEY: kein Bestätigungs-
  # dialog in Claude Code, und es gibt keinen Rückfall, bei dem das
  # Claude-Abo-OAuth-Token an den fremden Endpunkt geschickt würde.
  # Kein MCP (Websuche läuft über QuiteQue, das verbieten die AGB), keine Telegram-Hooks.
  # CLAUDE_CODE_ATTRIBUTION_HEADER=0: sonst steht im System-Prompt eine
  # "x-anthropic-billing-header: cc_version=…<hash>"-Zeile, die sich pro Session
  # ändert -- dann trifft der Prompt-Cache bei jedem Session-Start daneben
  # (~36k Tokens neu). Gleiches Problem wie bei owl_proxy (adb66d4).
  unset ANTHROPIC_API_KEY
  # shellcheck disable=SC2086
  ANTHROPIC_BASE_URL="$QWENPLAN_BASE_URL" \
  ANTHROPIC_AUTH_TOKEN="$key" \
  ANTHROPIC_MODEL="$model" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$fast" \
  ANTHROPIC_SMALL_FAST_MODEL="$fast" \
  CLAUDE_CODE_SUBAGENT_MODEL="$model" \
  CLAU_TG_SUPPRESS=1 \
  CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
  exec claude --model "$model" --strict-mcp-config $extra "$@"
}

# Headless/Automation ist laut Token-Plan-AGB verboten.
_qwenplan_refuse_headless() {
  echo "Backend 'qwenplan' ist nur interaktiv erlaubt (Alibaba Token Plan, AGB:" >&2
  echo "keine Automation, kein Headless/Backend-Betrieb). Abgebrochen." >&2
  exit 1
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
  _ensure_tmux || true

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

# Bügelt den Stand von GitHub über die installierte Kopie -- auch wenn dort
# lokal etwas geändert ist (git pull --rebase brach dann früher ab). Nichts
# geht verloren: lokale Commits landen in einem Branch backup/self-update-*,
# geänderte Dateien im git stash, die eigene .clau.conf bleibt erhalten.
self_update() {
  local script_path repo_dir
  script_path="$(readlink -f "$0")"
  repo_dir="$(dirname "$script_path")"
  local g=(git -C "$repo_dir")

  if ! "${g[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Das clau-Verzeichnis ($repo_dir) ist kein Git-Repository." >&2
    exit 1
  fi

  local branch; branch="$("${g[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ -z "$branch" || "$branch" == "HEAD" ]] && branch="main"
  echo "Hole $branch von $("${g[@]}" remote get-url origin 2>/dev/null || echo origin) ..."
  if ! "${g[@]}" fetch -q origin "$branch"; then
    echo "Fehler: git fetch fehlgeschlagen (Netz/Zugang?)." >&2
    exit 1
  fi

  local old new stamp; old="$("${g[@]}" rev-parse --short HEAD)"; new="$("${g[@]}" rev-parse --short "origin/$branch")"
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ "$("${g[@]}" rev-parse HEAD)" == "$("${g[@]}" rev-parse "origin/$branch")" ]] \
     && [[ -z "$("${g[@]}" status --porcelain --untracked-files=no)" ]]; then
    echo "clau ist schon aktuell ($new)."
    return 0
  fi

  local conf_bak=""
  if [[ -f "$repo_dir/.clau.conf" ]]; then
    conf_bak="$(mktemp)"; cp -p "$repo_dir/.clau.conf" "$conf_bak"
  fi
  local ahead; ahead="$("${g[@]}" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  if [[ "$ahead" -gt 0 ]]; then
    "${g[@]}" branch -q "backup/self-update-$stamp" HEAD
    echo "  $ahead lokale(r) Commit(s) gesichert in Branch backup/self-update-$stamp"
  fi
  if [[ -n "$("${g[@]}" status --porcelain --untracked-files=no)" ]]; then
    "${g[@]}" stash push -q -m "clau self-update $stamp" && \
      echo "  Lokale Änderungen gesichert: git -C $repo_dir stash list"
  fi

  "${g[@]}" reset -q --hard "origin/$branch"
  if [[ -n "$conf_bak" ]]; then
    cp -p "$conf_bak" "$repo_dir/.clau.conf"; rm -f "$conf_bak"
  fi
  chmod +x "$script_path"
  echo "clau aktualisiert: $old → $new"
  "${g[@]}" log --oneline "$old..$new" 2>/dev/null | head -15 | sed 's/^/  /'

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

# Erste sinnvolle User-Message (gekürzt) als Wiedererkennungs-Hinweis in der
# Session-Liste -- sonst sind alle Einträge nur eine UUID.
# Ein Scan pro Session-Datei statt mehrerer: Erstellungs-Timestamp (erste
# Zeile), Komprimiert-Herkunft (compactMetadata, siehe cc_compact.py
# write_new_session) und Vorschau (erste echte User-Nachricht, bei
# komprimierten Sessions ohne die Boilerplate-Einleitung). Gibt eine
# TAB-getrennte Zeile aus: created_ts \t is_compact \t orig_id \t orig_count \t preview
_session_meta() {
  local sf="$1"
  python3 - "$sf" <<'PYEOF' 2>/dev/null
import json, sys

sf = sys.argv[1]
try:
    with open(sf) as f:
        lines = f.readlines()
except Exception:
    lines = []

parsed = []
for line in lines:
    try:
        parsed.append(json.loads(line))
    except Exception:
        parsed.append(None)

created = ""
for d in parsed:
    if d and d.get("timestamp"):
        created = d["timestamp"]
        break

is_compact = "0"
orig_id = ""
orig_count = ""
for d in parsed:
    if d and d.get("type") == "system" and d.get("subtype") == "compact":
        meta = d.get("compactMetadata") or {}
        is_compact = "1"
        orig_id = meta.get("originalSessionId", "")
        orig_count = str(meta.get("originalMessageCount", ""))
        break

preview = ""
boilerplate_marker = "\n\n---\n\n"
for d in parsed:
    if not d or d.get("isMeta") or d.get("isSidechain"):
        continue
    msg = d.get("message") or {}
    if msg.get("role") != "user":
        continue
    c = msg.get("content")
    text = ""
    if isinstance(c, str):
        text = c
    elif isinstance(c, list):
        for block in c:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                break
    if is_compact == "1" and boilerplate_marker in text:
        text = text.split(boilerplate_marker, 1)[1]
    text = text.strip().replace("\n", " ").replace("\t", " ")
    if text:
        preview = text[:80]
        break

# \x1f (Unit Separator) statt Tab: bash-`read` behandelt Tab als "IFS
# whitespace" und schluckt aufeinanderfolgende Tabs/leere Felder dabei
# stillschweigend -- mit \x1f (kein Whitespace) bleiben leere Felder erhalten.
print("\x1f".join([created, is_compact, orig_id, orig_count, preview]))
PYEOF
}

# ── Session ↔ Markdown ───────────────────────────────────────────────────────
# Export: liest eine Session-JSONL und schreibt eine lesbare .md-Transkription
# (User/Assistant-Turns, Tool-Calls kompakt). Gibt den Pfad der .md-Datei aus.
_session_export_md() {
  local sf="$1"
  local sid; sid="$(basename "$sf" .jsonl)"
  local proj_dir; proj_dir="$(dirname "$sf")"
  local title; title="$(_get_session_title "$proj_dir" "$sid")"
  local slug="$sid"
  if [[ -n "$title" ]]; then
    slug="$(echo "$title" | tr -cs 'A-Za-z0-9äöüÄÖÜß' '-' | sed 's/^-*//;s/-*$//')"
    [[ -n "$slug" ]] || slug="$sid"
  fi
  local out="./${slug}.md"
  python3 - "$sf" "$sid" "${title:-<ohne Titel>}" "$out" <<'PY'
import json
import sys

sf, sid, title, out = sys.argv[1:5]


def text_from_content(content):
    if isinstance(content, str):
        return content
    out_parts = []
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if t == "text":
                out_parts.append(b.get("text", ""))
            elif t == "tool_use":
                out_parts.append(f"[Tool: {b.get('name','?')}({json.dumps(b.get('input', {}))[:300]})]")
            elif t == "tool_result":
                out_parts.append(f"[Tool-Result: {str(b.get('content',''))[:500]}]")
            elif t == "thinking":
                out_parts.append(f"[Thinking: {str(b.get('thinking',''))[:300]}]")
    return "\n".join(out_parts)


lines = []
try:
    with open(sf) as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("isMeta") or d.get("isSidechain"):
                continue
            msg = d.get("message")
            if not isinstance(msg, dict):
                continue
            role = msg.get("role")
            if role not in ("user", "assistant"):
                continue
            text = text_from_content(msg.get("content")).strip()
            if text:
                lines.append((role, text))
except Exception as e:
    print(f"FEHLER beim Lesen: {e}", file=sys.stderr)
    sys.exit(1)

with open(out, "w") as f:
    f.write(f"# Session: {title}\n\n")
    f.write(f"Session-ID: {sid}\n\n---\n\n")
    for role, text in lines:
        heading = "User" if role == "user" else "Assistant"
        f.write(f"## {heading}\n\n{text}\n\n")

print(out)
PY
}

# Import: nimmt eine beliebige .md-Datei, erzeugt eine neue Session mit ihrem
# Inhalt als erste User-Nachricht (wie eine frisch getippte erste Message --
# kein synthetisches Assistant-Echo wie bei cc_compact.py, Claude antwortet
# beim Fortsetzen ganz normal live darauf). Gibt die neue Session-ID aus.
_session_import_md() {
  local md_file="$1"
  [[ -f "$md_file" ]] || { echo "Datei nicht gefunden: $md_file" >&2; return 1; }
  local proj_dir; proj_dir="$(_claude_projects_dir)/$(_project_hash_for)"
  mkdir -p "$proj_dir"
  python3 - "$md_file" "$proj_dir" "$PWD" <<'PY'
import json
import sys
import uuid
import datetime

md_file, proj_dir, cwd = sys.argv[1:4]

with open(md_file) as f:
    content = f.read()

new_id = str(uuid.uuid4())
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

user_msg = {
    "type": "user",
    "isMeta": False,
    "isVisibleInTranscriptOnly": False,
    "message": {
        "role": "user",
        "content": [{"type": "text", "text": content}],
    },
    "uuid": str(uuid.uuid4()),
    "parentUuid": None,
    "timestamp": now,
    "sessionId": new_id,
    "userType": "external",
    "entrypoint": "sdk-cli",
    "cwd": cwd,
    "version": "2.0",
}

with open(f"{proj_dir}/{new_id}.jsonl", "w") as f:
    f.write(json.dumps(user_msg) + "\n")

print(new_id)
PY
}

# Importiert eine .md-Datei als Session-Start, backend-abhängig:
# - claude: synthetische Session-JSONL (_session_import_md) + normales
#   --resume -- eine echte, fortsetzbare Claude-Code-Session.
# - opencode: Claude-Code-Session-Format ist dort nicht ladbar. Statt eine
#   JSONL zu erzeugen die dann von run_opencode_session() ignoriert würde
#   (genau das ist David passiert -- Import "erfolgreich", aber opencode
#   startete komplett leer), geht der Inhalt direkt als --prompt in den
#   TUI-Start.
run_import_md() {
  local md_file="$1"
  [[ -f "$md_file" ]] || { echo "Datei nicht gefunden: $md_file" >&2; return 1; }
  local mdl; mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if [[ "$(effective_backend)" == "opencode" ]]; then
    _ensure_opencode_runtime || exit 1
    _opencode_sync_config "$mdl"
    local model_arg; model_arg="$(_opencode_model_arg "$mdl")"
    local content; content="$(cat "$md_file")"
    echo "Starte opencode mit $md_file als Startprompt ..."
    cleanup_tool_blocking
    unset_token_saver_env
    exec opencode --model "$model_arg" --prompt "$content"
  fi
  local new_id; new_id="$(_session_import_md "$md_file")"
  if [[ -n "$new_id" ]]; then
    echo "✓ Session aus $md_file erzeugt: $new_id"
    run_resume_id "$new_id"
  else
    echo "✗ Import fehlgeschlagen." >&2
    return 1
  fi
}

# Listet die letzten Sessions im aktuellen Projekt mit Größe/Token-Schätzung
# und Inhalts-Vorschau, lässt eine auswählen, und fragt dann: fortsetzen
# oder komprimieren (auf genau dieser gewählten Datei, nicht "die neueste").
choose_session_interactive() {
  local mdl; mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  local owl_id="" cw=""
  if is_owl_model "$mdl"; then
    owl_id="$(owl_model_id "$mdl")"
    cw="$(owl_context_window "$owl_id")"
  fi

  local proj_dir; proj_dir="$(_claude_projects_dir)/$(_project_hash_for)"
  local files=()
  if [[ -d "$proj_dir" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$proj_dir"/*.jsonl 2>/dev/null | head -20)
  fi
  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "Keine Sessions in diesem Projekt gefunden."
    return 1
  fi

  echo
  echo "Letzte Sessions in diesem Projekt (neueste zuerst, max. 20):"
  local i=1 f tok pct sizeh mtime
  local created is_compact orig_id orig_count preview user_title herkunft
  for f in "${files[@]}"; do
    tok="$(_estimate_session_tokens "$f")"
    tok="${tok:-0}"
    IFS=$'\x1f' read -r created is_compact orig_id orig_count preview < <(_session_meta "$f")
    sizeh="$(du -h "$f" 2>/dev/null | cut -f1)"
    mtime="$(date -r "$f" '+%d.%m. %H:%M' 2>/dev/null)"
    local created_h=""
    [[ -n "$created" ]] && created_h="$(date -d "$created" '+%d.%m. %H:%M' 2>/dev/null)"
    user_title="$(_get_session_title "$proj_dir" "$(basename "$f" .jsonl)")"

    if [[ -n "$cw" && "$cw" -gt 0 && "$tok" -gt 0 ]]; then
      pct=$(( tok * 100 / cw ))
      printf "  %2d) Erstellt %s · Aktiv %s · %s Tok (%s%% v. owl:%s, %s)\n" \
        "$i" "${created_h:-?}" "$mtime" "$tok" "$pct" "$owl_id" "$sizeh"
    else
      printf "  %2d) Erstellt %s · Aktiv %s · %s Tok (%s)\n" \
        "$i" "${created_h:-?}" "$mtime" "$tok" "$sizeh"
    fi

    herkunft=""
    [[ "$is_compact" == "1" ]] && herkunft="⤷ komprimiert aus ${orig_id:0:8}… (${orig_count:-?} Nachr.)"
    if [[ -n "$user_title" || -n "$herkunft" ]]; then
      printf "       %s%s%s\n" \
        "${user_title:+Titel: $user_title  }" \
        "$herkunft" \
        ""
    fi
    printf "       \"%s\"\n" "${preview:-<leer>}"
    ((i++))
  done
  printf "Auswahl [1-%d, Enter=Abbrechen]: " "${#files[@]}"
  local sel; read -r sel
  [[ -n "$sel" && "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le "${#files[@]}" ]] || { echo "Abgebrochen."; return 0; }
  local chosen="${files[$((sel-1))]}"
  local chosen_id; chosen_id="$(basename "$chosen" .jsonl)"

  echo
  echo "Gewählt: $chosen_id"
  echo "  1) Fortsetzen"
  echo "  2) Komprimieren (und danach fortsetzen)"
  echo "  3) Titel setzen"
  echo "  4) Löschen (unwiderruflich!)"
  echo "  5) Als Markdown exportieren"
  echo "  6) Abbrechen"
  printf "Auswahl [1-6, Enter=1]: "
  local action; read -r action
  case "${action:-1}" in
    2)
      if [[ -z "$owl_id" ]]; then
        echo "Komprimieren ist aktuell nur für owlAPI-Modelle verdrahtet (Modell wechseln, z.B. owl:120)." >&2
        return 1
      fi
      echo "Komprimiere $chosen_id (Ziel: owl:$owl_id) ..."
      local new_id
      new_id="$(_compact_session_file "$chosen" "$owl_id")"
      if [[ -n "$new_id" ]]; then
        echo "✓ Komprimiert → neue Session: $new_id"
        run_resume_id "$new_id"
      else
        echo "✗ Komprimieren fehlgeschlagen." >&2
        return 1
      fi
      ;;
    3)
      printf "Neuer Titel für %s: " "$chosen_id"
      local new_title; read -r new_title
      _set_session_title "$proj_dir" "$chosen_id" "$new_title"
      echo "✓ Titel gesetzt."
      choose_session_interactive
      ;;
    4)
      echo "Session $chosen_id WIRD ENDGÜLTIG UND UNWIEDERBRINGLICH GELÖSCHT."
      printf "Tippe 'löschen' zum Bestätigen: "
      local confirm; read -r confirm
      if [[ "$confirm" == "löschen" ]]; then
        rm -f "$chosen"
        _delete_session_title "$proj_dir" "$chosen_id"
        if [[ "${CLAU_SESSION_ID:-}" == "$chosen_id" ]]; then
          CLAU_SESSION_ID=""
          save_config
        fi
        echo "✓ Gelöscht: $chosen_id"
        choose_session_interactive
      else
        echo "Abgebrochen (nichts gelöscht)."
      fi
      ;;
    5)
      local out; out="$(_session_export_md "$chosen")"
      if [[ -n "$out" ]]; then
        echo "✓ Exportiert: $out"
      else
        echo "✗ Export fehlgeschlagen." >&2
      fi
      choose_session_interactive
      ;;
    6) echo "Abgebrochen." ;;
    *) run_resume_id "$chosen_id" ;;
  esac
}

# Globaler Session-Scan: durchsucht ALLE Projekt-Buckets unter
# ~/.claude/projects und listet jede Session mit Projekt-Pfad (aus dem
# "cwd"-Feld der JSONL), mtime, Token-Schätzung, Titel und Vorschau.
# Ein Python-Pass pro Datei (statt N getrennten Aufrufen) — bei vielen
# Sessions bleibt das schnell. Ausgabe: eine Zeile pro Session, Felder mit
# \x1f getrennt, nach mtime absteigend sortiert.
_all_sessions_scan() {
  local proj_root; proj_root="$(_claude_projects_dir)"
  [[ -d "$proj_root" ]] || return 0
  python3 - "$proj_root" <<'PYEOF' 2>/dev/null
import json, os, sys, time

proj_root = sys.argv[1]
SEP = "\x1f"
OVERHEAD_TOKENS = 20000
CHARS_PER_TOKEN = 3.5

def block_chars(b):
    if isinstance(b, dict) and b.get('type') in ('thinking', 'redacted_thinking'):
        return 0
    return len(json.dumps(b, ensure_ascii=False))

def estimate_tokens(rows):
    last_in = last_cr = last_cc = 0
    for d in rows:
        u = (d.get('message') or {}).get('usage') or {}
        if u:
            last_in = u.get('input_tokens', 0) or 0
            last_cr = u.get('cache_read_input_tokens', 0) or 0
            last_cc = u.get('cache_creation_input_tokens', 0) or 0
    total = last_in + last_cr + last_cc
    if total > 0:
        return total
    start = 0
    for i, d in enumerate(rows):
        if d.get('subtype') == 'compact_boundary':
            start = i
    chars = 0
    for d in rows[start:]:
        if d.get('isSidechain') or d.get('type') not in ('user', 'assistant'):
            continue
        content = (d.get('message') or {}).get('content')
        if isinstance(content, str):
            chars += len(content)
        elif isinstance(content, list):
            chars += sum(block_chars(b) for b in content)
    return int(chars / CHARS_PER_TOKEN) + OVERHEAD_TOKENS if chars > 0 else 0

def first_text(msg):
    c = msg.get('content')
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'text':
                return b.get('text', '')
    return ""

def clean(s):
    return s.strip().replace("\n", " ").replace("\t", " ").replace(SEP, " ")

sessions = []
for bucket in os.listdir(proj_root):
    bdir = os.path.join(proj_root, bucket)
    if not os.path.isdir(bdir):
        continue
    titles = {}
    tf = os.path.join(bdir, ".clau-session-titles.json")
    if os.path.isfile(tf):
        try:
            with open(tf) as f:
                titles = json.load(f)
        except Exception:
            titles = {}
    for fn in os.listdir(bdir):
        if not fn.endswith(".jsonl"):
            continue
        path = os.path.join(bdir, fn)
        sid = fn[:-6]
        try:
            mtime = os.path.getmtime(path)
        except Exception:
            continue
        rows = []
        cwd = ""
        try:
            with open(path) as f:
                for line in f:
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    rows.append(d)
                    if not cwd:
                        c = d.get('cwd')
                        if isinstance(c, str) and c:
                            cwd = c
        except Exception:
            continue
        if not cwd:
            # Fallback: Bucket-Namen rückwärts übersetzen (bricht bei
            # Pfadteilen mit Bindestrich, daher nur Notnagel).
            cwd = "/" + bucket.lstrip("-").replace("-", "/")
        preview = ""
        for d in rows:
            if not d or d.get('isMeta') or d.get('isSidechain'):
                continue
            msg = d.get('message') or {}
            if msg.get('role') != 'user':
                continue
            t = clean(first_text(msg))
            if t:
                preview = t[:80]
                break
        sessions.append((mtime, cwd, sid, estimate_tokens(rows), preview, clean(titles.get(sid, ""))))

sessions.sort(key=lambda s: s[0], reverse=True)
for mtime, cwd, sid, tokens, preview, title in sessions:
    mstr = time.strftime("%d.%m.%Y %H:%M", time.localtime(mtime))
    print(SEP.join([mstr, cwd, sid, str(tokens), preview, title]))
PYEOF
}

# Ermittelt die Sessions, die JETZT aktiv laufen (in anderen Terminals oder
# im Hintergrund). Grundlage sind die laufenden claude-Prozesse: deren cwd
# (via /proc/<pid>/cwd) und --resume-Flag. Sessions mit --resume werden über
# die ID gematcht; frisch gestartete (ohne --resume) über das cwd-Feld der
# Session-Datei -- pro cwd nur die neueste (Scan ist mtime-absteigend).
# Gibt dieselbe \x1f-getrennte Zeile wie _all_sessions_scan aus.
_running_sessions() {
  local pids=()
  mapfile -t pids < <(pgrep -x claude 2>/dev/null)
  [[ "${#pids[@]}" -eq 0 ]] && return 0

  local active_sids=() active_cwds=()
  local pid cwd sid
  for pid in "${pids[@]}"; do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
    [[ -n "$cwd" ]] || continue
    # --resume <sid> (oder --resume=<sid>) aus der Kommandozeile.
    # || true: grep liefert Exit 1, wenn kein --resume da ist -- mit
    # set -e + pipefail würde die Zuweisung sonst die Funktion abbrechen.
    local cmdline
    cmdline="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    sid="$(printf '%s\n' "$cmdline" | grep -oP '(?<=^--resume=)\S+' || true)"
    if [[ -z "$sid" ]]; then
      sid="$(printf '%s\n' "$cmdline" | grep -A1 '^--resume$' | tail -1 || true)"
    fi
    if [[ -n "$sid" ]]; then
      active_sids+=("$sid")
    else
      active_cwds+=("$cwd")
    fi
  done
  [[ "${#active_sids[@]}" -eq 0 && "${#active_cwds[@]}" -eq 0 ]] && return 0

  local line mstr cwd_field sid_field hit a e already
  local emitted_cwds=()
  while IFS= read -r line; do
    IFS=$'\x1f' read -r mstr cwd_field sid_field _ <<< "$line"
    hit=0
    for a in "${active_sids[@]}"; do
      if [[ "$sid_field" == "$a" ]]; then
        hit=1
        break
      fi
    done
    if [[ "$hit" -eq 0 && "${#active_cwds[@]}" -gt 0 ]]; then
      for a in "${active_cwds[@]}"; do
        if [[ "$cwd_field" == "$a" ]]; then
          already=0
          for e in "${emitted_cwds[@]}"; do
            if [[ "$e" == "$a" ]]; then
              already=1
              break
            fi
          done
          if [[ "$already" -eq 0 ]]; then
            hit=1
            emitted_cwds+=("$a")
          fi
          break
        fi
      done
    fi
    [[ "$hit" -eq 1 ]] && printf '%s\n' "$line"
  done < <(_all_sessions_scan)
}

# Globaler Session-Picker: listet Sessions aus ALLEN Projekten auf und
# ermöglicht es, eine davon aus der aktuellen Konsole zu erreichen. Claude
# löst --resume <id> gegen den Bucket des aktuellen Arbeitsordners auf,
# daher wird vor dem Fortsetzen in den Projektordner der Session gewechselt
# (und dessen .clau.conf geladen, damit das dort konfigurierte Modell gilt).
choose_all_sessions() {
  local filter="${1:-all}"
  local lines=()
  if [[ "$filter" == "running" ]]; then
    while IFS= read -r l; do lines+=("$l"); done < <(_running_sessions)
  else
    while IFS= read -r l; do lines+=("$l"); done < <(_all_sessions_scan)
  fi
  if [[ "${#lines[@]}" -eq 0 ]]; then
    if [[ "$filter" == "running" ]]; then
      echo "Keine aktuell laufenden Claude-Code-Sessions gefunden."
    else
      echo "Keine Claude-Code-Sessions gefunden."
    fi
    return 0
  fi

  local max=50 shown="${#lines[@]}"
  [[ "$shown" -gt "$max" ]] && shown="$max"

  echo
  if [[ "$filter" == "running" ]]; then
    echo "Aktuell laufende Claude-Code-Sessions (andere Terminals / Hintergrund):"
  else
    echo "Alle Claude-Code-Sessions auf dieser Maschine (neueste zuerst, max. $max):"
  fi
  echo
  local i=1 l mstr cwd sid tokens preview title
  for l in "${lines[@]:0:shown}"; do
    IFS=$'\x1f' read -r mstr cwd sid tokens preview title <<< "$l"
    printf "  %2d) %s  %s\n" "$i" "$mstr" "$cwd"
    printf "       %s… · %s Tok%s\n" "${sid:0:8}" "${tokens:-0}" "${title:+ · Titel: $title}"
    printf "       \"%s\"\n" "${preview:-<leer>}"
    ((i++))
  done
  [[ "${#lines[@]}" -gt "$shown" ]] && echo "  … und $(( ${#lines[@]} - shown )) weitere (ältere)."
  echo
  printf "Auswahl [1-%d, Enter=Abbrechen]: " "$shown"
  local sel; read -r sel
  [[ -n "$sel" && "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le "$shown" ]] || { echo "Abgebrochen."; return 0; }

  local chosen="${lines[$((sel-1))]}"
  IFS=$'\x1f' read -r mstr cwd sid tokens preview title <<< "$chosen"

  if [[ -d "$cwd" ]]; then
    echo
    echo "Wechsle nach $cwd und setze Session ${sid:0:8}… fort ..."
    (
      cd "$cwd" || exit 1
      if [[ -f ".clau.conf" ]]; then
        # shellcheck disable=SC1090
        source "./.clau.conf"
      fi
      run_resume_id "$sid"
    )
  else
    echo "Projektordner nicht gefunden: $cwd" >&2
    echo "Setze die Session im aktuellen Ordner fort (kann fehlschlagen)." >&2
    run_resume_id "$sid"
  fi
}

run_resume_picker() {
  local mdl
  mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if [[ "$(effective_backend)" == "qwenplan" ]]; then
    run_qwenplan_session --resume
    return
  fi
  if [[ "$(effective_backend)" == "opencode" ]]; then
    # opencode hat seinen eigenen /sessions-Picker in der TUI -- kein von
    # außen scriptbares Äquivalent zu Claudes --resume ohne ID.
    run_opencode_session
    return
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
  if [[ "$(effective_backend)" == "qwenplan" ]]; then
    run_qwenplan_session --resume "$CLAU_SESSION_ID"
    return
  fi
  if [[ "$(effective_backend)" == "opencode" ]]; then
    # CLAU_SESSION_ID ist ein Claude-Code-Session-Format, überträgt sich
    # nicht auf opencode -- dessen eigene TUI übernimmt die Fortsetzung.
    run_opencode_session
    return
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
  if [[ "$(effective_backend)" == "qwenplan" ]]; then
    run_qwenplan_session
    return
  fi
  if [[ "$(effective_backend)" == "opencode" ]]; then
    run_opencode_session
    return
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
  local api_args=()
  while IFS= read -r line; do api_args+=("$line"); done < <(_api_claude_args interactive)
  _api_prompt_args
  # shellcheck disable=SC2086
  exec claude --model "$(claude_cli_model "$mdl")" $extra "${api_args[@]}" "${API_PROMPT_ARGS[@]}"
}

# Setzt eine konkrete Session-ID fort (z.B. nach custom-compact)
run_resume_id() {
  local rid="$1"
  local mdl; mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
  fi
  if [[ "$(effective_backend)" == "qwenplan" ]]; then
    run_qwenplan_session --resume "$rid"
    return
  fi
  if [[ "$(effective_backend)" == "opencode" ]]; then
    # $rid ist eine Claude-Code-Session-ID (aus cc_compact.py) -- opencode
    # hat kein passendes Gegenstück dazu (Phase 2: Kompressions-Brücke).
    echo "Hinweis: Session-ID $rid ist Claude-Code-Format, nicht auf opencode übertragbar." >&2
    run_opencode_session
    return
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
  local api_args=()
  while IFS= read -r line; do api_args+=("$line"); done < <(_api_claude_args interactive)
  _api_prompt_args
  # shellcheck disable=SC2086
  exec claude --resume "$rid" --model "$(claude_cli_model "$mdl")" $extra "${api_args[@]}" "${API_PROMPT_ARGS[@]}"
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
  _owl_activity_env "compact"
  OWL_HDR_AGENT_TOOL="$OWL_HDR_AGENT_TOOL" OWL_HDR_REQUEST_CONTEXT="$OWL_HDR_REQUEST_CONTEXT" \
  OWL_HDR_PROJECT="$OWL_HDR_PROJECT" OWL_HDR_USER="$OWL_HDR_USER" \
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
  [[ "$(effective_backend)" == "qwenplan" ]] && _qwenplan_refuse_headless
  if [[ "$(effective_backend)" == "opencode" ]]; then
    _ensure_opencode_runtime || exit 1
    build_opencode_headless_cmd
    echo "Starte opencode headless im Verzeichnis: $(pwd)"
    exec "${OPENCODE_CMD[@]}"
  fi
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
  [[ "$(effective_backend)" == "qwenplan" ]] && _qwenplan_refuse_headless
  if [[ "$(effective_backend)" == "opencode" ]]; then
    _ensure_opencode_runtime || exit 1
    echo "Projektverzeichnis bereit für opencode headless: $dir"
    (
      cd "$dir"
      build_opencode_headless_cmd
      echo "Starte opencode headless in: $dir"
      exec "${OPENCODE_CMD[@]}"
    )
    return
  fi
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
        echo "  3) opus    Opus 5.5    stärker, teurer"
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

choose_tg_brain() {
  _tg_load
  echo
  echo "Concierge-Modell (das 'Hirn' des Bots, läuft über QuiteQue):"
  echo "  aktuell: ${CLAU_TG_BRAIN_MODEL}  (${CLAU_TG_BRAIN:-1} = 1:an / 0:aus)"
  echo "  1) gemma-12b-chat    lokal, DE-optimiert, schnell   [Standard]"
  echo "  2) owl:free          Router, gratis"
  echo "  3) claude-opus-5-5   stark, aber teuer fürs Plaudern"
  echo "  4) eigene Modell-ID eingeben"
  echo "  5) Concierge AUS (jede Nachricht geht direkt an Claude)"
  echo "  6) Zurück"
  printf "Auswahl [1-6, Enter=6]: "
  read -r b
  case "${b:-6}" in
    1) _tg_conf_set CLAU_TG_BRAIN_MODEL "gemma-12b-chat"; _tg_conf_set CLAU_TG_BRAIN "1"; echo "✅ gemma-12b-chat" ;;
    2) _tg_conf_set CLAU_TG_BRAIN_MODEL "free";           _tg_conf_set CLAU_TG_BRAIN "1"; echo "✅ free (Router)" ;;
    3) _tg_conf_set CLAU_TG_BRAIN_MODEL "claude-opus-5-5"; _tg_conf_set CLAU_TG_BRAIN "1"; echo "✅ claude-opus-5-5" ;;
    4) printf "Modell-ID (wie auf QuiteQue): "; read -r mid
       [[ -n "$mid" ]] && { _tg_conf_set CLAU_TG_BRAIN_MODEL "$mid"; _tg_conf_set CLAU_TG_BRAIN "1"; echo "✅ $mid"; } ;;
    5) _tg_conf_set CLAU_TG_BRAIN "0"; echo "Concierge AUS." ;;
    6) return ;;
    *) echo "Ungültige Auswahl." ;;
  esac
}

choose_telegram_interactive() {
  while true; do
    _tg_load
    local st="AUS / unvollständig"
    _tg_ready && st="AN (Gruppe ${CLAU_TG_GROUP_ID})"
    echo
    echo "Telegram / Handy   [Status: $st]"
    echo "  1) Bot-Token eingeben (einfach reinpasten)"
    echo "  2) Gruppe verbinden (Gruppen-ID ermitteln)"
    echo "  3) Meine User-ID anzeigen & Allowlist setzen"
    echo "  4) Testnachricht senden"
    echo "  5) Bot starten – vom Handy entwickeln (Vordergrund, Strg-C beendet)"
    echo "  6) LIVE-Session starten (Bildschirm + Telegram parallel, tmux)"
    echo "  7) Concierge-Modell  [${CLAU_TG_BRAIN_MODEL:-gemma-12b-chat}, $([[ "${CLAU_TG_BRAIN:-1}" == "1" ]] && echo AN || echo AUS)]"
    echo "  8) Zurück"
    printf "Auswahl [1-8, Enter=8]: "
    read -r c
    # Unterfunktionen in Subshell: ihr evtl. 'exit' beendet nur die Subshell, nicht clau
    case "${c:-6}" in
      1) ( tg_token )  || true ;;
      2) ( tg_setup )  || true ;;
      3) ( tg_whoami ) || true ;;
      4) ( tg_test )   || true ;;
      5) ( tg_bot )    || true ;;
      6) tg_mirror ;;
      7) ( choose_tg_brain ) || true ;;
      8) return ;;
      *) echo "Ungültige Auswahl." ;;
    esac
  done
}

interactive_start() {
  ensure_model

  local mdl; mdl="$(effective_model)"
  local tag
  if [[ "$(effective_backend)" == "qwenplan" ]]; then
    tag="Qwen:${CLAU_QWEN_MODEL}"
  elif is_owl_model "$mdl"; then
    tag="LiteLLM:$(owl_model_id "$mdl")"
  else
    tag="Claude:$mdl"
  fi

  echo
  echo "clau — $(basename "$(pwd)")  [$tag, Engine: $(effective_backend)]"
  [[ -n "${CLAU_SESSION_NAME:-}" ]] && echo "  Session: ${CLAU_SESSION_NAME}"
  echo "  1) Session auswählen (fortsetzen oder komprimieren)"
  echo "  2) Neue Session beginnen        [Enter]"
  echo "  3) Modell wechseln"
  echo "  4) Bot-Einstellungen"
  echo "  5) Session komprimieren (custom-compact via QuiteQue)"
  echo "  6) Telegram / Handy"
  echo "  7) Update von GitHub (self-update)"
  echo "  8) CLI-Engine wechseln (Claude Code / opencode / Qwen Token Plan)"
  echo "  9) Markdown importieren (neue Session aus Datei)"
  echo "  10) Alle Sessions (alle Projekte auf dieser Maschine)"
  echo "  11) Laufende Sessions (jetzt aktive, andere Terminals/Hintergrund)"
  echo "  12) Team-Modus / Fernsteuerung  [Team: $(team_active && echo AN || echo aus), API: $([[ "${CLAU_API:-0}" == "1" ]] && echo AN || echo aus)]"
  printf "Auswahl [1-12, Enter=2]: "
  read -r start_choice

  case "${start_choice:-2}" in
    1) choose_session_interactive; interactive_start ;;
    2) run_new_session_named ;;
    3) choose_model_interactive; interactive_start ;;
    4) choose_bot_settings; interactive_start ;;
    5) run_compact ;;
    6) choose_telegram_interactive; interactive_start ;;
    7)
      self_update
      echo
      echo "Bitte 'clau' erneut starten, um die neue Version zu nutzen."
      exit 0
      ;;
    8) choose_backend_interactive; interactive_start ;;
    9)
      local md_files=()
      while IFS= read -r f; do md_files+=("$f"); done < <(ls -1 ./*.md 2>/dev/null)
      local md_path=""
      if [[ "${#md_files[@]}" -gt 0 ]]; then
        echo
        echo ".md-Dateien in diesem Verzeichnis:"
        local mi=1 mf
        for mf in "${md_files[@]}"; do
          printf "  %2d) %s\n" "$mi" "$mf"
          ((mi++))
        done
        printf "Auswahl [1-%d] oder eigener Pfad, Enter=Abbrechen: " "${#md_files[@]}"
        local md_choice; read -r md_choice
        if [[ "$md_choice" =~ ^[0-9]+$ && "$md_choice" -ge 1 && "$md_choice" -le "${#md_files[@]}" ]]; then
          md_path="${md_files[$((md_choice-1))]}"
        else
          md_path="$md_choice"
        fi
      else
        printf "Pfad zur .md-Datei: "
        read -r md_path
      fi
      if [[ -z "$md_path" || ! -f "$md_path" ]]; then
        echo "Datei nicht gefunden: $md_path" >&2
        interactive_start
        return
      fi
      run_import_md "$md_path" || interactive_start
      ;;
    10) choose_all_sessions ;;
    11) choose_all_sessions running ;;
    12) choose_team_settings; interactive_start ;;
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
      --backend)
        if [[ -z "${2:-}" || ( "$2" != "claude" && "$2" != "opencode" && "$2" != "qwenplan" ) ]]; then
          echo "--backend erwartet: claude|opencode|qwenplan" >&2
          exit 1
        fi
        CLI_BACKEND_OVERRIDE="$2"
        shift 2
        ;;
      --qwen-model)
        if [[ -z "${2:-}" || "$2" == -* ]]; then
          choose_qwen_model_interactive
          exit 0
        fi
        CLAU_QWEN_MODEL="$2"
        save_config
        echo "Qwen-Modell gesetzt auf: $CLAU_QWEN_MODEL"
        exit 0
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
      --import-md)
        if [[ -z "${2:-}" ]]; then
          echo "--import-md erwartet einen Dateipfad" >&2
          exit 1
        fi
        ACTION="import-md"
        IMPORT_MD_FILE="$2"
        shift 2
        ;;
      --all-sessions)
        ACTION="all-sessions"
        shift
        ;;
      --running-sessions)
        ACTION="running-sessions"
        shift
        ;;
      --tg-token)
        ACTION="tg-token"
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
      --mirror)
        ACTION="mirror"
        shift
        ;;
      --api)
        ACTION="api"
        shift
        ;;
      --api-stop)
        ACTION="api-stop"
        shift
        ;;
      --tg-pump)
        ACTION="tg-pump"
        TG_PUMP_ARGS=("${2:-}" "${3:-}" "${4:-}")
        shift 4 || shift $#
        ;;
      --tg-hooks-off)
        ACTION="tg-hooks-off"
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
TG_PUMP_ARGS=("" "" "")

load_config
parse_args "$@"

if [[ "${ACTION}" == "tg-pump" ]]; then
  tg_pump "${TG_PUMP_ARGS[0]}" "${TG_PUMP_ARGS[1]}" "${TG_PUMP_ARGS[2]}"
  exit 0
fi

# Telegram-Hook: sofort abarbeiten (kein Update-Check, kein Menü) — muss schnell sein
if [[ "${ACTION}" == "tg-hook" ]]; then
  tg_hook
  exit 0
fi

# Update-Check nur für interaktive Läufe (nicht headless/CI/tg)
case "${ACTION}" in
  tg-token|tg-setup|tg-test|tg-whoami|tg-bot|tg-hooks-off|mirror|tg-pump|api|api-stop) : ;;
  *) [[ "${HEADLESS:-0}" -eq 1 ]] || check_for_updates ;;
esac

# Fernsteuerung im Hintergrund (nur mit CLAU_API=1, nicht für Hilfsaufrufe)
case "${ACTION}" in
  tg-*|mirror|api|api-stop) : ;;
  *) [[ "${HEADLESS:-0}" -eq 1 ]] || api_daemon_ensure ;;
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
  import-md)
    run_import_md "$IMPORT_MD_FILE" || exit 1
    ;;
  all-sessions)
    choose_all_sessions
    ;;
  running-sessions)
    choose_all_sessions running
    ;;
  tg-token)
    tg_token
    ;;
  tg-setup)
    tg_setup
    ;;
  tg-test)
    tg_test
    ;;
  tg-hooks-off)
    tg_hooks_off
    ;;
  mirror)
    tg_mirror
    ;;
  api)
    run_api_server
    ;;
  api-stop)
    api_daemon_stop
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
