#!/usr/bin/env python3
"""
picogk_mcp.py — PicoGK (Voxel-CAD, C#) als optionales MCP-Werkzeug für clau.

Nur aktiv bei CLAU_PICOGK=1 oder "picogk": true im clau --delegate-Spec.
Nutzt die vorhandene Einrichtung unter 3ddruck/picogk (Docker-Image picogk-dotnet:9.0, run.sh) – nichts
davon wird verändert. Eigene Projekte heißen cc_<kennung>_<name> und kollidieren so nicht mit denen der
WebUI/Wilfrieds Chat (dort bleibt nur Lesen erlaubt). Ergebnisse (<name>.stl, <name>_vorschau.png und der
C#-Quelltext <name>.cs) landen im cwd. Kennung: CLAU_CHAT_ID, sonst Ordnername.

Logik angelehnt an picogk/webui-werkzeug/picogk_tool.py (dort unverändert; Kurzreferenz und Vorlagen werden
zur Laufzeit von dort gelesen, damit sie nicht doppelt gepflegt werden).
"""
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(os.environ.get("CLAU_PICOGK_ROOT", "/home/david/Schreibtisch/Platte/3ddruck"))
PICOGK = ROOT / "picogk"
MODELLE = ROOT / "modelle"
RUN_SH = PICOGK / "run.sh"
OPENSCAD = ROOT / "cad" / "OpenSCAD.AppImage"
WEBUI_TOOL = PICOGK / "webui-werkzeug" / "picogk_tool.py"
ZEIT_DEFAULT = int(os.environ.get("CLAU_PICOGK_TIMEOUT", "600"))
IMAGE = "picogk-dotnet:9.0"
KEINE = {"PicoGK", "PicoGK-official", "build", "nuget", "Documents", "webui-werkzeug", "verlauf"}

CSPROJ = """<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>disable</Nullable>
    <RootNamespace>PicoGKGen</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="../PicoGK-official/PicoGK.csproj" />
  </ItemGroup>
  <ItemGroup>
    <None Include="../PicoGK-official/native/linux-x64/libpicogk.26.2.so">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <Link>libpicogk.26.2.so</Link>
    </None>
  </ItemGroup>
</Project>
"""

KURZ = """PicoGK 2.3 (C#, Voxel). Speichern IMMER nach /ausgabe/<name>.stl. Es gibt kein Vector3d, kein BoundingBox, kein lib.Voxels(...):
richtig sind Vector3 (System.Numerics), BBox3, new Lattice(lib) + AddBeam(a, b, radA, radB, rundeKappe), new Voxels(lattice) bzw.
new Voxels(lib, IImplicit, bbox); BoolAdd/BoolSubtract/BoolIntersect/Offset(mm); vox.mshAsMesh().SaveToStlFile(pfad).
Voxelgröße bestimmt Zeit und Speicher: 0.5 mm Sekunden, 0.3 mm zügig, 0.05 mm das Tausendfache (sehr speicherhungrig, für feine
Gravuren nur kleine Bauräume). Vor dem ersten Modell picogk_hilfe lesen (zwei geprüfte Vorlagen)."""


def kennung():
    k = os.environ.get("CLAU_CHAT_ID") or os.path.basename(os.getcwd().rstrip("/"))
    return re.sub(r"[^A-Za-z0-9]", "", k)[:12].lower() or "allgemein"


def san(name):
    return re.sub(r"[^a-z0-9_]", "_", (name or "").lower()).strip("_") or "modell"


def eigen(name):
    return PICOGK / f"cc_{kennung()}_{san(name)}"


def finden(name):
    """Eigenes Projekt, sonst fremdes (nur lesen)."""
    e = eigen(name)
    if (e / "Program.cs").exists():
        return e, True
    b = san(name)
    for k in (PICOGK / f"gen_{b}", PICOGK / b, PICOGK / (name or "")):
        if k.is_dir() and (k / "Program.cs").exists():
            return k, False
    return None, False


def archiviere(proj):
    q = proj / "Program.cs"
    if q.exists():
        a = PICOGK / "verlauf" / proj.name  # AUSSERHALB des Projekts, sonst kompiliert .NET alte Stände mit
        a.mkdir(parents=True, exist_ok=True)
        shutil.copy2(q, a / f"Program_{time.strftime('%Y%m%d-%H%M%S')}.cs")
        for alt in sorted(a.glob("Program_*.cs"))[:-20]:
            alt.unlink(missing_ok=True)


