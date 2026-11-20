# Subagent: TUI / Oberfläche und Test-Oberfläche

## Ziel
Die Terminal-Oberfläche (Qode: `vendor/nano/nano_claude_code/screen.py`, `ui.py`; clau-Menüs und Session-Browser in `clau.sh`)
und die grafische Oberfläche (`clau_gui.py`, tkinter) prüfen und verbessern, und eine wiederholbare Test-Oberfläche bereitstellen.

## Aufgaben
1. **Darstellung prüfen** in festen Größen (80x24, 100x30, 200x50) und mit Umlauten/CJK/Arabisch: Umbrüche, abgeschnittene
   Statusleiste (`draw_status`), Kopfzeile (Modell, `forge on/off`), Cache-Anzeige (grün = Cache, rot = neu), Tabellen im Browser.
2. **Test-Oberfläche:** ein Skript `tools/tui_test.py`, das Qode bzw. den Browser in einem Pseudo-Terminal (`pty` oder
   `tmux new -d -x W -y H` + `tmux send-keys` / `capture-pane -p`) startet, Tasten sendet (↑ ↓ Enter, `m`, `n`, `p`, `0`)
   und den Bildschirm als Text zurückgibt. Ziel: Regressionstests ohne Handarbeit, Mock-Backend statt QuiteQue.
3. **GUI:** `python3 clau_gui.py --no-launch` startet ohne Fehler; Session-Liste zeigt dieselben Spalten/Filter (Harness) wie der Browser.

## Regeln
- Qode läuft mit `~/.local/share/clau/nano-venv/bin/python`.
- tmux nur in eigener Test-Sitzung (`tmux -L tuitest …`), danach `kill-server` für diesen Socket.
- Echte Sessions/Verlauf (`~/.nano_claude`, `~/.claude`) nicht verändern: `HOME` auf ein Temp-Verzeichnis setzen.
- Terminal-Escape-Folgen nicht vereinfachen, die `screen.py` für tmux braucht (z. B. `ESC O A/B`, Synchronized Output).

## Abgabe
Befunde mit Größe/Tastenfolge/Bildschirmausschnitt, geänderte/neue Dateien, wie man `tools/tui_test.py` aufruft. Nicht committen.
