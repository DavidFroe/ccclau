#!/usr/bin/env python3
"""
matlab_mcp.py — MATLAB R2020a (Windows-VM, SSH) als optionales MCP-Werkzeug für clau.

Nur aktiv, wenn eingeschaltet: CLAU_MATLAB=1 (Umgebung/.clau.conf) oder "matlab": true im
clau --delegate-Spec. Ohne Einschalten wird dieser Server nie eingetragen.

Arbeitsordner = cwd des Laufs. VM-Ordner: C:\\arbeit\\chat_<kennung>, Kennung aus CLAU_CHAT_ID,
sonst Ordnername. Skripte laufen als "matlab.exe -batch \"cd '<ordner>'; <skript>\"" (nie Code in -batch).
Logik angelehnt an webui-werkzeug/matlab_kvm.py (dort unverändert; hier eigene Kopie der Grundfunktionen).
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

SSH_ZIEL = os.environ.get("CLAU_MATLAB_SSH", "davud@127.0.0.1")
SSH_PORT = os.environ.get("CLAU_MATLAB_PORT", "2210")
SSH_KEY = os.environ.get("CLAU_MATLAB_KEY", "/home/david/.ssh/id_ed25519_win10")
MATLAB_EXE = os.environ.get("CLAU_MATLAB_EXE", r"C:\matlab\bin\matlab.exe")
WURZEL = os.environ.get("CLAU_MATLAB_ROOT", r"C:\arbeit")
VM_DIENST = os.environ.get("CLAU_MATLAB_SERVICE", "win10-matlab.service")
ZEIT_DEFAULT = int(os.environ.get("CLAU_MATLAB_TIMEOUT", "420"))
START_ZEIT = 300
MAX_MB = 300
PROTOKOLL = os.environ.get("CLAU_MATLAB_LOG", "/home/david/Schreibtisch/Platte/matlab-tuning/fehlerlog/zugriffe.jsonl")
SPICK = Path(os.environ.get("CLAU_MATLAB_SPICK", "/home/david/Schreibtisch/Platte/matlab-toolboxen/spick"))

HIN = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff", ".gif", ".webp", ".mp4", ".avi", ".mov", ".mkv",
       ".wav", ".mp3", ".flac", ".ogg", ".m4a", ".stl", ".obj", ".ply", ".off", ".3mf", ".step", ".stp", ".pcd",
       ".csv", ".txt", ".tsv", ".xlsx", ".xls", ".json", ".xml", ".mat", ".dat", ".m", ".pdf", ".docx", ".zip",
       ".urdf", ".fasta", ".fa", ".gb"}
ZURUECK = {".png", ".mp4", ".gif", ".stl", ".obj", ".ply", ".off", ".3mf", ".pcd", ".wav", ".mp3", ".flac", ".ogg",
           ".m4a", ".csv", ".tsv", ".xlsx", ".xls", ".json", ".xml", ".mat", ".txt", ".dat", ".pdf", ".docx",
           ".html", ".zip", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".svg"}

REGELN = """MATLAB R2020a läuft im Stapelbetrieb in einer Windows-VM (Anlauf ~25 s -> lieber EIN größeres Skript als viele kleine).
- Bei Rechen-/Darstellungswünschen einfach rechnen, nicht zurückfragen.
- Variablen überleben den Aufruf nicht (save/load nutzen). Kein input/pause; kein 'clear all'/'close all' nötig. Vektorisiert rechnen.
- Grafik: figure('Visible','off'); EINE Grafik pro Figur (kein subplot-Panel); Figurgröße <= 1000x700 Pixel
  (VM-Bildschirm 1024x768: größere Figuren werden beim Speichern verzerrt, Kreise werden Ovale), mehr Pixel über 'Resolution';
  speichern mit exportgraphics(gcf,'name.png','Resolution',200) NICHT gca (Titel wird abgeschnitten);
  Legende 'Location','best'; Schrift 12/14.
