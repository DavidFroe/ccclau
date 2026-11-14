"""Festes Bildschirmlayout für nano (wie bei Claude Code):

    oben   Kopfzeile (Propeller, Modell/API, Ordner, Tools- und Skill-Liste), bleibt stehen
    Mitte  scrollender Verlauf (Scroll-Region des Terminals)
    unten  Eingabefeld zwischen zwei Linien und eine Statusleiste
           (Modell · API · Effort · Modus  |  Zustand  |  Kontext benutzt/maximal)

Umgesetzt mit einer ANSI-Scroll-Region (DECSTBM) und einem eigenen, kleinen Zeileneditor. Ohne Terminal
(Pipe, NO_COLOR, zu kleines Fenster, NANO_PLAIN=1) bleibt `Screen.active` False, und nano verhält sich
wie vorher.
"""
from __future__ import annotations

import codecs
import os
import re
import select
import shutil
import signal
import sys
import threading
import time

try:
    import termios
except ImportError:  # kein POSIX
    termios = None

ACCENT = "\033[38;5;80m"
GREY = "\033[38;5;245m"
DIM = "\033[2m"
BOLD = "\033[1m"
RED = "\033[38;5;203m"
GREEN = "\033[38;5;114m"
AMBER = "\033[38;5;222m"
RST = "\033[0m"

_ANSI = re.compile(r"\033\[[0-9;?]*[A-Za-z]|\033[78]")


def vlen(s: str) -> int:
    return len(_ANSI.sub("", s))


def clip(s: str, width: int) -> str:
    """Auf sichtbare Breite kürzen (ANSI-Folgen bleiben ganz), mit … am Ende."""
    if vlen(s) <= width:
        return s
    out, n, i = [], 0, 0
    while i < len(s) and n < width - 1:
        m = _ANSI.match(s, i)
        if m:
            out.append(m.group(0)); i = m.end(); continue
        out.append(s[i]); n += 1; i += 1
    return "".join(out) + "…" + RST


PROPELLER = [
    " ╲ │ ╱ ",
    " ──◉── ",
    " ╱ │ ╲ ",
]


def _fmt_k(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.1f}k".replace(".0k", "k")
    return str(n)


class _Out:
    """stdout-Ersatz: serialisiert alle Schreibzugriffe (Hauptthread, Spinner, Statusleiste)."""

    def __init__(self, real, lock):
        self._real = real
        self._lock = lock

    def write(self, s):
        with self._lock:
            return self._real.write(s)

    def flush(self):
        with self._lock:
            self._real.flush()

    def __getattr__(self, name):
        return getattr(self._real, name)