def speichern(name, code):
    proj = eigen(name)
    proj.mkdir(parents=True, exist_ok=True)
    archiviere(proj)
    (proj / "Program.cs").write_text(code, encoding="utf-8")
    (proj / "Test.csproj").write_text(CSPROJ, encoding="utf-8")
    return proj


def container_beenden(proj):
    """Nach Zeitlimit: Container dieses Projekts beenden (docker run --rm überlebt das Töten von bash)."""
    try:
        ids = subprocess.run(["docker", "ps", "-q", "--filter", f"ancestor={IMAGE}"], capture_output=True, text=True, timeout=15).stdout.split()
        for i in ids:
            wd = subprocess.run(["docker", "inspect", "-f", "{{.Config.WorkingDir}}", i], capture_output=True, text=True, timeout=15).stdout.strip()
            if wd.endswith("/" + proj.name):
                subprocess.run(["docker", "kill", i], capture_output=True, timeout=30)
    except Exception:
        pass


def vorschau(stl, ziel):
    """PNG mit OpenSCAD (PicoGK ist Y-up, OpenSCAD Z-up -> 90° um X). Leer bei Fehler."""
    try:
        with tempfile.TemporaryDirectory() as td:
            scad = Path(td) / "v.scad"
            scad.write_text(f'rotate([90, 0, 0]) {{ import("{stl}"); }}\n', encoding="utf-8")
            out = Path(td) / "v.png"
            subprocess.run(["xvfb-run", "-a", str(OPENSCAD), "--export-format=png", "--imgsize=800,800",
                            "--projection=ortho", "-o", str(out), str(scad)], capture_output=True, text=True, timeout=120)
            if out.exists() and out.stat().st_size > 0:
                shutil.copy2(out, ziel)
                return True
    except Exception:
        pass
    return False


def bauen(name, proj, zeit):
    t0 = time.time()
    try:
        p = subprocess.run(["bash", str(RUN_SH), proj.name], cwd=str(PICOGK), capture_output=True, text=True, timeout=zeit)
    except subprocess.TimeoutExpired:
        container_beenden(proj)
        return (f"Zeitlimit: nach {zeit} s abgebrochen und Container beendet. Voxelgröße vergrößern "
                f"(z.B. new Library(1.0f)) oder den Bauraum verkleinern."), True
    if p.returncode != 0:
        zeilen = [z for z in (p.stdout or "").splitlines() if "error" in z.lower() or "FEHLER" in z]
        tail = ((p.stderr or "").strip()[-300:] + "\n" + ("\n".join(zeilen[-12:]) or (p.stdout or "").strip()[-1200:])).strip()[-2000:]
        return f"FEHLER (Exit {p.returncode}):\n{tail}\nCode prüfen und gezielt EINE Stelle ändern, dann picogk_bauen erneut.", True
    b = san(name)
    neu = [f for f in MODELLE.glob("*.stl") if f.stat().st_mtime > t0]
    stl = (MODELLE / f"{b}.stl") if (MODELLE / f"{b}.stl").exists() and (MODELLE / f"{b}.stl") in neu else (max(neu, key=lambda f: f.stat().st_mtime) if neu else None)
    if stl is None:
        return "FEHLER: keine neue STL entstanden. Der Code muss nach /ausgabe/<name>.stl speichern.\n" + (p.stdout or "")[-800:], True
    cwd = Path.cwd()
    shutil.copy2(stl, cwd / f"{b}.stl")
    shutil.copy2(proj / "Program.cs", cwd / f"{b}.cs")
    png = vorschau(stl, cwd / f"{b}_vorschau.png")
    out = [f"OK ({time.time() - t0:.0f} s). Im Arbeitsverzeichnis: {b}.stl ({stl.stat().st_size // 1024} KB), {b}.cs (Quelltext)"
           + (f", {b}_vorschau.png" if png else " (Vorschau-PNG nicht erzeugt)")]
    return "\n".join(out), False


