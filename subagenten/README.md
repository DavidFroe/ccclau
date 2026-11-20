# Subagenten-Anweisungen

Je eine Datei pro Fleißarbeit. Aufruf: dem Subagenten sagen „Lies `subagenten/<datei>.md` und führe sie aus“.
Jede Datei ist in sich vollständig (Ziel, Dateien, Regeln, Prüfung, Abgabe). Subagenten committen **nicht** –
das macht die Hauptsitzung nach Durchsicht.

| Datei | Aufgabe |
|---|---|
| `subagent_uebersetzung.md` | neue/geänderte UI-Texte in alle 14 Sprachen übersetzen |
| `subagent_tests.md` | Ungetestetes (Session-Browser, Resume fremder Harnesse, /compress, /model) prüfen |
| `subagent_doku.md` | README/Hilfetexte nach Code-Änderungen nachziehen |
| `subagent_review.md` | geänderte Dateien auf Fehler, tote Pfade, Sicherheitsprobleme durchsehen |
| `subagent_maintainer.md` | GitHub/Repo-Pflege: Commits, Release, Aufräumen, Issue-Entwürfe |
| `subagent_tui.md` | Terminal-/grafische Oberfläche prüfen, Test-Oberfläche (tmux/pty) |
| `subagent_triage.md` | Bugtracker: liest `tracker/INBOX.md`, ordnet in `TRACKER.md`, schreibt Aufträge für die anderen Agenten |
| `subagent_clau.md` | clau selbst: Modellwahl, Routing (welches Modell wann/wo), Menüs, Konfiguration, Proxy |
| `subagent_qode.md` | Qode als Coding-Werkzeug: Agent-Schleife, Werkzeuge, Befehle, Sitzungen, Modellanbindung |

## Bugtracker
`tracker/INBOX.md` ← David schreibt frei rein · `tracker/TRACKER.md` ← geordnete Liste · `tracker/auftraege/` ← Aufträge je Agent.
Ablauf: Triage-Agent sortiert → Aufträge → Subagenten arbeiten → Triage trägt Ergebnis ein → Hauptsitzung committet.
| `subagent_admin_installer.md` | Webrecherche, Programme/Tools installieren, Daten für ccclau besorgen (dokumentiert in `docs/BESCHAFFT.md`) |
