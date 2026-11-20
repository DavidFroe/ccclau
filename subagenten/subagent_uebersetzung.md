# Subagent: Übersetzung

## Ziel
Alle UI-Texte von clau und Qode liegen in `locales/<lang>.json` (Schlüssel `clau.*` für die Shell, `nano.*` für Qode).
Deutsch (`de.json`) und Englisch (`en.json`) sind die Quelle; die übrigen 14 Sprachen
(es fr pt it nl pl tr ru uk ja ko zh ar hi) müssen denselben Stand haben.

## Vorgehen
1. Fehlendes finden:
   - Texte, die noch hart im Code stehen (`clau.sh`, `vendor/nano/nano_claude_code/*.py`, `owl_proxy.py`): jede deutsche
     Benutzer-Ausgabe, die nicht über `t "…"` (Shell) bzw. `_("…")` (Python) läuft. Neu seit `d307cac`:
     Kopfzeile „Release · Revision“, Session-Browser (`choose_sessions_browser`, `_session_table`: Spalten, Filter,
     `0` = Hauptmenü, Gruppen), `/model`, `/compress`, Cache-Anzeige und `forge on/off` in `screen.py`.
   - Schlüssel, deren Text sich geändert hat, z. B. `clau.menu.main.more_sessions` (nur de/en sind aktuell).
2. Neue Schlüssel in `de.json` und `en.json` anlegen (Schlüsselnamen nach dem Muster der vorhandenen), Code auf `t`/`_` umstellen.
3. In alle anderen 14 `*.json` übersetzen.
4. `python3 tools/i18n_build.py` ausführen (erzeugt `locales/<lang>.sh`), dann `python3 tools/i18n_check.py`.

## Regeln
- Platzhalter (`%s`, `%d`) in gleicher Anzahl und Reihenfolge wie die Quelle; Escape-Folgen und Zeilenumbrüche unverändert.
- Kurz halten: Menüzeilen stehen in einem Terminal, Spaltenüberschriften haben feste Breite.
- Kürzel, Tastenbelegung und Befehlsnamen (`m`, `n`, `p`, `/model`, `clau`, `Qode`, `tmux`) nicht übersetzen.
- Arabisch: Zeilen nicht umdrehen, nur den Text übersetzen.
- Keine Texte erfinden, die es im Programm nicht gibt. Unsicher → in der Abgabe nachfragen, nicht raten.

## Abgabe
Nicht committen. Kurz berichten: neue/geänderte Schlüssel (Anzahl + Liste), geänderte Dateien, Ausgabe von
`i18n_check.py` (muss ohne Fehler laufen), und was ausdrücklich NICHT erledigt wurde.
