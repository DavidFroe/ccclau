#!/usr/bin/env python3
"""Claude-Code-Sitzung in einen anderen Ordner "übernehmen" (Kopie, nichts wird gelöscht).

Claude Code findet `--resume <id>` nur im Projektordner des aktuellen Verzeichnisses
(~/.claude/projects/<cwd mit / -> ->/). Wurde eine Sitzung im falschen Ordner gestartet (z. B. ~),
kopiert dieses Skript die Sitzungsdatei samt Titel/Meta-Einträgen von clau in den Projektordner
des Zielverzeichnisses. Danach erscheint sie dort als normale (geschlossene) Sitzung.

  adopt_session.py <sid> [--to /pfad] [--from /pfad] [--force]

Läuft die Sitzung noch, ist die Kopie nur ein Schnappschuss: nach dem Beenden erneut mit --force kopieren.
"""
import argparse, json, os, shutil, sys

root = os.path.expanduser("~/.claude/projects")
enc = lambda p: os.path.abspath(p).replace("/", "-")

ap = argparse.ArgumentParser()
ap.add_argument("sid")
ap.add_argument("--to", default=os.getcwd())
ap.add_argument("--from", dest="src")
ap.add_argument("--force", action="store_true")
a = ap.parse_args()

src_dir = os.path.join(root, enc(a.src)) if a.src else None
if src_dir is None:
    hits = [os.path.join(root, d) for d in os.listdir(root)
            if d != enc(a.to) and os.path.exists(os.path.join(root, d, a.sid + ".jsonl"))]   # Ziel ist nicht die Quelle
    if len(hits) != 1:
        sys.exit(f"Sitzung {a.sid}: {len(hits)} Fundorte, bitte --from angeben" if hits else f"Sitzung {a.sid} nicht gefunden")
    src_dir = hits[0]
dst_dir = os.path.join(root, enc(a.to))
if os.path.abspath(src_dir) == os.path.abspath(dst_dir):
    sys.exit("Quelle und Ziel sind gleich – nichts zu tun")
os.makedirs(dst_dir, exist_ok=True)

s, d = os.path.join(src_dir, a.sid + ".jsonl"), os.path.join(dst_dir, a.sid + ".jsonl")
if os.path.exists(d) and not a.force:
    sys.exit(f"{d} existiert schon (mit --force überschreiben)")
shutil.copy2(s, d)
sub = os.path.join(src_dir, a.sid)               # Unterordner (Subagenten, Tool-Ergebnisse)
if os.path.isdir(sub):
    shutil.copytree(sub, os.path.join(dst_dir, a.sid), dirs_exist_ok=True)

for name in (".clau-session-titles.json", ".clau-session-meta.json"):
    sp, dp = os.path.join(src_dir, name), os.path.join(dst_dir, name)
    try:
        sj = json.load(open(sp)).get(a.sid)
    except Exception:
        sj = None
    if sj is None:
        continue
    try:
        dj = json.load(open(dp))
    except Exception:
        dj = {}
    dj[a.sid] = sj
    json.dump(dj, open(dp, "w"), indent=1, ensure_ascii=False)
print(f"übernommen: {a.sid[:8]}  {src_dir.replace(root + '/', '')} → {dst_dir.replace(root + '/', '')}  (Quelle bleibt unverändert)")
