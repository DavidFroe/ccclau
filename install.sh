#!/usr/bin/env bash
#
# Einzeiler-Installation von clau auf einem frischen System:
#
#   curl -fsSL https://raw.githubusercontent.com/DavidFroe/ccclau/main/install.sh | bash
#
# Kloniert das Repo (falls nicht vorhanden) und ruft `clau --install` auf,
# das Symlink + Abhängigkeiten (claude-code, opencode, tmux) einrichtet.
# Ist clau schon installiert, wird dessen Ordner (Ziel des clau-Symlinks)
# auf den GitHub-Stand gebracht -- auch bei lokalen Änderungen (gesichert in
# git stash bzw. Branch backup/self-update-*, .clau.conf bleibt erhalten).
set -euo pipefail

REPO_URL="${CLAU_REPO_URL:-https://github.com/DavidFroe/ccclau.git}"
if [[ -n "${CLAU_TARGET_DIR:-}" ]]; then
  TARGET_DIR="$CLAU_TARGET_DIR"
elif [[ -L "$HOME/.local/bin/clau" ]]; then
  TARGET_DIR="$(dirname "$(readlink -f "$HOME/.local/bin/clau")")"
else
  TARGET_DIR="$HOME/ccclau"
fi

echo "==> Installiere clau nach: $TARGET_DIR"

if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "==> Repo vorhanden — bringe es auf den GitHub-Stand ..."
  G=(git -C "$TARGET_DIR")
  BRANCH="$("${G[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  [[ "$BRANCH" == "HEAD" ]] && BRANCH=main
  "${G[@]}" fetch -q origin "$BRANCH"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  CONF_BAK=""
  [[ -f "$TARGET_DIR/.clau.conf" ]] && { CONF_BAK="$(mktemp)"; cp -p "$TARGET_DIR/.clau.conf" "$CONF_BAK"; }
  if [[ "$("${G[@]}" rev-list --count "origin/$BRANCH..HEAD")" -gt 0 ]]; then
    "${G[@]}" branch -q "backup/self-update-$STAMP" HEAD
    echo "    lokale Commits gesichert in Branch backup/self-update-$STAMP"
  fi
  if [[ -n "$("${G[@]}" status --porcelain --untracked-files=no)" ]]; then
    "${G[@]}" stash push -q -m "clau install $STAMP" && echo "    lokale Änderungen gesichert (git stash list)"
  fi
  "${G[@]}" reset -q --hard "origin/$BRANCH"
  [[ -n "$CONF_BAK" ]] && { cp -p "$CONF_BAK" "$TARGET_DIR/.clau.conf"; rm -f "$CONF_BAK"; }
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
