# RAG / Indexing — Vorbereitungsnotizen

Stand: Vorbereitung, noch nichts gebaut. Ziel: lokale Modelle sollen eigene Dokumente
(zuerst Paperless-ngx) schnell und mit wenig Token durchsuchen können, ohne dass der
Verlauf mit ganzen Dokumenten vollläuft.

## Ist-Stand
- `paperless_mcp.py` (MCP, stdio) hat drei Tools: `paperless_search` (Volltext über die
  Paperless-API), `paperless_read` (Text eines Dokuments, gekürzt), `paperless_tags`.
- Token liegt in `~/.config/clau/paperless.token` (chmod 600), Menü `x → 2 → t`.
- Bisher nur gegen eine Attrappe der API getestet, **nicht** gegen das echte Paperless.
- nano und Claude Code nutzen denselben Server (nano über eigenen MCP-Client).

## Stufe 1: Paperless-Volltext (fertig, nur noch echt testen)
- Mit echtem Token prüfen: Suche, Lesen, Tags; Treffer-Qualität bei deutschen Texten.
- Offene Frage: reicht die Paperless-Volltextsuche (Whoosh) für den Alltag?
  Wenn ja, ist Stufe 2 optional.

## Stufe 2: eigener Vektor-Index (nur wenn Stufe 1 nicht reicht)
Idee: Dokumente in Abschnitte teilen, Embeddings berechnen, lokal speichern,
per MCP-Tool `rag_search` die besten Abschnitte liefern.

Bausteine:
1. **Quelle:** Paperless-API (`/api/documents/?modified__gt=…`) für inkrementelle Updates.
2. **Chunking:** ca. 300–500 Token pro Abschnitt, etwas Überlappung, Titel/Datum/Tags
   als Metadaten mitspeichern.
3. **Embedding-Modell:** noch zu klären (lokal über QuiteQue/owlAPI oder eigener
   Embedding-Server). Prüfen, ob die owlAPI einen Embeddings-Endpunkt anbietet und
   welches Modell dort läuft; Dimension und Sprache (Deutsch) beachten.
4. **Speicher:** klein halten, z. B. SQLite (mit Vektor-Erweiterung) oder eine einfache
   Datei mit NumPy-Matrix. Pfad unter `~/.local/share/clau/rag/`, nicht im Repo.
5. **Aktualisierung:** per Befehl (`clau --rag-index`) oder beim Start prüfen, was seit
   dem letzten Lauf geändert wurde; Gelöschtes entfernen.
6. **MCP-Tool:** `rag_search(query, limit)` liefert Dokument-ID, Titel, Abschnitt und
   Fundstelle; `paperless_read` bleibt für das ganze Dokument.
7. **Menü:** Eintrag unter `x → MCP-Server`, standardmäßig aus (jeder Server kostet
   Tool-Schemas pro Anfrage).

## Offene Entscheidungen (bitte klären)
- Embedding-Modell und wo es läuft (und ob es die lokalen Karten blockiert; die
  Flash-Modelle belegen beide GPUs und verdrängen andere Modelle).
- Nur Paperless oder auch Verzeichnisse/Notizen/Code?
- Wie oft aktualisieren (manuell, beim Start, per Zeitplan)?
- Auf welchem Rechner liegt der Index (Zielsystem mit Paperless oder hier)?

## Test-Plan
1. Paperless-Token setzen, Stufe 1 mit echten Dokumenten prüfen (Suche, Lesen).
2. Kleiner Testbestand (20–50 Dokumente): Index bauen, 10 Testfragen, Treffer von Hand
   bewerten und mit der Volltextsuche vergleichen.
3. Token-Zähler (`clau --usage`) vorher/nachher: kostet das Tool mehr, als es spart?

## Nebenbei beobachtet
- Die Websuche (QuiteQue `/websearch`) hing zeitweise im Server: Der MCP-Server
  antwortet auf `initialize`, die Suche selbst dauerte über 45 s. Das lag nicht an clau.
