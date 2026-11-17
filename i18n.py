"""Mehrsprachigkeit für Python-Komponenten (nano, Proxy, Hilfsskripte).

Sprachwahl: CLAU_LANG (Umgebung) -> LC_ALL -> LC_MESSAGES -> LANG -> LANGUAGE -> en.
Kataloge: locales/<lang>.json, Fallback auf en.json.
"""
import json
import os
import re
import unicodedata

LOCALE_DIR = os.environ.get("NANO_LOCALE_DIR",
                            os.path.join(os.path.dirname(os.path.abspath(__file__)), "locales"))
LANGS = ["en", "de", "es", "fr", "pt", "it", "nl", "pl", "tr", "ru", "uk", "ja", "ko", "zh", "ar", "hi"]

_caches = {}
_current_lang = None


def detect_lang() -> str:
    """Sprache aus Umgebung bestimmen."""
    # CLAU_LANG hat Vorrang (von clau.sh gesetzt oder Benutzerkonfiguration)
    clau_lang = os.environ.get("CLAU_LANG", "").strip()
    if clau_lang and clau_lang != "auto":
        code = clau_lang.split("_")[0].split(".")[0].split("@")[0].lower()
        if code in LANGS:
            return code

    # Dann Konsole
    for var in ["LC_ALL", "LC_MESSAGES", "LANG", "LANGUAGE"]:
        val = os.environ.get(var, "").strip()
        if not val or val in ("C", "POSIX"):
            continue
        code = val.split("_")[0].split(".")[0].split("@")[0].lower()
        if code in LANGS:
            return code

    return "en"


def load_catalog(lang: str) -> dict:
    global _caches
    if lang in _caches:
        return _caches[lang]

    path = os.path.join(LOCALE_DIR, f"{lang}.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            cat = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        cat = {}

    _caches[lang] = cat
    return cat


def init(lang: str = None):
    """Initialisiert i18n mit gegebener oder erkannter Sprache."""
    global _current_lang
    if lang is None:
        lang = detect_lang()
    _current_lang = lang
    load_catalog(lang)
    load_catalog("en")  # Fallback immer laden


def _(key: str, *args, **kwargs) -> str:
    """Übersetzt einen Schlüssel mit optionalen Platzhaltern."""
    global _current_lang
    if _current_lang is None:
        init()

    lang = _current_lang
    cat = load_catalog(lang)
    text = cat.get(key)

    if text is None:
        # Fallback auf Englisch
        en_cat = load_catalog("en")
        text = en_cat.get(key, key)

    if args or kwargs:
        try:
            text = text % args if args else text % kwargs
        except (TypeError, ValueError):
            pass  # Platzhalter stimmen nicht, Text trotzdem ausgeben

    return text


def vlen(s: str) -> int:
    """Anzeigebreite eines Strings (CJK=2, kombinierende Zeichen=0)."""
    width = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        eaw = unicodedata.east_asian_width(ch)
        if eaw in ("W", "F"):
            width += 2
        else:
            width += 1
    return width


def clip(s: str, width: int) -> str:
    """Auf sichtbare Breite kürzen, mit … am Ende."""
    if vlen(s) <= width:
        return s
    out, n, i = [], 0, 0
    while i < len(s) and n < width - 1:
        ch = s[i]
        if unicodedata.combining(ch):
            out.append(ch)
        else:
            eaw = unicodedata.east_asian_width(ch)
            w = 2 if eaw in ("W", "F") else 1
            if n + w > width - 1:
                break
            out.append(ch)
            n += w
        i += 1
    return "".join(out) + "…"


def wrap(s: str, width: int) -> list:
    """Text umbruch auf Zeilen mit gegebener Breite."""
    lines = []
    words = s.split()
    current = []
    current_width = 0

    for word in words:
        word_width = vlen(word)
        if current and current_width + 1 + word_width > width:
            lines.append(" ".join(current))
            current = [word]
            current_width = word_width
        else:
            if current:
                current_width += 1
            current.append(word)
            current_width += word_width

    if current:
        lines.append(" ".join(current))

    return lines


# Initialisierung beim Import
init()
