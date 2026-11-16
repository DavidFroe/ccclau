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
_TOK = re.compile(r"\033\[[0-9;?<>]*[A-Za-z~]|\033[()][A-Za-z0-9]|\033[78=>]|\033|\r|\n|\t|[^\033\r\n\t]+")


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

    def __init__(self, real, lock, record=None):
        self._real = real
        self._lock = lock
        self._record = record

    def write(self, s):
        with self._lock:
            r = self._real.write(s)
            if self._record is not None:
                try:
                    self._record(s)
                except Exception:
                    pass
            return r

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
        self.turn_t0: float | None = None    # Beginn des ganzen Zugs (Prefill, Denken, Tools, Antwort): der Zähler läuft durch
        self.out_chars = 0
        self.ctx_used = lambda: 0
        self.ctx_max = 200_000
        self._ticker: threading.Thread | None = None
        self._tick_stop = threading.Event()
        self._hint = ""          # Vorschlagsleiste (ersetzt kurz die Statusleiste)
        self._old_winch = None
        self.queue: list[str] = []     # während der Arbeit eingetippte Nachrichten (Warteschlange)
        self._typed = ""               # angefangener, noch nicht abgeschickter Text
        self.cmds: list[str] = []      # Befehle (/…, exit), die den Zug beenden und als Nächstes laufen (nicht in der Warteschlange)
        self.live_cmd = None           # von cli gesetzt: führt einen Schrägstrich-Befehl sofort aus → "done" | "defer" | Prompt-Text
        self.hist: list[str] = [""]   # alles, was in die Scroll-Region geschrieben wurde (für PgUp)
        self._cr = False

    # ── Aufbau ───────────────────────────────────────────────────────
    def _size(self) -> None:
        sz = shutil.get_terminal_size((100, 30))
        self.cols, self.rows = max(40, sz.columns), sz.lines

    def build_header(self) -> list[str]:
        i = self.info
        w = self.cols - 1
        bl = lambda s: c(s, BOLD)  # noqa: E731
        mascot = [c(PROPELLER[0], ACCENT), c(PROPELLER[1], ACCENT, BOLD), c(PROPELLER[2], ACCENT)]
        sess = os.environ.get("NANO_SESSION_NAME", "").strip() or i.get("session") or ""
        folder = i.get("folder", "")
        l1 = c("nano", BOLD, ACCENT) + c("  ·  PropellerA  ·  Claude-Code-Nachbau", GREY)
        l2 = c("/help", ACCENT) + c(" for help  ·  ", GREY) + c("/tools", ACCENT) + c(" for tools (on/off in clau: menu x)", GREY)
        l3 = c(folder, GREY) + (c("  ·  ", GREY) + sess if sess else "")
        rows = [" " + mascot[0] + "  " + l1, " " + mascot[1] + "  " + l2, " " + mascot[2] + "  " + l3]
        tools = i.get("tools") or []
        skills = i.get("skills") or []
        if self.rows >= 26:
            rows.extend(" " + r for r in self._tool_rows(tools, w))
            if skills:
                rows.append(" " + self._list("skills", skills, w))
            # Worum geht es in dieser Session: Beginn und letzte Nutzer-Nachricht (von clau)
            for lab, key in (("start  ", "NANO_SESSION_START"), ("zuletzt", "NANO_SESSION_LAST")):
                v = os.environ.get(key, "").strip()
                if v:
                    rows.append(" " + c(lab + " ", GREY) + c(v, DIM))
            gu = os.environ.get("NANO_GITEA_URL", "").strip()
            if gu:
                gf = os.environ.get("NANO_GITEA_FORK_URL", "").strip()
                rows.append(" " + c("gitea  ", GREY) + c(gu, ACCENT)
                            + ((c("  ·  fork ", GREY) + c(gf, ACCENT)) if gf else ""))
            if i.get("resumed"):
                rows.append(" " + c("resumed ", GREY) + c(i["resumed"], AMBER))
        else:
            rows.append(" " + c(f"tools {len(tools)}" + (f" · skills {len(skills)}" if skills else ""), GREY))
        rows.append(c("─" * w, GREY))
        return [clip(r, w) for r in rows]

    def _tool_rows(self, tools: list[str], width: int, max_rows: int = 3) -> list[str]:
        """Tools in höchstens max_rows Zeilen: erst die eingebauten, dann je MCP-Server 'name(Anzahl)'; Rest als '+N · /tools'."""
        builtin = [t for t in tools if not t.startswith("mcp__")]
        servers: dict[str, int] = {}
        for t in tools:
            if t.startswith("mcp__"):
                parts = t.split("__")
                srv = parts[1] if len(parts) >= 3 else t[5:]
                servers[srv] = servers.get(srv, 0) + 1
        room = width - 2

        def pack(label, cnt, items, rows_allowed):
            """items = [(text, sichtbare Länge)] → (zeilen, übrig)"""
            head = c(label + " ", GREY) + c(cnt + " ", DIM)
            hl = len(label) + len(cnt) + 2
            rows, cur, used, first = [], head, hl, True
            for k, (txt, ln) in enumerate(items):
                if used + ln + 3 > room and not first:
                    if len(rows) + 1 >= rows_allowed:
                        rows.append(cur)
                        return rows, len(items) - k
                    rows.append(cur)
                    cur, used, first = c(" " * 7, GREY), 7, True
                cur += ("" if first else c(" · ", GREY)) + txt
                used += ln + (0 if first else 3)
                first = False
            rows.append(cur)
            return rows, 0

        b_items = [(c(n, ACCENT), len(n)) for n in builtin]
        out: list[str] = []
        left = 0
        b_rows, b_left = pack("tools", f"({len(builtin)})", b_items, max_rows - (1 if servers else 0))
        out += b_rows
        left += b_left
        if servers:
            m_items = [(c(k, ACCENT) + c(f"({v})", GREY), len(k) + len(str(v)) + 2) for k, v in servers.items()]
            m_rows, m_left = pack("mcp  ", f"({len(servers)} Server, {sum(servers.values())} Tools)", m_items,
                                  max_rows - len(out))
            out += m_rows
            left += m_left
        if left:
            out[-1] += c(f"  +{left} · /tools", AMBER)
        return out[:max_rows]

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
        sys.stdout = _Out(self.real, self.lock, self._record)
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
            self._last_status = None
            w(f"\033[{top};{bot}r\033[{top if clear else bot};1H")
            self.real.flush()
        self.draw_status()
        if clear and (len(self.hist) > 1 or self.hist[0]):
            self._repaint_region()      # nach Resize/Neuzeichnen den Verlauf wiederherstellen (sonst bleibt der Bereich leer)
        if self.queue or self._typed:
            self._draw_typeahead()

    def _resize(self) -> None:
        if not self.active:
            return
        self._layout(clear=True)

    # ── Verlauf zum Zurückblättern (tmux/Terminal behalten bei fester Eingabezeile keinen Scrollback) ──
    def _record(self, s: str) -> None:
        h = self.hist
        for m in _TOK.finditer(s):
            t = m.group(0)
            if t == "\n":
                h.append(""); self._cr = False
            elif t == "\r":
                self._cr = True
            elif t == "\t":
                h[-1] += "    "
            elif t[0] == "\033":
                if len(t) > 2 and t.endswith("m") and t[1] == "[":
                    h[-1] += t
                elif len(t) > 2 and t.endswith("K") and self._cr:
                    h[-1] = ""
            else:
                if self._cr:
                    h[-1] = ""; self._cr = False
                h[-1] += t
        if len(h) > 6000:
            del h[:1000]

    @staticmethod
    def _wrap(line: str, width: int) -> list[str]:
        rows, cur, n, sgr, i = [], "", 0, "", 0
        while i < len(line):
            m = _ANSI.match(line, i)
            if m:
                code = m.group(0)
                cur += code
                if code.endswith("m"):
                    sgr = "" if code in ("\033[0m", "\033[m") else sgr + code
                i = m.end(); continue
            cur += line[i]; n += 1; i += 1
            if n >= width:
                rows.append(cur + RST); cur, n = sgr, 0
        rows.append(cur + RST if cur else "")
        return rows

    def _repaint_region(self) -> None:
        off_hint = self._hint
        self.view_scroll(0)
        self._hint = off_hint
        with self.lock:
            top, bot, *_ = self._geom()
            self.real.write(f"\033[{bot};1H")      # Ausgabe geht am unteren Rand der Region weiter
            self.real.flush()

    def view_scroll(self, off: int) -> int:
        """Die Scroll-Region aus dem Verlauf neu zeichnen, `off` Zeilen über dem Ende. Gibt das begrenzte off zurück."""
        with self.lock:
            top, bot, *_ = self._geom()
            height = bot - top + 1
            rows: list[str] = []
            for ln in self.hist[-1500:]:
                rows.extend(self._wrap(ln, self.cols - 1))
            off = max(0, min(off, max(0, len(rows) - height)))
            start = max(0, len(rows) - height - off)
            chunk = rows[start:start + height]
            w = self.real.write
            for k in range(height):
                w(f"\033[{top + k};1H\033[2K{chunk[k] if k < len(chunk) else ''}")
            self._hint = (c(f"↑ Verlauf: noch {off} Zeilen darunter", AMBER) + c("  ·  PgUp/PgDn blättern · Home Anfang · End/Enter/Esc zurück", GREY)) if off else ""
            self.real.flush()
        return off

    # ── Statusleiste ─────────────────────────────────────────────────
    def set_state(self, state: str) -> None:
        if state != self.state:
            self.state = state
            self.state_t0 = time.monotonic()
            if state == "idle":
                self.turn_t0 = None
            elif self.turn_t0 is None:           # erster Nicht-Leerlauf-Zustand = Zugbeginn
                self.turn_t0 = self.state_t0
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
        el = int(time.monotonic() - (self.turn_t0 or self.state_t0))
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
        extra = f" {el // 60}:{el % 60:02d}" if el >= 60 else f" {el}s"
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
            # überschreiben statt erst die Zeile zu löschen (sonst flackert die Leiste); Rest danach leeren
            body = f"\033[{rst};1H{clip(line, w + 1)}\033[K"
            if line == getattr(self, "_last_status", None) and restore:
                return          # unverändert: nichts neu zeichnen
            self._last_status = line
            # Cursor während des Zeichnens verbergen und als eine Einheit ausgeben (Synchronized Output, falls unterstützt):
            # sonst springt der Cursor sichtbar zwischen Eingabe/Verlauf und Statusleiste
            self.real.write(f"\033[?2026h\033[?25l\0337{body}\0338\033[?25h\033[?2026l" if restore else body)
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
                            "1~": "home", "4~": "end", "7~": "home", "8~": "end", "3~": "delete", "5~": "pgup", "6~": "pgdn",
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
        if self.cmds:        # Befehl, der den Zug beendet hat (z.B. exit, /clear): zuerst ausführen
            return self.cmds.pop(0)
        if self.queue:       # in der Wartezeit Eingetipptes: alles zusammen als ein Auftrag abarbeiten
            txt = "\n\n".join(self.queue)
            self.queue = []
            self._draw_typeahead()
            return txt
        fd, old = self._raw()
        buf, pos = self._typed, len(self._typed)
        self._typed = ""
        hist_i = len(history)
        draft = ""
        sugg: list[tuple[str, str]] = []   # (neuer Text, Meta)
        sel = -1
        base = ""
        pt = []                            # Zwischenspeicher für Tastenfolge
        vo = 0                             # Blätter-Offset (0 = live)
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
                if vo or val in ("pgup", "pgdn"):
                    # Blättermodus: PgUp/PgDn/Home/End; jede andere Taste kehrt zum Live-Verlauf zurück
                    top_, bot_, *_r = self._geom()
                    step = max(3, (bot_ - top_) // 2)
                    if val == "pgup":
                        vo += step
                    elif val == "pgdn":
                        vo -= step
                    elif val == "home":
                        vo = 10 ** 6
                    elif vo:
                        vo = 0
                        self._hint = ""; self.view_scroll(0); draw()
                        continue
                    vo = self.view_scroll(max(0, vo))
                    draw()
                    continue
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
            self._last_status = None
            self.real.write(f"\033[{rst};1H {clip(self._hint, self.cols - 2)}\033[K")
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

    # ── Während der Arbeit: Esc unterbricht, Tippen füllt die Warteschlange ────
    def _draw_typeahead(self) -> None:
        """Eingabezeile mit dem angefangenen Text und die Warteschlange (grau) auf der Linie darüber zeichnen."""
        if not self.active:
            return
        with self.lock:
            top, bot, r1, rin, r2, rst = self._geom()
            avail = self.cols - 4
            if self.queue:
                items = "  ·  ".join(f"{k + 1}) {q.splitlines()[0] if q else ''}" for k, q in enumerate(self.queue))
                head = f"─ ⏎ in der Warteschlange ({len(self.queue)}): "
                line = clip(c(head + items + " ", GREY), self.cols - 2)
                line += c("─" * max(0, self.cols - 1 - vlen(line)), GREY)
            else:
                line = c("─" * (self.cols - 1), GREY)
            vis = self._typed.replace("\n", "↵")[-avail:]
            self.real.write(f"\033[?25l\0337\033[{r1};1H\033[2K{line}\033[{rin};1H\033[2K{c('❯ ', BOLD, ACCENT)}{vis}\0338\033[?25h")
            self.real.flush()

    def _ta_feed(self, data: bytes) -> bool:
        """Tasten aus der Wartezeit verarbeiten. True = Esc (Abbruch) erkannt."""
        if data == b"\x1b":
            return True
        data = data.replace(b"\x1b[200~", b"").replace(b"\x1b[201~", b"")
        changed = False
        text = []
        i = 0
        while i < len(data):                      # Escape-Folgen (Pfeile, PgUp, …) überspringen
            if data[i] == 0x1b:
                j = i + 2
                while j < len(data) and not (0x40 <= data[j] <= 0x7e):
                    j += 1
                i = j + 1
                continue
            text.append(data[i]); i += 1
        interrupt = False
        for ch in bytes(text).decode("utf-8", "ignore"):
            if ch in "\r\n":
                line = self._typed.strip()
                self._typed = ""; changed = True
                if line:
                    low = line.lower()
                    is_cmd = line.startswith("/") or low in ("exit", "quit", ":q")
                    if is_cmd and self.live_cmd is not None:
                        # Befehle nie in die Warteschlange: sofort ausführen, oder (wenn sie den Zug anfassen) Zug beenden und als Nächstes laufen
                        try:
                            res = self.live_cmd(line if line.startswith("/") else "/exit")
                        except Exception as e:      # noqa: BLE001
                            res = "done"
                            self.real.write(f"\n  [Befehl fehlgeschlagen: {type(e).__name__}: {e}]\n")
                        if res == "defer":
                            self.cmds.append(line)
                            interrupt = True
                        elif res != "done":
                            self.queue.append(str(res))   # z.B. Skill/Review liefert einen Prompt
                    else:
                        self.queue.append(line)
            elif ch in "\x7f\x08":
                self._typed = self._typed[:-1]; changed = True
            elif ch == "\x15":
                self._typed = ""; changed = True
            elif ch >= " ":
                self._typed += ch; changed = True
        if changed:
            self._draw_typeahead()
        return interrupt

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
                        d = os.read(fd, 1024)
                        if self._ta_feed(d):
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
        try:                                           # noch ungelesene Tasten nicht verlieren
            while select.select([fd], [], [], 0)[0]:
                d = os.read(fd, 1024)
                if not d:
                    break
                self._ta_feed(d if d != b"\x1b" else b"")
        except (OSError, ValueError):
            pass
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        self._w = None


def c(text: str, *codes: str) -> str:
    return "".join(codes) + str(text) + RST


SCREEN = Screen()
