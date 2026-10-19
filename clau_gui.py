#!/usr/bin/env python3
"""
clau_gui.py — Grafisches Steuerpanel für clau (tkinter, nur Standardbibliothek).

Start über `clau --gui` oder direkt `python3 clau_gui.py [--dir <pfad>] [--no-launch]`.

Die GUI ist eine dünne Schicht: Sie liest die Konfiguration und die Session-Liste
aus clau.sh (bzw. den Sidecar-Dateien) und führt Aktionen über die nicht-interaktiven
clau-Flags aus. Die Kernlogik bleibt in clau.sh (Single Source of Truth).

Bereiche:
  * Config-Leiste   aktueller Ordner + Zusammenfassung (Modell, Engine, Autonomie, Team, Websuche)
  * Modellwahl      Presets (Claude + owl) + Qwen-Optionen + freies Feld → clau --set-model
  * Session-Tabelle Hier/Alle, Aktionen: Neu, Fortsetzen, Umbenennen, Export, Löschen, tmux fixieren
  * tmux-Panel      tmux ls + Anbinden / Beenden
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

import tkinter as tk
from tkinter import ttk, messagebox, simpledialog

# ── Modell-Presets (spiegeln model_from_number / OWL_PRESETS in clau.sh) ──────
# (Anzeige, --set-model-Spec)
CLAUDE_PRESETS = [
    ("1 · haiku", "haiku"),
    ("2 · sonnet", "sonnet"),
    ("3 · opus", "opus"),
    ("4 · fable", "fable"),
]
OWL_PRESETS = [
    ("5 · owl:120 (PropellerA lokal)", "owl:120"),
    ("6 · owl:121 (Qwen3.8-Flash 97k)", "owl:121"),
    ("7 · owl:126 (Qwen3.8-Flash 262k)", "owl:126"),
    ("8 · owl:129 (Qwen3.8-35B-A3B 32k)", "owl:129"),
    ("0 · owl:free (Router gratis)", "owl:free"),
]
QWEN_PRESETS = [
    ("qwen3.8-max (Standard, 1M)", "qwen:qwen3.8-max"),
    ("qwen3.8-flash (schnell, 1M)", "qwen:qwen3.8-flash"),
    ("qwen3.7-max (Vorgänger Max)", "qwen:qwen3.7-max"),
    ("qwen3.7-plus", "qwen:qwen3.7-plus"),
    ("qwen3.6-flash", "qwen:qwen3.6-flash"),
    ("deepseek-v4-pro", "qwen:deepseek-v4-pro"),
    ("deepseek-v4.1-flash", "qwen:deepseek-v4.1-flash"),
    ("glm-5.3", "qwen:glm-5.3"),
    ("glm-5.2", "qwen:glm-5.2"),
    ("auto", "qwen:auto"),
]
ALL_PRESETS = CLAUDE_PRESETS + OWL_PRESETS + QWEN_PRESETS

# ── Konfig-Schlüssel, die die GUI in der Leiste anzeigt ───────────────────────
DISPLAY_KEYS = {
    "CLAU_MODEL": "Modell",
    "CLAU_BACKEND": "Engine",
    "CLAU_QWEN_MODEL": "Qwen-Modell",
    "CLAU_INTERACTION_LEVEL": "Autonomie",
    "CLAU_TEAM": "Team",
    "CLAU_WEBSEARCH": "Websuche",
    "CLAU_TMUX": "tmux",
}


def _clau_bin():
    """Pfad zu clau.sh (neben diesem Skript) oder 'clau' aus dem PATH."""
    here = os.path.dirname(os.path.abspath(__file__))
    cand = os.path.join(here, "clau.sh")
    if os.path.isfile(cand):
        return cand
    return "clau"


def _conf_file(d):
    """Konfig-Datei für Ordner d: .clau.conf oder XDG-Fallback."""
    local = os.path.join(d, ".clau.conf")
    if os.path.isfile(local):
        return local
    xdg = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    slug = "".join(c if c.isalnum() else "_" for c in os.path.abspath(d))
    return os.path.join(xdg, "clau", "dirs", slug + ".conf")


def _load_config(d):
    """Key="Value"-Datei zu dict parsen (leer bei Fehlschlag)."""
    path = _conf_file(d)
    out = {}
    if not os.path.isfile(path):
        return out
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip().strip('"')
    except Exception:
        pass
    return out


def _run_clau(args, cwd, timeout=60):
    """clau mit Argumenten ausführen, (stdout, stderr, returncode) zurückgeben."""
    try:
        p = subprocess.run([_clau_bin()] + list(args), cwd=cwd,
                           capture_output=True, text=True, timeout=timeout)
        return p.stdout or "", p.stderr or "", p.returncode
    except subprocess.TimeoutExpired:
        return "", "Zeitüberschreitung", 124
    except Exception as e:
        return "", str(e), 1


def _tmux_list():
    """tmux ls parsen → Liste von dicts (name, attached, created, path, cmd)."""
    try:
        p = subprocess.run(
            ["tmux", "ls", "-F",
             "#{session_name}|#{session_attached}|#{session_created}|"
             "#{pane_current_path}|#{pane_current_command}"],
            capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    rows = []
    for line in (p.stdout or "").splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) < 5:
            parts += [""] * (5 - len(parts))
        name, attached, created, path, cmd = (x.strip() for x in parts[:5])
        rows.append({"name": name, "attached": attached,
                     "created": created, "path": path, "cmd": cmd})
    return rows


def _launch_terminal(cmd, cwd):
    """
    clau in einem neuen Terminal-Fenster starten (erkennt Emulator).
    Fallback: tmux new-session -d. Gibt True bei Erfolg.
    """
    env_disp = os.environ.get("DISPLAY", "")
    candidates = [
        (["gnome-terminal", "--"], "gnome-terminal"),
        (["konsole", "-e"], "konsole"),
        (["xfce4-terminal", "-e"], "xfce4-terminal"),
        (["xterm", "-e"], "xterm"),
    ]
    for args, _ in candidates:
        if shutil.which(args[0]):
            full = args + [cmd]
            try:
                subprocess.Popen(full, cwd=cwd,
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
                return True
            except Exception:
                continue
    # Fallback: tmux
    if shutil.which("tmux"):
        name = "clau-gui-%d" % int(time.time())
        try:
            subprocess.Popen(
                ["tmux", "new-session", "-d", "-s", name, cmd], cwd=cwd,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except Exception:
            pass
    if not env_disp:
        return False
    return False


class ClauGui:
    def __init__(self, root, base_dir, no_launch):
        self.root = root
        self.base_dir = os.path.abspath(base_dir)
        self.no_launch = no_launch
        self.scope = "here"
        self.sessions = []          # Liste von dicts (aus --sessions-json)
        self._build()
        self.refresh()

    # ── Aufbau ────────────────────────────────────────────────────────────
    def _build(self):
        self.root.title("clau — Steuerpanel")
        self.root.geometry("980x620")
        self.root.minsize(760, 480)

        root = ttk.Frame(self.root, padding=8)
        root.pack(fill="both", expand=True)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(4, weight=1)

        # --- Config-Leiste ---
        cfg = ttk.LabelFrame(root, text="Konfiguration", padding=8)
        cfg.grid(row=0, column=0, sticky="ew", pady=(0, 6))
        cfg.columnconfigure(1, weight=1)
        self.dir_var = tk.StringVar()
        ttk.Label(cfg, text="Ordner:").grid(row=0, column=0, sticky="w")
        ttk.Entry(cfg, textvariable=self.dir_var, width=60).grid(
            row=0, column=1, sticky="ew", padx=4)
        self.cfg_summary = tk.StringVar(value="")
        ttk.Label(cfg, textvariable=self.cfg_summary, wraplength=900,
                  justify="left").grid(row=1, column=0, columnspan=2,
                                       sticky="w", pady=(4, 0))

        # --- Modellwahl ---
        mod = ttk.LabelFrame(root, text="Modell", padding=8)
        mod.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        mod.columnconfigure(1, weight=1)
        ttk.Label(mod, text="Preset:").grid(row=0, column=0, sticky="w")
        self.model_var = tk.StringVar()
        self.model_box = ttk.Combobox(mod, textvariable=self.model_var, width=44,
                                      values=[label for label, _ in ALL_PRESETS])
        self.model_box.grid(row=0, column=1, sticky="w", padx=4)
        self.model_box.current(0)
        self.model_free = tk.StringVar()
        ttk.Label(mod, text="Frei (z.B. owl:99):").grid(row=1, column=0, sticky="w", pady=(4, 0))
        ttk.Entry(mod, textvariable=self.model_free, width=44).grid(
            row=1, column=1, sticky="w", padx=4, pady=(4, 0))
        ttk.Button(mod, text="Modell speichern",
                   command=self.on_set_model).grid(row=0, column=2, sticky="e", padx=4)

        # --- Session-Tabelle ---
        sess = ttk.LabelFrame(root, text="Sessions", padding=6)
        sess.grid(row=2, column=0, sticky="ew", pady=(0, 6))
        sess.columnconfigure(0, weight=1)
        sess.rowconfigure(1, weight=1)

        scope = ttk.Frame(sess)
        scope.grid(row=0, column=0, sticky="w")
        self.scope_var = tk.StringVar(value="Hier")
        ttk.Radiobutton(scope, text="Hier", value="here",
                        variable=self.scope_var, command=self.refresh_sessions).pack(side="left")
        ttk.Radiobutton(scope, text="Alle", value="all",
                        variable=self.scope_var, command=self.refresh_sessions).pack(side="left", padx=(12, 0))
        ttk.Button(scope, text="⟳ Aktualisieren", command=self.refresh_sessions).pack(side="right")

        cols = ("name", "cwd", "model", "mtime", "tokens")
        self.tree = ttk.Treeview(sess, columns=cols, show="headings", height=10)
        for cid, txt, w, anchor in [
            ("name", "Name", 260, "w"),
            ("cwd", "Ordner", 240, "w"),
            ("model", "Modell", 120, "w"),
            ("mtime", "Zuletzt", 130, "w"),
            ("tokens", "Tokens", 80, "e"),
        ]:
            self.tree.heading(cid, text=txt)
            self.tree.column(cid, width=w, anchor=anchor, stretch=(cid in ("name", "cwd")))
        self.tree.grid(row=1, column=0, sticky="nsew")
        sb = ttk.Scrollbar(sess, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        sb.grid(row=1, column=1, sticky="ns")
        self.tree.bind("<Double-1>", lambda e: self.on_resume())

        # --- Session-Aktionen ---
        acts = ttk.Frame(sess)
        acts.grid(row=2, column=0, columnspan=2, sticky="w", pady=(6, 0))
        ttk.Button(acts, text="Neue Session", command=self.on_new).pack(side="left")
        ttk.Button(acts, text="Fortsetzen", command=self.on_resume).pack(side="left", padx=4)
        ttk.Button(acts, text="Umbenennen", command=self.on_rename).pack(side="left")
        ttk.Button(acts, text="Export .md", command=self.on_export).pack(side="left", padx=4)
        ttk.Button(acts, text="tmux fixieren", command=self.on_tmux_pin).pack(side="left")
        ttk.Button(acts, text="Löschen", command=self.on_delete).pack(side="left")

        # --- tmux-Panel ---
        tm = ttk.LabelFrame(root, text="tmux-Sitzungen", padding=6)
        tm.grid(row=3, column=0, sticky="ew", pady=(0, 6))
        tm.columnconfigure(0, weight=1)
        tm.rowconfigure(1, weight=1)
        self.tmux_tree = ttk.Treeview(tm, columns=("attached", "path", "cmd"),
                                      show="headings", height=4)
        for cid, txt, w in [("name", "Name", 220), ("attached", "Angebunden", 90),
                            ("path", "Ordner", 360), ("cmd", "Prozess", 220)]:
            self.tmux_tree.heading(cid, text=txt)
            self.tmux_tree.column(cid, width=w, anchor="w")
        self.tmux_tree.grid(row=1, column=0, sticky="nsew")
        tmsb = ttk.Scrollbar(tm, orient="vertical", command=self.tmux_tree.yview)
        self.tmux_tree.configure(yscrollcommand=tmsb.set)
        tmsb.grid(row=1, column=1, sticky="ns")
        ttk.Button(tm, text="tmux aktualisieren", command=self.refresh_tmux).grid(
            row=0, column=0, sticky="w")
        ttk.Button(tm, text="Anbinden (attach)", command=self.on_tmux_attach).grid(
            row=0, column=1, sticky="e", padx=4)
        ttk.Button(tm, text="Beenden (kill)", command=self.on_tmux_kill).grid(
            row=0, column=2, sticky="e")

        # --- Statuszeile ---
        self.status = tk.StringVar(value="Bereit.")
        ttk.Label(root, textvariable=self.status, foreground="#555").grid(
            row=4, column=0, sticky="w", pady=(4, 0))

    # ── Refresh ───────────────────────────────────────────────────────────
    def refresh(self):
        self.refresh_config()
        self.refresh_sessions()
        self.refresh_tmux()

    def refresh_config(self):
        self.dir_var.set(self.base_dir)
        cfg = _load_config(self.base_dir)
        bits = []
        for key, label in DISPLAY_KEYS.items():
            if key in cfg and cfg[key] != "":
                bits.append("%s: %s" % (label, cfg[key]))
        if bits:
            self.cfg_summary.set("  ·  ".join(bits))
        else:
            self.cfg_summary.set("Keine Konfiguration für diesen Ordner (.clau.conf).")

    def refresh_sessions(self):
        self.scope = self.scope_var.get()
        out, err, rc = _run_clau(["--sessions-json", self.scope], self.base_dir)
        self.sessions = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                self.sessions.append(json.loads(line))
            except Exception:
                continue
        self.tree.delete(*self.tree.get_children())
        for s in self.sessions:
            self.tree.insert("", "end", iid=s.get("sid", ""), values=(
                s.get("name") or "(ohne Titel)", s.get("cwd", ""),
                s.get("model") or "—", s.get("mtime", ""), s.get("tokens", 0)))
        if rc != 0 and not self.sessions:
            self.status.set("Session-Scan: " + (err.strip() or "leere Liste"))
        else:
            self.status.set("%d Session(en) (%s)." % (len(self.sessions), self.scope))

    def refresh_tmux(self):
        self.tmux_tree.delete(*self.tmux_tree.get_children())
        for row in _tmux_list():
            self.tmux_tree.insert("", "end", iid=row["name"], values=(
                row["name"], "ja" if row["attached"] == "1" else "nein",
                row["path"], row["cmd"]))

    # ── Auswahl-Hilfen ────────────────────────────────────────────────────
    def _selected_session(self):
        sel = self.tree.selection()
        if not sel:
            messagebox.showinfo("clau", "Keine Session ausgewählt.")
            return None
        sid = sel[0]
        for s in self.sessions:
            if s.get("sid") == sid:
                return s
        return None

    def _selected_tmux(self):
        sel = self.tmux_tree.selection()
        if not sel:
            messagebox.showinfo("clau", "Keine tmux-Sitzung ausgewählt.")
            return None
        return sel[0]

    # ── Aktionen ──────────────────────────────────────────────────────────
    def on_set_model(self):
        free = self.model_free.get().strip()
        if free:
            spec = free
        else:
            spec = ALL_PRESETS[self.model_box.current()][1]
        out, err, rc = _run_clau(["--set-model", spec], self.base_dir)
        if rc == 0:
            self.status.set("Modell gespeichert: " + spec)
            self.refresh_config()
        else:
            messagebox.showerror("clau", "Modell konnte nicht gesetzt werden:\n" +
                                 (err.strip() or out.strip() or "unbekannter Fehler"))

    def on_new(self):
        if self.no_launch:
            self.status.set("[no-launch] Neue Session in %s" % self.base_dir)
            return
        if _launch_terminal(_clau_bin(), self.base_dir):
            self.status.set("Neue clau-Session gestartet in %s" % self.base_dir)
        else:
            self.status.set("Kein Terminal-Fenster verfügbar (DISPLAY/tmux fehlt).")

    def on_resume(self):
        s = self._selected_session()
        if not s:
            return
        sid = s["sid"]
        cwd = s.get("cwd") or self.base_dir
        if self.no_launch:
            self.status.set("[no-launch] Fortsetzen %s in %s" % (sid, cwd))
            return
        if _launch_terminal(_clau_bin() + " --resume " + sid, cwd):
            self.status.set("Session fortgesetzt: %s" % (s.get("name") or sid))
        else:
            self.status.set("Kein Terminal-Fenster verfügbar (DISPLAY/tmux fehlt).")

    def on_rename(self):
        s = self._selected_session()
        if not s:
            return
        new = simpledialog.askstring("Umbenennen", "Neuer Name:", parent=self.root)
        if not new:
            return
        out, err, rc = _run_clau(["--rename", s["sid"], new],
                                 s.get("cwd") or self.base_dir)
        if rc == 0:
            self.status.set("Umbenannt: " + new)
            self.refresh_sessions()
        else:
            messagebox.showerror("clau", "Umbenennen fehlgeschlagen:\n" +
                                 (err.strip() or out.strip()))

    def on_export(self):
        s = self._selected_session()
        if not s:
            return
        out, err, rc = _run_clau(["--export-md", s["sid"]],
                                 s.get("cwd") or self.base_dir)
        if rc == 0:
            self.status.set("Export: " + (out.strip() or "erledigt"))
        else:
            messagebox.showerror("clau", "Export fehlgeschlagen:\n" +
                                 (err.strip() or out.strip()))

    def on_tmux_pin(self):
        s = self._selected_session()
        if not s:
            return
        # Status aus Meta-Datei abfragen, dann umschalten
        bdir = self._projects_dir_for(s.get("cwd") or self.base_dir)
        meta = os.path.join(bdir, ".clau-session-meta.json")
        on = False
        if os.path.isfile(meta):
            try:
                d = json.load(open(meta))
                on = bool(d.get(s["sid"], {}).get("tmux", False))
            except Exception:
                on = False
        new = "off" if on else "on"
        out, err, rc = _run_clau(["--tmux-pin", s["sid"], new],
                                 s.get("cwd") or self.base_dir)
        if rc == 0:
            self.status.set("tmux %s: %s" % ("fixiert" if new == "on" else "gelöst",
                                             s.get("name") or s["sid"]))
        else:
            messagebox.showerror("clau", "tmux-Pin fehlgeschlagen:\n" +
                                 (err.strip() or out.strip()))

    def on_delete(self):
        s = self._selected_session()
        if not s:
            return
        if not messagebox.askyesno("Löschen",
                                   "Session wirklich löschen?\n\n" +
                                   (s.get("name") or s["sid"]) +
                                   "\n(" + s["sid"] + ")\n\nUnwiderruflich."):
            return
        out, err, rc = _run_clau(["--delete-session", s["sid"]],
                                 s.get("cwd") or self.base_dir)
        if rc == 0:
            self.status.set("Session gelöscht: " + (s.get("name") or s["sid"]))
            self.refresh_sessions()
        else:
            messagebox.showerror("clau", "Löschen fehlgeschlagen:\n" +
                                 (err.strip() or out.strip()))

    def on_tmux_attach(self):
        name = self._selected_tmux()
        if not name:
            return
        if self.no_launch:
            self.status.set("[no-launch] tmux attach " + name)
            return
        if _launch_terminal("tmux attach -t " + name, self.base_dir):
            self.status.set("tmux angehängt: " + name)
        else:
            self.status.set("Kein Terminal-Fenster verfügbar (DISPLAY/tmux fehlt).")

    def on_tmux_kill(self):
        name = self._selected_tmux()
        if not name:
            return
        if not messagebox.askyesno("tmux beenden",
                                   "tmux-Sitzung beenden?\n\n" + name):
            return
        subprocess.run(["tmux", "kill-session", "-t", name],
                       capture_output=True, text=True)
        self.refresh_tmux()
        self.status.set("tmux beendet: " + name)

    # ── Hilfen ────────────────────────────────────────────────────────────
    @staticmethod
    def _projects_dir_for(cwd):
        base = os.path.expanduser("~/.claude/projects")
        slug = "".join(c if c == "-" or c.isalnum() else "-" for c in os.path.abspath(cwd))
        return os.path.join(base, slug)


def main():
    ap = argparse.ArgumentParser(description="clau GUI (tkinter)")
    ap.add_argument("--dir", default=os.getcwd(), help="Projektordner (Standard: PWD)")
    ap.add_argument("--no-launch", action="store_true",
                    help="Terminal-Start nur simulieren (Testen)")
    args = ap.parse_args()

    try:
        root = tk.Tk()
    except tk.TclError as e:
        sys.stderr.write("Fehler: tkinter benötigt ein Display (DISPLAY gesetzt?).\n"
                         "Details: %s\n" % e)
        sys.exit(1)
    ClauGui(root, args.dir, args.no_launch)
    root.mainloop()


if __name__ == "__main__":
    main()
