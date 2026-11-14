"""Terminal-Oberfläche von nano: eigene Optik, aber bewusst nach dem Bedienmuster von Claude Code gebaut
(Kopfzeile, Eingabe mit Statusleiste, Antworttext, Tool-Zeilen mit eingerücktem Ergebnis, Spinner mit
Laufzeit, Rückfrage mit nummerierten Optionen), damit Umsteiger nichts neu lernen müssen.
"""
from __future__ import annotations

import os
import shutil
import sys
import threading
import time
from pathlib import Path

_TTY = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def c(text: str, *codes: str) -> str:
    """ANSI-Farbe; ohne Terminal (Pipe) bleibt der Text unverändert."""
    if not _TTY:
        return str(text)
    return "".join(codes) + str(text) + "\033[0m"


ACCENT = "\033[38;5;80m"    # Türkis
GREY = "\033[38;5;245m"
DIM = "\033[2m"
BOLD = "\033[1m"
RED = "\033[38;5;203m"
GREEN = "\033[38;5;114m"
AMBER = "\033[38;5;222m"


def _width() -> int:
    return max(40, min(shutil.get_terminal_size((100, 24)).columns - 1, 120))


def _home_short(p) -> str:
    s = str(p)
    h = str(Path.home())
    return "~" + s[len(h):] if s.startswith(h) else s


def rule() -> str:
    return c("─" * _width(), GREY)


# ── Kopfzeile ────────────────────────────────────────────────────────────

def print_banner(model: str, provider: str, tools_count: int, skill_count: int = 0,
                 session_title: str = "", resumed: str = "") -> None:
    rows = [
        (c("nano", BOLD, ACCENT) + c("  ·  terminal coding agent (Claude Code clone)", GREY)),
        c("model   ", GREY) + c(model, BOLD),
        c("folder  ", GREY) + _home_short(Path.cwd()),
    ]
    extra = f"{tools_count} tools" + (f" · {skill_count} skills" if skill_count else "")
    rows.append(c("tools   ", GREY) + extra)
    if session_title:
        rows.append(c("session ", GREY) + session_title)
    if resumed:
        rows.append(c("resumed ", GREY) + c(resumed, AMBER))
    print()
    for r in rows:
        print("  " + r)
    print()
    print("  " + c("/help for commands · Tab completes · Ctrl+C interrupts · Ctrl+C twice exits", GREY))


# ── Eingabe ──────────────────────────────────────────────────────────────

STATUS = {"model": "", "mode": "", "ctx": ""}


def status_text() -> str:
    parts = [p for p in (STATUS["model"], STATUS["mode"], STATUS["ctx"]) if p]
    return "  " + "  ·  ".join(parts)


def prompt_plain() -> str:
    return "\n" + rule() + "\n" + c("❯ ", BOLD, ACCENT)


# ── Antworttext (mit Markdown) ───────────────────────────────────────────

import re

_RE_CODE = re.compile(r"`([^`\n]+)`")
_RE_BOLD = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*")
_RE_ITAL = re.compile(r"(?<![\*\w])\*(?![\s\*])([^*\n]+?)(?<![\s\*])\*(?![\*\w])")
_RE_LINK = re.compile(r"\[([^\]\n]+)\]\((https?://[^)\s]+)\)")


def _st(on: str, off: str, text: str) -> str:
    return f"{on}{text}{off}" if _TTY else text


def inline(text: str) -> str:
    """Inline-Markdown: `code`, **fett**, *kursiv*, [text](url)."""
    keep: list[str] = []

    def stash(m):  # Code zuerst herausnehmen, damit darin nichts weiter ersetzt wird
        keep.append(_st("\033[38;5;222m", "\033[39m", m.group(1)))
        return f"\x00{len(keep) - 1}\x00"

    text = _RE_CODE.sub(stash, text)
    text = _RE_BOLD.sub(lambda m: _st("\033[1m", "\033[22m", m.group(1)), text)
    text = _RE_ITAL.sub(lambda m: _st("\033[3m", "\033[23m", m.group(1)), text)
    text = _RE_LINK.sub(lambda m: m.group(1) + _st("\033[2m", "\033[22m", f" ({m.group(2)})"), text)
    return re.sub(r"\x00(\d+)\x00", lambda m: keep[int(m.group(1))], text)


