"""Wörter für die Statusleiste („Grübelt…“, „Tüftelt…“) – frei anpassbar je Installation.

Die Wörter stehen in einer JSON-Datei: ``$NANO_VERBEN`` oder ``~/.nano_claude/verben.json``.
Fehlt sie, wird sie beim ersten Start mit dem Standard unten angelegt; danach kann jede Installation
sie nach Belieben ändern (Wörter hinzufügen, löschen, eigene Zustände). Fehlende Schlüssel fallen auf den Standard zurück.
"""
from __future__ import annotations

import json
import os
import random
import time
from pathlib import Path

STANDARD: dict = {
    "_hinweis": "Wörter für die Statusleiste von nano. Pro Zustand eine Liste; nano wechselt reihum. "
                "wechsel_sekunden = wie lange ein Wort steht. mit_zustand = technischen Zustand (prefill/reasoning/…) dahinter zeigen.",
    "wechsel_sekunden": 8,
    "mit_zustand": False,
    "zustaende": {
        "prefill":   ["Grübelt", "Brütet", "Sortiert Gedanken", "Räuspert sich", "Spitzt die Bleistifte", "Sammelt sich",
                      "Kramt in der Schublade", "Knackt die Fingerknöchel"],
        "reasoning": ["Denkt nach", "Tüftelt", "Knobelt", "Wägt ab", "Philosophiert", "Zerbricht sich den Kopf",
                      "Spinnt Fäden", "Hulahoopt", "Hirnt", "Rührt im Gedankentopf"],
        "streaming": ["Schreibt", "Formuliert", "Tippt", "Dichtet", "Kritzelt", "Feilt an Sätzen"],
        "compact":   ["Faltet den Verlauf zusammen", "Räumt auf", "Packt den Koffer"],
        "tool":      ["Werkelt", "Schraubt", "Hämmert", "Baut"],
        "approval":  ["Wartet auf dein Ja"],
    },
    "fertig": ["Gegrübelt", "Getüftelt", "Gewerkelt", "Geknobelt", "Gebrütet", "Gehulahoopt", "Gefeilt", "Gebastelt"],
}

_cfg: dict | None = None
_seed = random.random()


def _pfad() -> Path:
    p = os.environ.get("NANO_VERBEN")
    return Path(p).expanduser() if p else Path.home() / ".nano_claude" / "verben.json"


def laden(neu: bool = False) -> dict:
    """Konfiguration lesen (beim ersten Mal Standarddatei anlegen). Fehler → Standard."""
    global _cfg
    if _cfg is not None and not neu:
        return _cfg
    cfg = json.loads(json.dumps(STANDARD))
    p = _pfad()
    try:
        if p.exists():
            user = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(user, dict):
                for k, v in user.items():
                    if k == "zustaende" and isinstance(v, dict):
                        for z, lst in v.items():
                            if isinstance(lst, list) and lst and all(isinstance(x, str) for x in lst):
                                cfg["zustaende"][z] = lst
                    elif k == "fertig":
                        if isinstance(v, list) and v and all(isinstance(x, str) for x in v):
                            cfg["fertig"] = v
                    elif k in ("wechsel_sekunden", "mit_zustand"):
                        cfg[k] = v
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps(STANDARD, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except Exception:
        pass
    _cfg = cfg
    return cfg


def neuer_zug() -> None:
    """Pro Auftrag ein anderer Startpunkt in den Listen."""
    global _seed
    _seed = random.random()


def wort(zustand: str, sekunden: float) -> str | None:
    """Wort für den Zustand; wechselt reihum alle ``wechsel_sekunden``. None = kein Wort definiert."""
    cfg = laden()
    z = "tool" if zustand.startswith("tool:") else zustand
    lst = cfg["zustaende"].get(z)
    if not lst:
        return None
    try:
        step = max(1.0, float(cfg.get("wechsel_sekunden", 8)))
    except (TypeError, ValueError):
        step = 8.0
    i = int(_seed * len(lst)) + int(max(0.0, sekunden) // step)
    return lst[i % len(lst)]


def fertig_wort() -> str:
    lst = laden()["fertig"]
    return lst[int(_seed * len(lst)) % len(lst)]


def mit_zustand() -> bool:
    return bool(laden().get("mit_zustand"))