- R2020a kennt viele neuere Funktionen nicht -> vor Toolbox-Code matlab_spickzettel lesen.
- Fehlermeldung ERST lesen, dann gezielt EINE Stelle ändern (nicht das ganze Skript neu schreiben).
- Ergebnisdateien (PNG, MP4, CSV, MAT, PDF ...) werden automatisch ins Arbeitsverzeichnis zurückgeholt."""


def _ssh(befehl, zeit=60):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                           "-i", SSH_KEY, "-p", SSH_PORT, SSH_ZIEL, befehl],
                          capture_output=True, text=True, errors="replace", timeout=zeit)


def _scp(quelle, ziel, zeit=900):
    return subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
                           "-i", SSH_KEY, "-P", SSH_PORT, quelle, ziel],
                          capture_output=True, text=True, errors="replace", timeout=zeit)


def _protokoll(werkzeug, art, ok, dauer=0.0, **felder):
    if not PROTOKOLL:
        return
    try:
        p = Path(PROTOKOLL)
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists() and p.stat().st_size > 20 * 1024 * 1024:
            p.replace(p.with_name(p.name + ".alt"))
        e = {"zeit": datetime.now().isoformat(timespec="seconds"), "werkzeug": werkzeug, "ok": bool(ok),
             "art": art, "chat": _kennung(), "dauer_s": round(dauer, 1), "quelle": "ccclau"}
        e.update({k: v for k, v in felder.items() if v not in (None, "", [], {})})
        with p.open("a", encoding="utf-8") as f:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _kennung():
    k = os.environ.get("CLAU_CHAT_ID") or os.path.basename(os.getcwd().rstrip("/"))
    return re.sub(r"[^A-Za-z0-9]", "", k)[:16] or "allgemein"


def _ordner():
    return f"{WURZEL}\\chat_{_kennung()}"


def _vm_name(name):
    stamm, endung = os.path.splitext(os.path.basename(name or "datei"))
    ers = {"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss"}
    stamm = "".join(ers.get(c, c) for c in stamm)
    stamm = re.sub(r"[^A-Za-z0-9_.-]", "_", stamm).strip("._") or "datei"
    return stamm[:80] + re.sub(r"[^A-Za-z0-9.]", "", endung.lower())


def _ssh_ok():
    try:
        r = _ssh("echo bereit", 20)
        return r.returncode == 0 and "bereit" in (r.stdout or "")
    except subprocess.TimeoutExpired:
        return False


def _qemu_laeuft():
    return subprocess.run(["pgrep", "-f", "qemu-system-x86_64.*win10.qcow2"], capture_output=True).returncode == 0


def _vm_bereit():
    """'' = erreichbar, sonst Hinweistext. Startet die VM bei Bedarf über systemd."""
    if _ssh_ok():
        return ""
    t0 = time.time()
    if not _qemu_laeuft():
        try:
            r = subprocess.run(["sudo", "-n", "systemctl", "start", VM_DIENST], capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            r = None
        if r is None or r.returncode != 0:
            m = "Zeitüberschreitung" if r is None else (r.stderr or r.stdout or "").strip()[:300]
            _protokoll("matlab_run", "vm_start_fehler", False, meldung=m)
            return "Das Rechenwerk (Windows-VM) ließ sich nicht starten: " + m
    while time.time() - t0 < START_ZEIT:
        time.sleep(5)
        if _ssh_ok():
            _protokoll("matlab_run", "vm_autostart", True, dauer=time.time() - t0)
            return ""
    _protokoll("matlab_run", "vm_start_zeitlimit", False, dauer=time.time() - t0)
    return f"VM wurde gestartet, antwortet nach {START_ZEIT} s aber noch nicht. Gleich erneut versuchen."


def _anlegen(ordner):
    r = _ssh(f"New-Item -ItemType Directory -Force -Path '{ordner}' | Out-Null; echo ok")
    return r.returncode == 0, (r.stderr or "").strip()


def _vm_stand(ordner):
    r = _ssh(f"Get-ChildItem -Path '{ordner}' -File -ErrorAction SilentlyContinue | "
             f"ForEach-Object {{ \"$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)\" }}", 30)
    st = {}
    for z in (r.stdout or "").splitlines():
        t = z.strip().split("|")
        if len(t) == 3:
            st[t[0]] = (int(t[1]) if t[1].isdigit() else -1, t[2])
    return st


def _hoch(ordner):
    """Dateien aus dem cwd (nicht rekursiv) in die VM spiegeln. -> Liste übertragener Namen"""
    stand = _vm_stand(ordner)
    ok = []
    for f in sorted(Path.cwd().iterdir()):
        if not f.is_file() or f.suffix.lower() not in HIN or f.name.startswith("."):
            continue
        g = f.stat().st_size
        vm = _vm_name(f.name)
        if g > MAX_MB * 1048576 or stand.get(vm, (None,))[0] == g:
            continue
        h = _scp(str(f), f"{SSH_ZIEL}:{ordner}/{vm}".replace("\\", "/"))
        if h.returncode == 0:
            ok.append(vm)
    return ok


def _zurueck(ordner, vorher):
    nachher = _vm_stand(ordner)
    neu = [n for n, st in nachher.items() if vorher.get(n) != st and os.path.splitext(n)[1].lower() in ZURUECK]
    geholt = []
    for n in sorted(neu)[:40]:
        if nachher[n][0] > MAX_MB * 1048576:
            geholt.append(f"{n} (zu groß, nicht geholt)")
            continue
        h = _scp(f"{SSH_ZIEL}:{ordner}/{n}".replace("\\", "/"), str(Path.cwd() / n))
        if h.returncode == 0:
            geholt.append(str(Path.cwd() / n))
    return geholt


def _beenden(ordner):
    try:
        r = _ssh("Get-CimInstance Win32_Process -Filter \"Name='MATLAB.exe' or Name='matlab.exe'\" | "
                 f"Where-Object {{ $_.CommandLine -like '*{ordner}*' }} | "
                 "ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $_.ProcessId }", 30)
        return [z.strip() for z in (r.stdout or "").splitlines() if z.strip()]
    except Exception:
        return []


def _deutung(text):
    for muster, ursache in ((r"Unrecognized function or variable '([^']+)'", "unbekannter_name"),
                            (r"Undefined function '([^']+)'", "unbekannter_name"),
                            (r"Not enough input arguments", "zu_wenig_argumente"),
                            (r"Too many input arguments", "zu_viele_argumente"),
                            (r"Index exceeds", "index_zu_gross"),
                            (r"Matrix dimensions must agree", "masse_passen_nicht"),
                            (r"Error using (\S+)", "falscher_aufruf"), (r"Error in (\S+)", "fehler_im_skript"),
                            (r"License checkout failed", "lizenz"), (r"Out of memory", "speicher")):
        m = re.search(muster, text or "")
        if m:
            return f"{ursache}:{(m.group(1) if m.groups() else m.group(0))[:60]}"
    return "unklar"


def _skript_uebertragen(ordner, name, code):
    lokal = Path.cwd() / name
    lokal.write_text(code, encoding="utf-8")  # bleibt im cwd: nachvollziehbar und änderbar
    s = _scp(str(lokal), f"{SSH_ZIEL}:{ordner}/{name}".replace("\\", "/"), 120)
    return s.returncode == 0, (s.stderr or "").strip()[:250]


def _lauf(aufruf, ordner, zeit, name, code=""):
    t0 = time.time()
    hin = _hoch(ordner)
    vorher = _vm_stand(ordner)
    try:
        m = _ssh(f'{MATLAB_EXE} -batch "cd \'{ordner}\'; {aufruf}"', zeit)
    except subprocess.TimeoutExpired:
        weg = _beenden(ordner)
        _protokoll("matlab_run", "zeitlimit", False, time.time() - t0, datei=name, code=code[:4000])
        return False, (f"Zeitlimit: nach {zeit} s abgebrochen" + (" und MATLAB in der VM beendet." if weg else ".")
                       + " Häufige Ursache: Endlosschleife, zu feines Gitter oder input()/Fenster, das auf Eingabe wartet.")
    aus, err = (m.stdout or "").strip(), (m.stderr or "").strip()
    neu = _zurueck(ordner, vorher)
    teile = []
    if hin:
        teile.append("In die VM übertragen: " + ", ".join(hin))
    if aus:
        teile.append("AUSGABE:\n" + aus[:4000])
    if err:
        teile.append("MELDUNGEN:\n" + err[:2000])
    if neu:
        teile.append("NEUE/GEÄNDERTE DATEIEN im Arbeitsverzeichnis:\n" + "\n".join(neu))
    fehler = m.returncode != 0 or re.search(r"^Error (?:using|in) ", err, re.M)
    if not teile:
        teile.append("Lief durch, ohne etwas auszugeben.")
    _protokoll("matlab_run", "matlab_fehler" if fehler else "erfolg", not fehler, time.time() - t0, datei=name,
               code=code[:1500], rc=m.returncode, signatur=_deutung(err or aus) if fehler else "", dateien=len(neu))
    if fehler:
        teile.append("FEHLER: erst die Meldung lesen, dann gezielt EINE Stelle ändern und erneut matlab_run.")
    return (not fehler), "\n\n".join(teile)


def t_status(_a):
    laeuft = _qemu_laeuft()
    ok = _ssh_ok() if laeuft else False
    if not ok:
        return (f"VM {'läuft, SSH antwortet nicht' if laeuft else 'gestoppt'} "
                f"(startet bei matlab_run automatisch, ~30-120 s). Ordner: {_ordner()}"), False
    r = _ssh(f'{MATLAB_EXE} -batch "disp(version)"', 120)
    return f"VM erreichbar. MATLAB {(r.stdout or '').strip() or '?'}. VM-Ordner: {_ordner()}  cwd: {os.getcwd()}", False


def _vorbereiten():
    h = _vm_bereit()
    if h:
        return None, h
    ordner = _ordner()
    ok, f = _anlegen(ordner)
    return (ordner, "") if ok else (None, "VM-Ordner nicht anlegbar: " + f)


def t_run(a):
    ordner, h = _vorbereiten()
    if not ordner:
        return h, True
    zeit = int(a.get("zeit_s") or ZEIT_DEFAULT)
    if a.get("datei"):
        name = os.path.basename(a["datei"])
        if not re.match(r"^[A-Za-z0-9_.\-]+\.m$", name):
            return "Dateiname ungültig (nur A-Z a-z 0-9 _ . -, Endung .m)", True
        if not (Path.cwd() / name).exists():
            return f"{name} liegt nicht im Arbeitsverzeichnis {os.getcwd()}", True
        aufruf, code = name[:-2], (Path.cwd() / name).read_text(errors="replace")
    elif (a.get("code") or "").strip():
        name = re.sub(r"[^A-Za-z0-9_.\-]", "", os.path.basename(a.get("name") or "lauf.m")) or "lauf.m"
        if not name.endswith(".m"):
            name += ".m"
        if not name.startswith("lauf_") and name != "lauf.m":
            name = "lauf_" + name  # Skriptname darf nicht wie eine Variable heißen
        code = a["code"]
        ok, f = _skript_uebertragen(ordner, name, code)
        if not ok:
            return "Skript nicht übertragbar: " + f, True
        aufruf = name[:-2]
    else:
        return "Bitte 'datei' oder 'code' angeben.", True
    ok, text = _lauf(aufruf, ordner, zeit, name, code)
    return text, not ok


def t_sync(a):
    ordner, h = _vorbereiten()
    if not ordner:
        return h, True
    if a.get("richtung") == "raus":
        n = _zurueck(ordner, {})
        return "Zurückgeholt:\n" + "\n".join(n) if n else "Keine Ergebnisdateien in der VM.", False
    n = _hoch(ordner)
    return "In die VM übertragen: " + (", ".join(n) if n else "nichts Neues"), False


def t_latex(a):
    ausdruck = (a.get("ausdruck") or "").strip()
    if not ausdruck:
        return "Bitte 'ausdruck' angeben.", True
    ordner, h = _vorbereiten()
    if not ordner:
        return h, True
    skript = (a.get("code") or "").strip() + "\nfid=fopen('latex_out.txt','w'); fprintf(fid,'%s',latex(" + ausdruck + ")); fclose(fid);"
    ok, f = _skript_uebertragen(ordner, "formel.m", skript)
    if not ok:
        return "Skript nicht übertragbar: " + f, True
    try:
        m = _ssh(f'{MATLAB_EXE} -batch "cd \'{ordner}\'; formel"', ZEIT_DEFAULT)
    except subprocess.TimeoutExpired:
        _beenden(ordner)
        return "Zeitlimit, MATLAB beendet.", True
    err = (m.stderr or "").strip()
    if m.returncode != 0 or re.search(r"^Error (?:using|in) ", err, re.M):
        _protokoll("matlab_latex", "matlab_fehler", False, signatur=_deutung(err))
        return "FEHLER:\n" + err[:1500], True
    f = _ssh(f"Get-Content -Raw -Path '{ordner}\\latex_out.txt' -ErrorAction SilentlyContinue", 60)
    formel = (f.stdout or "").strip()
    _protokoll("matlab_latex", "erfolg" if formel else "leer", bool(formel))
    return (f"LaTeX:\n$$\n{formel}\n$$" if formel else "Keine Formel erhalten."), not formel


def t_spick(a):
    metas = {}
    for f in sorted(SPICK.glob("*.meta.json")):
        try:
            m = json.loads(f.read_text())
            metas[m["key"]] = m
        except Exception:
            pass
    w = (a.get("toolbox") or "").strip().lower()
    if w:
        for k, m in metas.items():
            if w == k or w in m.get("name", "").lower() or k in w:
                p = SPICK / f"{k}.md"
                if p.exists():
                    return p.read_text(errors="replace")[:60000], False
        return f"Unbekannt: {w}. Gültig: {', '.join(metas)}", True
    return "\n".join(f"{k}: {m.get('name')} - {m.get('wann_sinnvoll', '')[:110]}" for k, m in metas.items()) or "keine Spickzettel", False


S = {"type": "string"}
TOOLS = [
    ("matlab_status", "Prüft, ob die MATLAB-VM erreichbar ist (Version, Ordner).", {}, [], t_status),
    ("matlab_run", "MATLAB R2020a ausführen (Skriptdatei im cwd ODER Code). Neue Ergebnisdateien kommen ins cwd. REGELN:\n" + REGELN,
     {"datei": S, "code": S, "name": S, "zeit_s": {"type": "integer"}}, [], t_run),
    ("matlab_files_sync", "Dateien zwischen cwd und VM abgleichen. richtung: 'rein' (Standard) oder 'raus' (Ergebnisse holen).",
     {"richtung": {"type": "string", "enum": ["rein", "raus"]}}, [], t_sync),
    ("matlab_latex", "Symbolischen MATLAB-Ausdruck per Symbolic Core in LaTeX wandeln (code: syms/Vorbereitung, ausdruck: z.B. f).",
     {"code": S, "ausdruck": S}, ["ausdruck"], t_latex),
    ("matlab_spickzettel", "Geprüfter R2020a-Spickzettel einer Toolbox (leer = Übersicht). VOR Toolbox-Code lesen.",
     {"toolbox": S}, [], t_spick),
]


def reply(i, res=None, err=None):
    m = {"jsonrpc": "2.0", "id": i}
    m["error" if err else "result"] = err or res
    sys.stdout.write(json.dumps(m, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        m, i = r.get("method"), r.get("id")
        if m == "initialize":
            reply(i, {"protocolVersion": (r.get("params") or {}).get("protocolVersion", "2024-11-05"),
                      "capabilities": {"tools": {}}, "serverInfo": {"name": "matlab", "version": "1.0"},
                      "instructions": REGELN})
        elif m == "tools/list":
            reply(i, {"tools": [{"name": n, "description": d, "inputSchema": {"type": "object", "properties": p, "required": q}}
                                for n, d, p, q, _ in TOOLS]})
        elif m == "tools/call":
            fn = next((t[4] for t in TOOLS if t[0] == r["params"]["name"]), None)
            try:
                txt, bad = fn(r["params"].get("arguments") or {}) if fn else ("Unbekanntes Werkzeug", True)
            except Exception as e:
                txt, bad = f"Fehler: {e!r}", True
            reply(i, {"content": [{"type": "text", "text": txt}], "isError": bool(bad)})
        elif i is not None:
            reply(i, err={"code": -32601, "message": "unbekannt"})


if __name__ == "__main__":
    main()