def _plain(text: str) -> str:
    """Markdown-Zeichen entfernen (für Überschriften, die ohnehin fett sind)."""
    text = _RE_CODE.sub(r"\1", text)
    text = _RE_BOLD.sub(r"\1", text)
    return _RE_ITAL.sub(r"\1", text)


_BULLET = re.compile(r"^(\s*)[-*+] ")


class TextOut:
    """Streamt Antworttext mit Aufzählungspunkt vorn, eingerückten Folgezeilen und Markdown-Darstellung
    (Überschriften, Listen, Zitate, Codeblöcke, **fett**, *kursiv*, `code`). Es wird wortweise ausgegeben,
    sobald die Inline-Markierungen im ausgegebenen Stück ausgeglichen sind."""

    def __init__(self) -> None:
        self.buf = ""
        self.fresh = True        # am Zeilenanfang, Zeilenart noch offen
        self.mode: str | None = None   # None | "h" | "q" | "code"
        self.in_code = False
        self.open = False        # Antwortblock begonnen (Punkt schon gesetzt)

    # -- Ausgabe ------------------------------------------------------
    def _emit(self, s: str) -> None:
        sys.stdout.write(s)

    def _prefix(self) -> str:
        pre = c("● ", ACCENT) if not self.open else "  "
        self.open = True
        return pre

    def write(self, chunk: str) -> None:
        self.buf += chunk
        self._drain(final=False)
        sys.stdout.flush()

    def _drain(self, final: bool) -> None:
        while self.buf:
            if self.fresh:
                if self.buf.startswith("\n"):          # Leerzeile
                    self._emit("\n"); self.buf = self.buf[1:]; continue
                nl = self.buf.find("\n")
                if nl < 0 and " " not in self.buf and not final:
                    return                              # Zeilenart noch nicht erkennbar
                line = self.buf[:nl] if nl >= 0 else self.buf
                body = line.lstrip()
                if self.in_code or body.startswith("```"):
                    if body.startswith("```"):          # Zaun: ganze Zeile abwarten
                        if nl < 0 and not final:
                            return
                        self.in_code = not self.in_code
                        lang = body[3:].strip()
                        self._emit(self._prefix() + c("┄┄ " + (lang or "code") if self.in_code else "┄┄", GREY) + "\n")
                        self.buf = self.buf[nl + 1:] if nl >= 0 else ""
                        continue
                    self.mode = "code"
                elif re.match(r"^#{1,6} ", body):
                    self.mode = "h"
                    self.buf = re.sub(r"^(\s*)#{1,6} ", r"\1", self.buf, count=1)
                elif body.startswith("> "):
                    self.mode = "q"
                    self.buf = self.buf.replace("> ", "", 1)
                elif re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", body.strip()) and nl >= 0:
                    self._emit(self._prefix() + c("─" * 40, GREY) + "\n")
                    self.buf = self.buf[nl + 1:]
                    continue
                else:
                    self.mode = None
                    self.buf = _BULLET.sub(lambda m: m.group(1) + "• ", self.buf, count=1)
                self._emit(self._prefix() + ("  │ " if False else ""))
                if self.mode == "q":
                    self._emit(c("│ ", GREY))
                self.fresh = False
            nl = self.buf.find("\n")
            if nl >= 0:
                self._seg(self.buf[:nl]); self._emit("\n")
                self.buf = self.buf[nl + 1:]
                self.fresh = True
                continue
            if final:
                self._seg(self.buf); self.buf = ""
                return
            sp = self.buf.rfind(" ")
            if sp < 0:
                return
            seg = self.buf[:sp + 1]
            flat = seg.replace("**", "")
            if self.mode != "code" and (seg.count("**") % 2 or seg.count("`") % 2 or flat.count("*") % 2):
                return                                  # Markierung noch offen: auf mehr Text warten
            self._seg(seg); self.buf = self.buf[sp + 1:]
            return

    def _seg(self, text: str) -> None:
        if not text:
            return
        if self.mode == "code":
            self._emit(c(text, "\033[38;5;180m"))
        elif self.mode == "h":
            self._emit(c(_plain(text), BOLD, ACCENT))
        elif self.mode == "q":
            self._emit(c(_plain(text), GREY))
        else:
            self._emit(inline(text))

    def end_block(self) -> None:
        """Textblock beendet (z.B. vor Tool-Zeile): Rest ausgeben, Zeile abschließen, zurücksetzen."""
        self._drain(final=True)
        if self.open and not self.fresh:
            self._emit("\n")
        self.buf = ""
        self.fresh = True
        self.open = False
        self.in_code = False
        sys.stdout.flush()


