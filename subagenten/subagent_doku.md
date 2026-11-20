# Subagent: Dokumentation nachziehen

## Ziel
`README.md`, `QUITEQUE_HINT.md` und die Hilfetexte (`clau --help`, Qode `/help`) stimmen mit dem Code überein.

## Vorgehen
1. `git log --oneline` seit dem letzten Doku-Stand lesen und die Diffs der Funktions-Commits ansehen.
2. Jede Änderung, die ein Nutzer bemerkt, prüfen: Session-Browser (`m`, Filter, `0`), Harness-Spalte, Release/Revision,
   `--pick-model`, `/model`, `/compress`, Cache-Anzeige, `forge on/off`, Pfeiltasten-History, `cc-<ID>.json`-Sicherung.
3. Fehlendes ergänzen, Veraltetes ändern oder streichen. Nichts beschreiben, was der Code nicht tut: im Zweifel Code lesen oder ausführen.

## Regeln
- Deutsch, knapp, mit Beispielen aus echten Befehlen. Kein Marketing.
- Hilfetexte im Code nur ändern, wenn sie falsch sind; dann auch die `locales/*.json` melden (→ `subagent_uebersetzung.md`).

## Abgabe
Liste der geänderten Dateien mit je einem Satz. Nicht committen.
