#!/usr/bin/env bash
# Interaktiver Wrapper für Claude Code pro Projektordner
# Speichert Modell + optionale feste Session-ID in .clau.conf

set -euo pipefail

CONFIG_FILE=".clau.conf"

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  : "${CLAU_MODEL:=}"
  : "${CLAU_SESSION_ID:=}"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF2
CLAU_MODEL="${CLAU_MODEL}"
CLAU_SESSION_ID="${CLAU_SESSION_ID}"
EOF2
}

print_help() {
  cat <<'EOT'
clau.sh - Interaktiver Wrapper für Claude Code mit per-Ordner-Config

Verwendung:
  clau.sh                 Interaktiver Start: Session/Modell auswählen
  clau.sh --list          Öffnet den Claude-Resume-Picker
  clau.sh --new           Startet eine neue Session
  clau.sh --help          Zeigt diese Hilfe
  clau.sh --model N       Setzt das Standardmodell (1=haiku, 2=sonnet, 3=opus)
  clau.sh --take ID       Merkt sich eine feste Session-ID für dieses Verzeichnis
  clau.sh --forget        Entfernt die gemerkte Session-ID
  clau.sh --current       Zeigt aktuelle Session/Model-Config
  clau.sh --clear-model   Entfernt das gespeicherte Modell

Hinweise:
  - Wenn kein Modell gesetzt ist, fragt clau.sh beim Start nach einem Modell.
  - Wenn keine feste Session-ID gesetzt ist, öffnet clau.sh beim Start den Resume-Picker.
  - Mit --take ID kannst du eine bestimmte Session dauerhaft für den Ordner merken.

Model-Mappings:
  1 = haiku
  2 = sonnet
  3 = opus
EOT
}

model_from_number() {
  case "${1:-}" in
    1) CLAU_MODEL="haiku" ;;
    2) CLAU_MODEL="sonnet" ;;
    3) CLAU_MODEL="opus" ;;
    *)
      echo "Unbekanntes Modell-Kürzel: $1 (erlaubt: 1=haiku, 2=sonnet, 3=opus)" >&2
      exit 1
      ;;
  esac
}

show_current() {
  echo "Aktuelles Verzeichnis: $(pwd)"
  echo "Konfiguriertes Modell : ${CLAU_MODEL:-<nicht gesetzt>}"
  echo "Feste Session-ID      : ${CLAU_SESSION_ID:-<keine>}"
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
  if [[ -z "${CLAU_MODEL:-}" ]]; then
    choose_model_interactive
  fi
}

ask_yes_no() {
  local prompt="${1:-Weiter?}"
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

run_resume_picker() {
  echo "Öffne Session-Auswahl für dieses Verzeichnis mit Modell $CLAU_MODEL ..."
  exec claude --resume --model "$CLAU_MODEL"
}

run_saved_session() {
  echo "Starte feste Session $CLAU_SESSION_ID mit Modell $CLAU_MODEL ..."
  exec claude --resume "$CLAU_SESSION_ID" --model "$CLAU_MODEL"
}

run_new_session() {
  echo "Starte neue Session mit Modell $CLAU_MODEL ..."
  exec claude --model "$CLAU_MODEL"
}

interactive_start() {
  ensure_model

  echo
  echo "Startoptionen für $(pwd):"
  echo "  1) Verfügbare Sessions auswählen"
  echo "  2) Neue Session starten"
  if [[ -n "${CLAU_SESSION_ID:-}" ]]; then
    echo "  3) Feste gespeicherte Session starten ($CLAU_SESSION_ID)"
    echo "  4) Modell für diesen Start ändern (aktuell: $CLAU_MODEL)"
    printf "Auswahl [1-4, Enter=1]: "
  else
    echo "  3) Modell für diesen Start ändern (aktuell: $CLAU_MODEL)"
    printf "Auswahl [1-3, Enter=1]: "
  fi

  read -r start_choice

  if [[ -n "${CLAU_SESSION_ID:-}" ]]; then
    case "${start_choice:-1}" in
      1) run_resume_picker ;;
      2) run_new_session ;;
      3) run_saved_session ;;
      4)
        choose_model_interactive
        interactive_start
        ;;
      *)
        echo "Ungültige Auswahl."
        exit 1
        ;;
    esac
  else
    case "${start_choice:-1}" in
      1) run_resume_picker ;;
      2) run_new_session ;;
      3)
        choose_model_interactive
        interactive_start
        ;;
      *)
        echo "Ungültige Auswahl."
        exit 1
        ;;
    esac
  fi
}

load_config

case "${1:-}" in
  --help|-h)
    print_help
    exit 0
    ;;

  --model)
    if [[ -z "${2:-}" ]]; then
      echo "--model erwartet eine Zahl (1=haiku, 2=sonnet, 3=opus)" >&2
      exit 1
    fi
    model_from_number "$2"
    save_config
    echo "Standardmodell für dieses Verzeichnis gesetzt auf: $CLAU_MODEL"
    exit 0
    ;;

  --take)
    if [[ -z "${2:-}" ]]; then
      echo "--take erwartet eine Session-ID" >&2
      exit 1
    fi
    CLAU_SESSION_ID="$2"
    save_config
    echo "Feste Session-ID für dieses Verzeichnis gesetzt auf: $CLAU_SESSION_ID"
    exit 0
    ;;

  --forget)
    CLAU_SESSION_ID=""
    save_config
    echo "Feste Session-ID für dieses Verzeichnis entfernt."
    exit 0
    ;;

  --clear-model)
    CLAU_MODEL=""
    save_config
    echo "Gespeichertes Modell entfernt. Beim nächsten Start wird gefragt."
    exit 0
    ;;

  --current)
    show_current
    exit 0
    ;;

  --list)
    ensure_model
    run_resume_picker
    ;;

  --new)
    ensure_model
    run_new_session
    ;;

  "")
    interactive_start
    ;;

  *)
    echo "Unbekannte Option: $1" >&2
    echo
    print_help
    exit 1
    ;;
esac
