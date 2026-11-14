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
        self.lang_name = ""
        self.lang = ""
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
                        self.lang_name = _LANG.get(lang.lower().split()[0], "") if self.in_code and lang else ""
                        self._emit(self._prefix() + c("┄┄ " + (lang or "code") if self.in_code else "┄┄", GREY) + "\n")
                        self.buf = self.buf[nl + 1:] if nl >= 0 else ""
                        continue
                    self.mode = "code"
                    self.lang = self.lang_name
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
            self._emit(highlight(text, self.lang) if self.lang else c(text, "\033[38;5;180m"))
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


_KW = {
    "py": "def class return if elif else for while try except finally with as import from in not and or is None True False "
          "lambda yield raise pass break continue async await self global nonlocal assert del",
    "js": "function const let var return if else for while try catch finally new class extends import export from default "
          "async await null undefined true false this throw typeof switch case break continue of in",
    "sh": "if then else elif fi for while do done case esac function in local export return echo cd exit set unset",
    "go": "func package import return if else for range var const type struct interface map chan go defer switch case nil true false",
    "rs": "fn let mut pub use mod struct enum impl trait return if else for while match loop in as self Self true false",
    "c": "int char void long short float double unsigned struct enum typedef return if else for while switch case break "
         "continue static const sizeof NULL include define",
}
_LANG = {"py": "py", "python": "py", "js": "js", "ts": "js", "jsx": "js", "tsx": "js", "javascript": "js", "typescript": "js",
         "sh": "sh", "bash": "sh", "zsh": "sh", "go": "go", "rs": "rs", "rust": "rs", "c": "c", "h": "c", "cpp": "c", "cc": "c",
         "java": "js", "json": "js"}
_HL = {}


def lang_of(name: str) -> str:
    return _LANG.get(name.lower().lstrip(".").rsplit(".", 1)[-1], "")


def highlight(line: str, lang: str) -> str:
    """Sehr leichte Syntaxfärbung (Kommentar, Zeichenkette, Zahl, Schlüsselwort) für eine Zeile."""
    if not _TTY or not lang:
        return line
    if lang not in _HL:
        kw = "|".join(sorted(_KW.get(lang, "").split(), key=len, reverse=True)) or "(?!)"
        com = r"#.*$" if lang in ("py", "sh") else r"//.*$"
        _HL[lang] = re.compile(
            r"(?P<com>" + com + r")|(?P<str>\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')|(?P<num>\b\d[\d_.]*\b)|(?P<kw>\b(?:" + kw + r")\b)"
        )
    col = {"com": GREY, "str": "\033[38;5;180m", "num": "\033[38;5;141m", "kw": "\033[38;5;75m"}

    def rep(m):
        k = m.lastgroup
        return f"{col[k]}{m.group(0)}\033[0m"
    return _HL[lang].sub(rep, line)


_BG_ADD = "\033[48;5;22m"
_BG_DEL = "\033[48;5;52m"


def _code_rows(lines, start: int, lang: str, limit: int, kind: str = "") -> list[str]:
    """Nummerierte Codezeilen; kind '+' / '-' färbt als Diff."""
    out = []
    width = len(str(start + len(lines)))
    for k, ln in enumerate(lines[:limit]):
        num = str(start + k).rjust(width)
        ln = ln.replace("\t", "    ").rstrip("\n")
        if len(ln) > _width() - 14:
            ln = ln[:_width() - 15] + "…"
        if kind == "+":
            out.append("      " + c(num + " + ", GREEN) + _BG_ADD + highlight(ln, lang) + "\033[0m")
        elif kind == "-":
            out.append("      " + c(num + " - ", RED) + _BG_DEL + ln + "\033[0m")
        else:
            out.append("      " + c(num + "   ", GREY) + highlight(ln, lang))
    if len(lines) > limit:
        out.append("      " + c(f"… +{len(lines) - limit} lines", GREY))
    return out


