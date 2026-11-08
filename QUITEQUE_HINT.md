# QuiteQue / PropellerA – Fähigkeiten (für den Agenten)

Neben Chat-Modellen bietet QuiteQue (`$OWL_BASE_URL`, meist http://11.0.0.13:7077, OpenAI-kompatibel unter `/v1`)
auch Spezialmodelle. Aufruf per curl/HTTP mit den Headern `X-OwlTrail-User: $CLAU_QQ_USER` (Standard `ccclau`),
`X-User`, `X-Agent-Tool`, `X-Project`, `X-Request-Context`. Aktuelle Liste und Status: `GET /v1/models`
(Feld `status`; `upstream_down` = gerade nicht nutzbar). Nutze sie, wenn der Auftrag es verlangt – nicht ungefragt.

- Bildgenerierung: 135 Qwen-Image 2.1 (beste Qualität), 130 Flux, 131 SDXL-Turbo (schnell); Upscaling: 180
- Sound/Musik: 151 Klang, 150 ACE-Step
- Spracherkennung (ASR): 170, 171, 125–128 · Sprachausgabe (TTS): 160, 161, 162
- Audio-Analyse: 173–175 · Video: 140 · 3D (Bild → GLB/druckfertiges STL): 145, 146
- Omni (Text+Bild+Audio): 172, 261 · Web-Suche: 117 (gründlich), 118 (schnell)

Unklare Parameter: zuerst `GET /v1/models` und die Fehlermeldung der API lesen, nicht raten.
Ergebnisdateien im Projektordner speichern und dem Nutzer den Pfad nennen.