def t_hilfe(_a):
    try:
        baum = ast.parse(WEBUI_TOOL.read_text(encoding="utf-8"))
        for n in ast.walk(baum):
            if isinstance(n, ast.FunctionDef) and n.name == "picogk_hilfe":
                for s in ast.walk(n):
                    if isinstance(s, ast.Return) and isinstance(s.value, ast.Constant):
                        return KURZ + "\n\n" + s.value.value, False
    except Exception:
        pass
    return KURZ, False


def t_liste(_a):
    z = []
    for o in sorted(PICOGK.iterdir()):
        if o.is_dir() and o.name not in KEINE and not o.name.startswith(".") and (o / "Program.cs").exists():
            mine = o.name.startswith(f"cc_{kennung()}_")
            z.append(f"{o.name:34s} {time.strftime('%d.%m. %H:%M', time.localtime((o / 'Program.cs').stat().st_mtime))}  "
                     f"{'eigenes (änderbar)' if mine else 'fremd (nur lesen)' if not o.name.startswith('cc_') else 'anderer Lauf (nur lesen)'}")
    return "\n".join(z) or "Noch keine Projekte.", False


def t_zeigen(a):
    p, _ = finden(a.get("name", ""))
    if p is None:
        return "Kein Projekt dieses Namens. picogk_modelle_auflisten zeigt die vorhandenen.", True
    return (p / "Program.cs").read_text(encoding="utf-8", errors="replace")[:20000], False


def t_speichern(a):
    if not (a.get("code") or "").strip():
        return "Bitte 'code' angeben.", True
    p = speichern(a.get("name", ""), a["code"])
    return f"Gespeichert als {p.name}. Jetzt picogk_bauen.", False


def t_bauen(a):
    name = a.get("name", "")
    if a.get("datei"):  # Quelltext liegt im cwd (z.B. mit dem Write-Werkzeug geschrieben)
        f = Path.cwd() / os.path.basename(a["datei"])
        if not f.exists():
            return f"{f.name} liegt nicht im Arbeitsverzeichnis.", True
        speichern(name, f.read_text(encoding="utf-8", errors="replace"))
    proj = eigen(name)
    if not (proj / "Program.cs").exists():
        fremd, _ = finden(name)
        if fremd is None:
            return "Kein Code vorhanden: erst picogk_code_speichern (oder datei angeben).", True
        proj = speichern(name, (fremd / "Program.cs").read_text(encoding="utf-8", errors="replace"))  # eigene Kopie
    return bauen(name, proj, int(a.get("zeit_s") or ZEIT_DEFAULT))


def t_shape(a):
    if not (a.get("code") or "").strip():
        return "Bitte 'code' (vollständiger Program.cs) angeben.", True
    speichern(a.get("name", ""), a["code"])
    return bauen(a.get("name", ""), eigen(a.get("name", "")), int(a.get("zeit_s") or ZEIT_DEFAULT))


S = {"type": "string"}
TOOLS = [
    ("picogk_hilfe", "Geprüfte PicoGK-Schnittstelle und zwei lauffähige Vorlagen. VOR dem ersten Modell lesen.\n" + KURZ, {}, [], t_hilfe),
    ("picogk_modelle_auflisten", "Vorhandene PicoGK-Projekte (eigene änderbar, fremde nur lesbar).", {}, [], t_liste),
    ("picogk_code_zeigen", "C#-Quelltext (Program.cs) eines Projekts ansehen.", {"name": S}, ["name"], t_zeigen),
    ("picogk_code_speichern", "Program.cs eines (eigenen) Projekts speichern, ohne zu bauen. Vorheriger Stand wird archiviert.",
     {"name": S, "code": S}, ["name", "code"], t_speichern),
    ("picogk_bauen", "Projekt bauen und rechnen (Docker). Optional datei = Program.cs aus dem cwd verwenden. Liefert <name>.stl, <name>.cs, "
     "<name>_vorschau.png im cwd. Fehler zuerst lesen, dann gezielt EINE Stelle ändern.",
     {"name": S, "datei": S, "zeit_s": {"type": "integer"}}, ["name"], t_bauen),
    ("picogk_shape", "Speichern + Bauen in einem Schritt: name und vollständiger C#-Code (Program.cs).",
     {"name": S, "code": S, "zeit_s": {"type": "integer"}}, ["name", "code"], t_shape),
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
                      "capabilities": {"tools": {}}, "serverInfo": {"name": "picogk", "version": "1.0"}, "instructions": KURZ})
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
