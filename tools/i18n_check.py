#!/usr/bin/env python3
"""Prüft alle locales/<lang>.json: gültiges JSON, gleiche Schlüssel wie en.json,
gleiche Platzhalter in gleicher Anzahl/Art."""
import json
import os
import re
import sys

LOCALES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "locales")
LANGS = ["en", "de", "es", "fr", "pt", "it", "nl", "pl", "tr", "ru", "uk", "ja", "ko", "zh", "ar", "hi"]

PLACEHOLDER_RE = re.compile(r"%[sd]")


def placeholders(s: str) -> list:
    return PLACEHOLDER_RE.findall(s)


def main():
    errors = []
    en_path = os.path.join(LOCALES, "en.json")
    if not os.path.exists(en_path):
        print("Fehler: en.json fehlt (Referenzkatalog)")
        return 1

    with open(en_path, "r", encoding="utf-8") as f:
        en = json.load(f)
    en_keys = set(en.keys())

    for lang in LANGS:
        path = os.path.join(LOCALES, f"{lang}.json")
        if not os.path.exists(path):
            errors.append(f"{lang}.json fehlt")
            continue

        try:
            with open(path, "r", encoding="utf-8") as f:
                cat = json.load(f)
        except json.JSONDecodeError as e:
            errors.append(f"{lang}.json: ungültiges JSON: {e}")
            continue

        keys = set(cat.keys())
        missing = en_keys - keys
        extra = keys - en_keys
        if missing:
            errors.append(f"{lang}.json: fehlende Schlüssel: {', '.join(sorted(missing))}")
        if extra:
            errors.append(f"{lang}.json: zusätzliche Schlüssel: {', '.join(sorted(extra))}")

        # Platzhalter prüfen
        for key in en_keys & keys:
            en_ph = placeholders(en[key])
            lang_ph = placeholders(cat[key])
            if en_ph != lang_ph:
                errors.append(f"{lang}.json: {key} — Platzhalter {lang_ph} != {en_ph}")

    if errors:
        print("Fehler gefunden:")
        for e in errors:
            print(f"  - {e}")
        return 1
    else:
        print("Alle Kataloge OK.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