# ── Tool-Zeilen ──────────────────────────────────────────────────────────

def tool_line(desc: str) -> str:
    name, _, rest = desc.partition("(")
    return "\n" + c("▪ ", ACCENT) + c(name, BOLD) + (c("(" + rest, GREY) if rest else "")


def tool_result_line(name: str, result, permitted: bool) -> str:
    if not permitted:
        return "  " + c("└ ", GREY) + c("denied", RED)
    text = result if isinstance(result, str) else str(result)
    if text.startswith("Error:"):
        return "  " + c("└ ", GREY) + c(text[:160].replace("\n", " "), RED)
    lines = text.count("\n") + (1 if text and not text.endswith("\n") else 0)
    first = next((l.strip() for l in text.splitlines() if l.strip()), "")
    first = first[:90] + ("…" if len(first) > 90 else "")
    meta = f"{lines} line{'s' if lines != 1 else ''}"
    return "  " + c("└ ", GREY) + c(meta, GREY) + ((c("  ", GREY) + c(first, DIM)) if first and lines > 0 else "")


# ── Rückfrage ────────────────────────────────────────────────────────────

def ask_permission(desc: str, config: dict) -> bool:
    print()
    print("  " + c("? ", BOLD, AMBER) + c(desc, BOLD))
    print("    " + c("1", BOLD) + " Yes")
    print("    " + c("2", BOLD) + " Yes, and don't ask again this session")
    print("    " + c("3", BOLD) + " No   " + c("(Enter)", GREY))
    try:
        ans = input("  " + c("› ", ACCENT)).strip().lower()
    except (KeyboardInterrupt, EOFError):
        print()
        return False
    if ans in ("2", "a", "always"):
        config["permission_mode"] = "accept-all"
        print("  " + c("accept-all for this session", GREY))
        return True
    return ans in ("1", "y", "yes")


# ── Spinner ──────────────────────────────────────────────────────────────

_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


class Spinner:
    """Zeigt „⠋ Working… (12s)“ in einer Zeile, solange auf das Modell oder ein Tool gewartet wird."""

    def __init__(self) -> None:
        self._stop = threading.Event()
        self._t: threading.Thread | None = None
        self.label = "Working"
        self.t0 = time.monotonic()

    def start(self, label: str | None = None) -> None:
        if not _TTY or (self._t and self._t.is_alive()):
            return
        if label:
            self.label = label
        self._stop.clear()
        self.t0 = time.monotonic()
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    def _run(self) -> None:
        i = 0
        while not self._stop.wait(0.1):
            el = int(time.monotonic() - self.t0)
            sys.stdout.write(f"\r\033[2K  {c(_FRAMES[i % len(_FRAMES)], ACCENT)} "
                             f"{c(self.label + '…', GREY)} {c(f'({el}s · Ctrl+C to interrupt)', DIM)}")
            sys.stdout.flush()
            i += 1

    def stop(self) -> None:
        if self._t:
            self._stop.set()
            self._t.join(timeout=0.5)
            self._t = None
            sys.stdout.write("\r\033[2K")
            sys.stdout.flush()


def with_spinner(events, spinner: Spinner, label_of=None):
    """Reicht Events durch; während auf das nächste gewartet wird, läuft der Spinner."""
    it = iter(events)
    while True:
        spinner.start()
        try:
            ev = next(it)
        except StopIteration:
            spinner.stop()
            return
        except BaseException:
            spinner.stop()
            raise
        spinner.stop()
        if label_of:
            lab = label_of(ev)
            if lab:
                spinner.label = lab
        yield ev