class Screen:
    def __init__(self) -> None:
        self.active = False
        self.lock = threading.RLock()
        self.real = sys.stdout
        self.rows = 24
        self.cols = 80
        self.header: list[str] = []
        self.info: dict = {}
        self.state = "idle"
        self.state_t0 = time.monotonic()
        self.out_chars = 0
        self.ctx_used = lambda: 0
        self.ctx_max = 200_000
        self._ticker: threading.Thread | None = None
        self._tick_stop = threading.Event()
        self._hint = ""          # Vorschlagsleiste (ersetzt kurz die Statusleiste)
        self._old_winch = None

    # ── Aufbau ───────────────────────────────────────────────────────
    def _size(self) -> None:
        sz = shutil.get_terminal_size((100, 30))
        self.cols, self.rows = max(40, sz.columns), sz.lines

    def build_header(self) -> list[str]:
        i = self.info
        w = self.cols - 1
        bl = lambda s: c(s, BOLD)  # noqa: E731
        mascot = [c(PROPELLER[0], ACCENT), c(PROPELLER[1], ACCENT, BOLD), c(PROPELLER[2], ACCENT)]
        sess = i.get("session") or ""
        folder = i.get("folder", "")
        l1 = c("nano", BOLD, ACCENT) + c("  ·  PropellerA  ·  Claude-Code-Nachbau", GREY)
        l2 = bl(i.get("model", "")) + c("  via  ", GREY) + i.get("api", "")
        l3 = c(folder, GREY) + (c("  ·  ", GREY) + sess if sess else "")
        rows = [" " + mascot[0] + "  " + l1, " " + mascot[1] + "  " + l2, " " + mascot[2] + "  " + l3]
        tools = i.get("tools") or []
        skills = i.get("skills") or []
        if self.rows >= 26:
            rows.append(" " + self._list("tools ", tools, w))
            if skills:
                rows.append(" " + self._list("skills", skills, w))
            if i.get("resumed"):
                rows.append(" " + c("resumed ", GREY) + c(i["resumed"], AMBER))
        else:
            rows.append(" " + c(f"tools {len(tools)}" + (f" · skills {len(skills)}" if skills else ""), GREY))
        rows.append(c("─" * w, GREY))
        return [clip(r, w) for r in rows]

    def _list(self, label: str, names: list[str], width: int) -> str:
        head = c(label + " ", GREY) + c(f"({len(names)}) ", DIM)
        room = width - 2 - len(label) - len(str(len(names))) - 4
        shown, used = [], 0
        for n in names:
            if used + len(n) + 3 > room - 6 and shown:
                shown.append(c(f"+{len(names) - len(shown)}", GREY))
                break
            shown.append(c(n, ACCENT)); used += len(n) + 3
        return head + c(" · ", GREY).join(shown)

    def start(self, info: dict, ctx_used=None, ctx_max: int = 200_000) -> bool:
        if (termios is None or not sys.stdin.isatty() or not sys.stdout.isatty()
                or os.environ.get("NO_COLOR") is not None or os.environ.get("NANO_PLAIN") == "1"
                or os.environ.get("TERM", "") in ("", "dumb")):
            return False
        self._size()
        if self.rows < 16 or self.cols < 50:
            return False
        self.info = dict(info)
        if ctx_used:
            self.ctx_used = ctx_used
        self.ctx_max = ctx_max
        self.real = sys.stdout
        sys.stdout = _Out(self.real, self.lock)
        self.active = True
        self._layout(clear=True)
        try:
            self._old_winch = signal.signal(signal.SIGWINCH, lambda *_: self._resize())
        except (ValueError, OSError):
            self._old_winch = None
        import atexit
        atexit.register(self.stop)
        return True

    def stop(self) -> None:
        if not self.active:
            return
        self.active = False
        self._tick_stop.set()
        with self.lock:
            self.real.write(f"\033[r\033[{self.rows};1H\033[0m\033[?25h\n")
            self.real.flush()
        sys.stdout = self.real
        if self._old_winch is not None:
            try:
                signal.signal(signal.SIGWINCH, self._old_winch)
            except (ValueError, OSError):
                pass

    # Zeilen: Kopf 1..H | Region H+1..rows-5 | Linie rows-3 | Eingabe rows-2 | Linie rows-1 | Status rows
    def _geom(self):
        h = len(self.header)
        return h + 1, self.rows - 4, self.rows - 3, self.rows - 2, self.rows - 1, self.rows

    def _layout(self, clear: bool) -> None:
        with self.lock:
            self._size()
            self.header = self.build_header()
            top, bot, r1, rin, r2, rst = self._geom()
            w = self.real.write
            if clear:
                w("\033[2J")
            w("\033[r")
            for n, line in enumerate(self.header, 1):
                w(f"\033[{n};1H\033[2K{line}")
            w(f"\033[{r1};1H\033[2K{c('─' * (self.cols - 1), GREY)}")
            w(f"\033[{rin};1H\033[2K{c('❯ ', BOLD, ACCENT)}")
            w(f"\033[{r2};1H\033[2K{c('─' * (self.cols - 1), GREY)}")
            w(f"\033[{top};{bot}r\033[{top if clear else bot};1H")
            self.real.flush()
        self.draw_status()

    def _resize(self) -> None:
        if not self.active:
            return
        self._layout(clear=True)

    # ── Statusleiste ─────────────────────────────────────────────────
    def set_state(self, state: str) -> None:
        if state != self.state:
            self.state = state
            self.state_t0 = time.monotonic()
            if state == "prefill":
                self.out_chars = 0
        if self.active:
            self.draw_status()

    def add_out(self, n: int) -> None:
        self.out_chars += n

    def update_info(self, **kw) -> None:
        self.info.update(kw)
        if self.active:
            self.draw_status()

    def _state_label(self) -> str:
        s = self.state
        el = int(time.monotonic() - self.state_t0)
        if s == "idle":
            return c("● idle", GREEN) + c(" · waiting for input", GREY)
        lab = {
            "prefill": ("◐ prefill", AMBER),
            "reasoning": ("◑ reasoning", ACCENT),
            "streaming": ("◉ streaming", ACCENT),
            "approval": ("? awaiting approval", AMBER),
        }.get(s)
        if lab is None:  # tool:<Name>
            lab = (f"▪ {s.replace('tool:', 'running ')}", AMBER)
        extra = f" {el}s"
        if s in ("reasoning", "streaming") and self.out_chars:
            extra += f" · ↓{_fmt_k(self.out_chars // 4)} tok"
        return c(lab[0], lab[1]) + c(extra, GREY)

    def draw_status(self, restore: bool = True) -> None:
        if not self.active:
            return
        with self.lock:
            top, bot, r1, rin, r2, rst = self._geom()
            w = self.cols - 1
            if self._hint:
                line = " " + self._hint
            else:
                used = int(self.ctx_used() or 0)
                mx = max(1, int(self.ctx_max))
                pct = min(100, used * 100 // mx)
                col = GREEN if pct < 60 else (AMBER if pct < 85 else RED)
                bar_n = 8
                fill = min(bar_n, (pct * bar_n + 99) // 100) if used else 0
                bar = c("▓" * fill, col) + c("░" * (bar_n - fill), GREY)
                right = (self._state_label() + c("  │  ", GREY) + c("ctx ", GREY)
                         + c(f"{_fmt_k(used)}/{_fmt_k(mx)}", col, BOLD) + c(f" {pct}% ", GREY) + bar + " ")
                i = self.info
                eff = c("effort ", GREY) + c(i.get("effort", "-"), ACCENT)
                api = i.get("api", "")
                room = w - vlen(right) - 3
                left = ""
                for with_api, with_mode in ((1, 1), (1, 0), (2, 0), (0, 0)):
                    a = api if with_api == 1 else (api.split()[0] if with_api == 2 and api else "")
                    parts = [c(i.get("model", ""), BOLD), c(a, GREY) if a else "", eff,
                             c(i.get("mode", ""), GREY) if with_mode else ""]
                    left = " " + c(" · ", GREY).join(p for p in parts if p)
                    if vlen(left) <= room:
                        break
                left = clip(left, max(10, room))
                gap = max(2, w - vlen(left) - vlen(right))
                line = left + " " * gap + right
            body = f"\033[{rst};1H\033[2K{clip(line, w + 1)}"
            self.real.write(f"\0337{body}\0338" if restore else body)
            self.real.flush()

    def start_ticker(self) -> None:
        if not self.active or (self._ticker and self._ticker.is_alive()):
            return
        self._tick_stop.clear()

        def run():
            while not self._tick_stop.wait(0.4):
                if self.state != "idle":
                    self.draw_status()
        self._ticker = threading.Thread(target=run, daemon=True)
        self._ticker.start()

    # ── Eingabe ──────────────────────────────────────────────────────
    def _raw(self):
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        new = termios.tcgetattr(fd)
        new[0] &= ~(termios.ICRNL | termios.INLCR | termios.IXON)
        new[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG | termios.IEXTEN)
        new[6][termios.VMIN] = 1
        new[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSADRAIN, new)
        return fd, old

    def _read_keys(self, fd):
        """Erzeugt ('text', s) und ('key', name)."""
        dec = codecs.getincrementaldecoder("utf-8")("replace")
        data = b""

        def more(timeout=None) -> bool:
            nonlocal data
            if timeout is not None and not select.select([fd], [], [], timeout)[0]:
                return False
            chunk = os.read(fd, 4096)
            if not chunk:
                raise EOFError
            data += chunk
            return True

        while True:
            if not data:
                more()
            b = data[0]
            if b == 0x1b:
                if len(data) == 1 and not more(0.04):
                    data = data[1:]
                    yield ("key", "esc"); continue
                if data[1:2] == b"[":
                    j = 2
                    while True:
                        while j >= len(data):
                            more()
                        if 0x40 <= data[j] <= 0x7e:
                            break
                        j += 1
                    seq = data[2:j + 1].decode("ascii", "ignore")
                    data = data[j + 1:]
                    if seq == "200~":  # eingefügter Text bis ESC[201~
                        end = b"\x1b[201~"
                        while end not in data:
                            more()
                        txt, _, data = data.partition(end)
                        yield ("paste", txt.decode("utf-8", "replace")); continue
                    name = {"A": "up", "B": "down", "C": "right", "D": "left", "H": "home", "F": "end",
                            "1~": "home", "4~": "end", "7~": "home", "8~": "end", "3~": "delete",
                            "1;5C": "wright", "1;5D": "wleft", "1;3C": "wright", "1;3D": "wleft"}.get(seq)
                    if name:
                        yield ("key", name)
                    continue
                if data[1:2] == b"O" and len(data) >= 3:
                    name = {b"H": "home", b"F": "end"}.get(data[2:3])
                    data = data[3:]
                    if name:
                        yield ("key", name)
                    continue
                if len(data) >= 2:  # Alt+Taste
                    ch = data[1:2]
                    data = data[2:]
                    if ch in (b"\x7f", b"\x08"):
                        yield ("key", "wdel")
                    elif ch in (b"\r", b"\n"):
                        yield ("key", "newline")
                    continue
            if b < 0x20 or b == 0x7f:
                data = data[1:]
                name = {0x0d: "enter", 0x0a: "enter", 0x7f: "bs", 0x08: "bs", 0x01: "home", 0x05: "end",
                        0x0b: "kill_end", 0x15: "kill_start", 0x17: "wdel", 0x03: "ctrl_c", 0x04: "ctrl_d",
                        0x09: "tab", 0x0c: "redraw", 0x02: "left", 0x06: "right", 0x10: "up", 0x0e: "down",
                        0x1a: None}.get(b)
                if name:
                    yield ("key", name)
                continue
            j = 0
            while j < len(data) and data[j] >= 0x20 and data[j] != 0x7f and data[j] != 0x1b:
                j += 1
            s = dec.decode(data[:j])
            data = data[j:]
            if s:
                yield ("text", s)

    def read_line(self, history: list[str], complete=None) -> str:
        """Eine Eingabezeile im festen Eingabefeld lesen. Raises KeyboardInterrupt (Ctrl+C), EOFError (Ctrl+D)."""
        top, bot, r1, rin, r2, rst = self._geom()
        fd, old = self._raw()
        buf, pos = "", 0
        hist_i = len(history)
        draft = ""
        sugg: list[tuple[str, str]] = []   # (neuer Text, Meta)
        sel = -1
        base = ""
        pt = []                            # Zwischenspeicher für Tastenfolge
        self.real.write("\0337")

        def draw():
            avail = self.cols - 4
            disp = buf.replace("\n", "↵")
            start = 0 if pos < avail else pos - avail + 1
            vis = disp[start:start + avail]
            if buf.startswith("/"):
                vis_c = c(vis, BOLD)
            else:
                vis_c = vis
            with self.lock:
                self.real.write(f"\033[{rin};1H\033[2K{c('❯ ', BOLD, ACCENT)}{vis_c}")
                self._draw_hint()
                self.real.write(f"\033[{rin};{3 + pos - start}H")
                self.real.flush()

        def calc_sugg():
            nonlocal sugg, sel, base
            sugg, sel, base = [], -1, buf
            if complete and buf.startswith("/"):
                try:
                    sugg = list(complete(buf[:pos]))
                except Exception:
                    sugg = []
            self._hint = self._sugg_line(sugg, sel) if sugg else ""

        def pick(delta):
            nonlocal sel, buf, pos
            if not sugg:
                return False
            sel = (sel + delta) % len(sugg) if sel >= 0 else (0 if delta > 0 else len(sugg) - 1)
            buf = sugg[sel][0]
            pos = len(buf)
            self._hint = self._sugg_line(sugg, sel)
            return True

        calc_sugg()
        draw()
        try:
            for kind, val in self._read_keys(fd):
                if kind == "text" or kind == "paste":
                    txt = val.replace("\r\n", "\n").replace("\r", "\n") if kind == "paste" else val
                    buf = buf[:pos] + txt + buf[pos:]
                    pos += len(txt)
                    calc_sugg()
                elif val == "enter":
                    break
                elif val == "newline":
                    buf = buf[:pos] + "\n" + buf[pos:]; pos += 1; calc_sugg()
                elif val == "ctrl_c":
                    raise KeyboardInterrupt
                elif val == "ctrl_d":
                    if not buf:
                        raise EOFError
                elif val == "bs":
                    if pos:
                        buf = buf[:pos - 1] + buf[pos:]; pos -= 1; calc_sugg()
                elif val == "delete":
                    buf = buf[:pos] + buf[pos + 1:]; calc_sugg()
                elif val == "left":
                    pos = max(0, pos - 1)
                elif val == "right":
                    pos = min(len(buf), pos + 1)
                elif val == "home":
                    pos = 0
                elif val == "end":
                    pos = len(buf)
                elif val == "wleft":
                    pos = len(re.sub(r"\S+\s*$", "", buf[:pos]))
                elif val == "wright":
                    m = re.match(r"\s*\S+", buf[pos:])
                    pos = pos + (m.end() if m else len(buf) - pos)
                elif val == "kill_end":
                    buf = buf[:pos]; calc_sugg()
                elif val == "kill_start":
                    buf = buf[pos:]; pos = 0; calc_sugg()
                elif val == "wdel":
                    new = re.sub(r"\S+\s*$", "", buf[:pos])
                    buf = new + buf[pos:]; pos = len(new); calc_sugg()
                elif val == "tab":
                    if not sugg and complete and buf.startswith("/"):
                        calc_sugg()
                    pick(1)
                elif val == "esc":
                    if sugg:
                        buf = base if sel >= 0 else buf
                        pos = len(buf); sugg, sel = [], -1; self._hint = ""
                    else:
                        buf, pos = "", 0
                elif val in ("up", "down"):
                    if sugg and buf.startswith("/"):
                        pick(1 if val == "down" else -1)
                    elif history:
                        if val == "up" and hist_i > 0:
                            if hist_i == len(history):
                                draft = buf
                            hist_i -= 1
                            buf = history[hist_i]; pos = len(buf)
                        elif val == "down" and hist_i < len(history):
                            hist_i += 1
                            buf = history[hist_i] if hist_i < len(history) else draft
                            pos = len(buf)
                        sugg, sel, self._hint = [], -1, ""
                elif val == "redraw":
                    self._layout(clear=False)
                draw()
        finally:
            self._hint = ""
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
            with self.lock:
                self.real.write(f"\033[{rin};1H\033[2K{c('❯ ', BOLD, ACCENT)}\0338")
                self.real.flush()
            self.draw_status()
        return buf

    def _sugg_line(self, sugg, sel) -> str:
        w = self.cols - 4
        names = [s[0] for s in sugg]
        if sel >= 0:
            meta = sugg[sel][1]
            tail = c("  — " + meta, GREY) if meta else ""
        else:
            tail = c("   Tab ⇥", GREY)
        parts, used = [], 0
        order = list(range(len(names)))
        if sel > 5:  # Auswahl sichtbar halten
            order = order[sel - 5:]
        for k in order:
            n = names[k]
            if used + len(n) + 2 > w - vlen(tail) - 6 and parts:
                parts.append(c("…", GREY))
                break
            parts.append(c(n, ACCENT, BOLD, "\033[7m") if k == sel else c(n, ACCENT))
            used += len(n) + 2
        return "  ".join(parts) + tail

    def _draw_hint(self) -> None:
        # Vorschlagsleiste in der Statusleiste anzeigen (oder Status zurück)
        top, bot, r1, rin, r2, rst = self._geom()
        if self._hint:
            self.real.write(f"\033[{rst};1H\033[2K {clip(self._hint, self.cols - 2)}")
        else:
            self.draw_status(restore=False)

    # ── Einzeltaste (Rückfragen) ─────────────────────────────────────
    def getkey(self) -> str:
        fd, old = self._raw()
        try:
            for kind, val in self._read_keys(fd):
                if kind == "text":
                    return val[0]
                if kind == "key":
                    return {"enter": "\n", "esc": "\x1b", "ctrl_c": "\x03"}.get(val, "")
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        return ""

    # ── Esc unterbricht den laufenden Zug ────────────────────────────
    def watch_start(self) -> None:
        if not self.active or getattr(self, "_w", None):
            return
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        new = termios.tcgetattr(fd)
        new[3] &= ~(termios.ECHO | termios.ICANON)   # ISIG bleibt: Ctrl+C geht weiter
        new[6][termios.VMIN] = 1
        new[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSADRAIN, new)
        stop = threading.Event()

        def run():
            while not stop.is_set():
                try:
                    if select.select([fd], [], [], 0.1)[0] and not stop.is_set():
                        d = os.read(fd, 64)
                        if d == b"\x1b":
                            os.kill(os.getpid(), signal.SIGINT)
                except (OSError, ValueError):
                    return

        t = threading.Thread(target=run, daemon=True)
        t.start()
        self._w = (fd, old, stop, t)

    def watch_stop(self) -> None:
        w = getattr(self, "_w", None)
        if not w:
            return
        fd, old, stop, t = w
        stop.set()
        t.join(timeout=0.5)
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        try:
            termios.tcflush(fd, termios.TCIFLUSH)
        except Exception:
            pass
        self._w = None


def c(text: str, *codes: str) -> str:
    return "".join(codes) + str(text) + RST


SCREEN = Screen()
