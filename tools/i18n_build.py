#!/usr/bin/env python3
"""Erzeugt aus locales/<lang>.json die für clau.sh ladbaren locales/<lang>.sh.

Nur die clau.*-Schlüssel werden übernommen (nano.* bleibt für Python).
Die .sh-Dateien werden mitcommittet, damit eine Installation ohne Python
funktioniert.
"""
import json
import os
import sys

LOCALES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "locales")
LANGS = ["en", "de", "es", "fr", "pt", "it", "nl", "pl", "tr", "ru", "uk", "ja", "ko", "zh", "ar", "hi"]


def escape_sh(s: str) -> str:
    """Shell-sicheres Single-Quoting (Apostrophe werden escaped)."""
    return "'" + s.replace("'", "'\\''") + "'"


def build_lang(lang: str) -> None:
    src = os.path.join(LOCALES, f"{lang}.json")
    dst = os.path.join(LOCALES, f"{lang}.sh")
    with open(src, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    clau_keys = {k: v for k, v in catalog.items() if k.startswith("clau.")}
    if not clau_keys:
        print(f"  {lang}: keine clau.*-Schlüssel, übersprungen")
        return

    lines = [f"# Erzeugt von tools/i18n_build.py — nicht von Hand bearbeiten."]
    lines.append(f"# Sprache: {lang}")
    lines.append(f"declare -gA I18N_{lang.upper()}")
    for key in sorted(clau_keys):
        val = escape_sh(clau_keys[key])
        lines.append(f'I18N_{lang.upper()}["{key}"]={val}')
    lines.append("")

    with open(dst, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"  {lang}: {len(clau_keys)} Schlüssel -> {dst}")


def main():
    print("Erzeuge .sh-Kataloge für clau.sh ...")
    for lang in LANGS:
        src = os.path.join(LOCALES, f"{lang}.json")
        if not os.path.exists(src):
            print(f"  {lang}: {src} fehlt, übersprungen")
            continue
        build_lang(lang)
    print("Fertig.")


if __name__ == "__main__":
    main()
