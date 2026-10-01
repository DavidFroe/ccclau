#!/usr/bin/env bash
#
# Einzeiler-Installation von clau auf einem frischen System:
#
#   curl -fsSL https://raw.githubusercontent.com/DavidFroe/ccclau/main/install.sh | bash
#
# Kloniert das Repo (falls nicht vorhanden) und ruft `clau --install` auf,
# das Symlink + Abhängigkeiten (claude-code, opencode, tmux) einrichtet.
# Idempotent: vorhandene Kopien/Tools werden nicht überschrieben.
set -euo pipefail

REPO_URL="${CLAU_REPO_URL:-https://github.com/DavidFroe/ccclau.git}"
TARGET_DIR="${CLAU_TARGET_DIR:-$HOME/ccclau}"

echo "==> Installiere clau nach: $TARGET_DIR"

if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "==> Repo vorhanden — aktualisiere (git pull) ..."
  git -C "$TARGET_DIR" pull --ff-only
elif [[ -e "$TARGET_DIR" ]]; then
  echo "Fehler: $TARGET_DIR existiert, ist aber kein Git-Repo." >&2
  echo "        Setz CLAU_TARGET_DIR auf einen anderen Pfad oder räume den Ordner auf." >&2
  exit 1
else
  echo "==> Kloniere Repo ..."
  git clone "$REPO_URL" "$TARGET_DIR"
fi

echo
echo "==> Führe clau --install aus (Symlink + Abhängigkeiten) ..."
bash "$TARGET_DIR/clau.sh" --install

echo
echo "==> Fertig. 'clau' ist einsatzbereit (ggf. Shell neu starten wegen PATH)."
