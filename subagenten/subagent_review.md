# Subagent: Review

## Ziel
Unabhängige Durchsicht der letzten Commits (Standard: `git diff <basis>..HEAD`, Basis vom Auftraggeber genannt) auf Fehler.

## Prüfen
- Shell (`clau.sh`): `set -e`/`pipefail`-Fallen (SIGPIPE bei `| head`), unquotierte Variablen, Pfade mit Leerzeichen, tmux-Namen.
- Python: Ausnahmen, die stillschweigend geschluckt werden und Daten verlieren (Sessions, Verlauf), Threads/Locks in `screen.py`.
- Datenverlust: Überschreiben von Sessiondateien (`autosave_latest.json`, `cc-<ID>.json`), Meta-Dateien.
- Sicherheit: Steuerport/Token des Proxys, Shell-Injection über Session-Namen oder Verzeichnisse.
- Kompatibilität: Änderungen am Proxy dürfen Claude Code nicht stören (zusätzliche Felder nur als Zusatzfelder).

## Abgabe
Nur bestätigte Befunde: Datei:Zeile · Fehlerszenario (konkrete Eingabe → falsches Ergebnis) · Vorschlag. Nichts ändern, nicht committen.