def _file_lines(path: str) -> list[str]:
    try:
        return Path(path).expanduser().read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return []


def tool_result(name: str, inputs: dict, result, permitted: bool) -> str:
    """Ergebniszeile(n) unter einer Tool-Zeile: Zusammenfassung plus Code-/Diff-Ausschnitt wie bei Claude Code."""
    head = tool_result_line(name, result, permitted)
    if not permitted:
        return head
    text = result if isinstance(result, str) else str(result)
    if text.startswith("Error:"):
        return head
    path = str(inputs.get("file_path") or inputs.get("path") or "")
    lang = lang_of(path) if path else ""
    rows: list[str] = []
    pre = "  " + c("└ ", GREY)
    if name == "Edit" and inputs.get("old_string") is not None:
        old = str(inputs.get("old_string")).splitlines()
        new = str(inputs.get("new_string", "")).splitlines()
        fl = _file_lines(path)
        first = new[0] if new else ""
        at = next((i for i in range(len(fl)) if fl[i:i + len(new)] == new), None) if new else None
        if at is None:
            at = 0
        before = fl[max(0, at - 2):at]
        after = fl[at + len(new):at + len(new) + 2]
        ln0 = max(1, at + 1)
        rows += _code_rows(before, max(1, ln0 - len(before)), lang, 3)
        rows += _code_rows(old, ln0, lang, 12, "-")
        rows += _code_rows(new, ln0, lang, 12, "+")
        rows += _code_rows(after, ln0 + len(new), lang, 3)
        summ = f"Updated {_home_short(path)}  " + c(f"+{len(new)}", GREEN) + c(" ", GREY) + c(f"-{len(old)}", RED)
        return pre + summ + "\n" + "\n".join(rows)
    if name == "Write" and inputs.get("content") is not None:
        body = str(inputs["content"]).splitlines()
        rows = _code_rows(body, 1, lang, 10)
        return pre + f"Wrote {len(body)} lines to {_home_short(path)}" + "\n" + "\n".join(rows)
    if name == "Read":
        body = [re.sub(r"^\s*\d+[\t|→:]\s?", "", l) for l in text.splitlines()]
        start = int(inputs.get("offset") or 1)
        rows = _code_rows(body, start, lang, 6)
        return pre + c(f"Read {len(body)} lines", GREY) + "\n" + "\n".join(rows)
    if name in ("Bash", "Grep", "Glob", "WebSearch", "WebFetch", "Agent"):
        body = [l for l in text.splitlines()]
        n = len(body)
        show = body[:6]
        rows = ["      " + c(l[:_width() - 8] + ("…" if len(l) > _width() - 8 else ""), DIM) for l in show]
        if n > 6:
            rows.append("      " + c(f"… +{n - 6} lines", GREY))
        if not n:
            return pre + c("(no output)", GREY)
        return pre + c(f"{n} line{'s' if n != 1 else ''}", GREY) + "\n" + "\n".join(rows)
    return head


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
    from nano_claude_code.screen import SCREEN
    print()
    print("  " + c("? ", BOLD, AMBER) + c(desc, BOLD))
    print("    " + c("1", BOLD) + " Yes")
    print("    " + c("2", BOLD) + " Yes, and don't ask again this session")
    print("    " + c("3", BOLD) + " No   " + c("(Enter / Esc)", GREY))
    if SCREEN.active:
        SCREEN.watch_stop()
        SCREEN.set_state("approval")
        try:
            while True:
                k = SCREEN.getkey().lower()
                if k in ("1", "y"):
                    ok = True; break
                if k in ("2", "a"):
                    config["permission_mode"] = "accept-all"
                    print("  " + c("accept-all for this session", GREY))
                    ok = True; break
                if k in ("3", "n", "\n", "\x1b", "\x03"):
                    ok = False; break
        finally:
            SCREEN.watch_start()
        print("  " + c("› " + ("yes" if ok else "no"), GREY))
        return ok
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
