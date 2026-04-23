#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=".clau.conf"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_NAME="clau"

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
  : "${CLAU_MODEL:=}"
  : "${CLAU_SESSION_ID:=}"
  : "${CLAU_INTERACTION_LEVEL:=2}"
  INTERACTION_LEVEL="$CLAU_INTERACTION_LEVEL"
}

save_config() {
  cat > "$CONFIG_FILE" <<CONF_EOF
CLAU_MODEL="${CLAU_MODEL}"
CLAU_SESSION_ID="${CLAU_SESSION_ID}"
CLAU_INTERACTION_LEVEL="${CLAU_INTERACTION_LEVEL}"
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
  1 = haiku   2 = sonnet   3 = opus
HELP_EOF
}

model_from_number() {
  case "${1:-}" in
    1) CLAU_MODEL="haiku" ;;
    2) CLAU_MODEL="sonnet" ;;
    3) CLAU_MODEL="opus" ;;
    *)
      echo "Unbekanntes Modell-Kürzel: $1 (erlaubt: 1=haiku,2=sonnet,3=opus)" >&2
      exit 1
      ;;
  esac
}

normalize_model_name() {
  case "${1:-}" in
    haiku|sonnet|opus)
      CLI_MODEL_OVERRIDE="$1"
      ;;
    *)
      echo "Ungültiges Modell: $1 (erlaubt: haiku, sonnet, opus)" >&2
      exit 1
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
  echo "Aktuelles Verzeichnis : $(pwd)"
  echo "Konfiguriertes Modell : ${CLAU_MODEL:-<nicht gesetzt>}"
  echo "Feste Session-ID      : ${CLAU_SESSION_ID:-<keine>}"
  echo "Autonomie-Level       : $(interaction_label)"
}

choose_model_interactive() {
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
      *) echo "Ungültige Auswahl. Bitte 1, 2 oder 3 eingeben." ;;
    esac
  done

  save_config
  echo "Modell für dieses Verzeichnis gesetzt auf: $CLAU_MODEL"
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
  # --dangerously-skip-permissions ist von Claude CLI als root verboten
  if [[ "${INTERACTION_LEVEL:-2}" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    echo "--dangerously-skip-permissions"
  fi
}

run_resume_picker() {
  local mdl
  mdl="$(effective_model)"
  if [[ -z "$mdl" ]]; then
    ensure_model
    mdl="$(effective_model)"
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
  build_headless_cmd
  echo "Starte headless im Verzeichnis: $(pwd)"
  exec "${CLAUDE_CMD[@]}"
}

run_headless_in_dir() {
  local dir="$1"
  mkdir -p "$dir"
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

  local mdl
  mdl="$(effective_model)"

  echo
  echo "Startoptionen für $(pwd):"
  echo "  1) Verfügbare Sessions auswählen"
  echo "  2) Neue Session starten"
  if [[ -n "${CLAU_SESSION_ID:-}" ]]; then
    echo "  3) Feste gespeicherte Session starten ($CLAU_SESSION_ID)"
    echo "  4) Modell ändern (aktuell: $mdl)"
    echo "  5) Autonomie-Level ändern (aktuell: $(interaction_label))"
    printf "Auswahl [1-5, Enter=1]: "
  else
    echo "  3) Modell ändern (aktuell: $mdl)"
    echo "  4) Autonomie-Level ändern (aktuell: $(interaction_label))"
    printf "Auswahl [1-4, Enter=1]: "
  fi

  read -r start_choice

  if [[ -n "${CLAU_SESSION_ID:-}" ]]; then
    case "${start_choice:-1}" in
      1) run_resume_picker ;;
      2) run_new_session ;;
      3) run_saved_session ;;
      4) choose_model_interactive; interactive_start ;;
      5) choose_interaction_interactive; interactive_start ;;
      *) echo "Ungültige Auswahl."; exit 1 ;;
    esac
  else
    case "${start_choice:-1}" in
      1) run_resume_picker ;;
      2) run_new_session ;;
      3) choose_model_interactive; interactive_start ;;
      4) choose_interaction_interactive; interactive_start ;;
      *) echo "Ungültige Auswahl."; exit 1 ;;
    esac
  fi
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
