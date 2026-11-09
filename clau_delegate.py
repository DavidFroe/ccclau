#!/usr/bin/env python3
"""
clau_delegate.py — schwere Aufgaben an einen eigenen, vollständig pro Aufruf konfigurierten
Claude-Code-Lauf (über clau.sh --headless) abgeben. Keine Rückfragen, Zwischenstände abrufbar.

  clau_delegate.py start  <spec.json | ->      Job starten, gibt job_id aus
  clau_delegate.py status <job_id>             Zwischenstand
  clau_delegate.py result <job_id>             Endergebnis (oder "läuft noch")
  clau_delegate.py wait   <job_id> [sek]       Auf Ende warten (Default 600 s), dann Ergebnis
  clau_delegate.py more   <job_id> <text>      Zusatzinfo, setzt denselben Lauf fort (--resume)
  clau_delegate.py stop   <job_id>
  clau_delegate.py list

Spec (alles optional außer aufgabe), Presets: ~/.config/clau/delegate/presets/<name>.json
  aufgabe, preset, modell ("owl:137"), ordner, isolation ("worktree"|"direkt"),
  tools [..], tools_verboten [..], mcp_server [{name,command,args,env}],
  skills [Name oder Pfad], systemprompt_zusatz, kontext (Text) / kontext_dateien [..],
  rechte ("bypass"|"normal"), limits {zeit_s, max_turns, budget_usd}, matlab / solidcraft (true = MCP dazu)
"""
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
CLAU_BIN = os.environ.get("CLAU_BIN") or os.path.join(HERE, "clau.sh")
BASE = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "clau", "delegate")
JOBS = os.path.join(BASE, "jobs")
LOCKS = os.path.join(BASE, "locks")
PRESETS = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                       "clau", "delegate", "presets")

REGELN = (
    "Du arbeitest als autonomer Unteragent. Stelle KEINE Rückfragen und biete keine Auswahl an: "
    "triff bei Unklarheit die vernünftigste Annahme und halte sie fest. "
    "Pflege laufend die Datei FORTSCHRITT.md im Arbeitsordner (erledigt / als nächstes / Annahmen), "
    "damit Zwischenstände abrufbar sind. Beende mit: LÖSUNG, ANNAHMEN, GEÄNDERTE DATEIEN, OFFENE PUNKTE."
)


def jdir(jid):
    return os.path.join(JOBS, jid)


def rj(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def wj(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def merge_spec(spec):
    if spec.get("preset"):
        p = rj(os.path.join(PRESETS, spec["preset"] + ".json"))
        if p is None:
            raise SystemExit(f"Preset nicht gefunden: {spec['preset']}")
        spec = {**p, **{k: v for k, v in spec.items() if v is not None}}
    if not spec.get("aufgabe"):
        raise SystemExit("Spec braucht 'aufgabe'")
    return spec


def git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def prepare_workdir(spec, jid):
    ordner = os.path.abspath(os.path.expanduser(spec.get("ordner") or os.getcwd()))
    if not os.path.isdir(ordner):
        raise SystemExit(f"Ordner existiert nicht: {ordner}")
    iso = spec.get("isolation") or "worktree"
    if iso == "worktree" and git(["rev-parse", "--git-dir"], ordner).returncode == 0:
        work = os.path.join(jdir(jid), "work")
        r = git(["worktree", "add", "-q", "-b", f"delegate/{jid}", work, "HEAD"], ordner)
        if r.returncode == 0:
            return work, ordner, True
        sys.stderr.write("worktree fehlgeschlagen, arbeite direkt: " + r.stderr)
    return ordner, ordner, False


def build_args(spec, jid, work):
    d = jdir(jid)
    a = ["--output-format", "stream-json", "--verbose"]
    if spec.get("rechte", "bypass") == "bypass" and os.geteuid() != 0:
        a.append("--dangerously-skip-permissions")
    if spec.get("tools"):
        a.append("--allowed-tools=" + ",".join(spec["tools"]))
    if spec.get("tools_verboten"):
        a.append("--disallowed-tools=" + ",".join(spec["tools_verboten"]))
    lim = spec.get("limits") or {}
    if lim.get("max_turns"):
        a += ["--max-turns", str(lim["max_turns"])]
    if lim.get("budget_usd"):
        a += ["--max-budget-usd", str(lim["budget_usd"])]
    mcp = list(spec.get("mcp_server") or [])
    if spec.get("matlab"):  # optional: MATLAB-MCP (matlab_mcp.py); Kennung = Job-ID
        mcp.append({"name": "matlab", "command": sys.executable,
                    "args": [os.path.join(HERE, "matlab_mcp.py")], "env": {"CLAU_CHAT_ID": jid}})
    if spec.get("solidcraft"):  # optional: SolidCraft-Brücke (solidcraft_mcp.py)
        mcp.append({"name": "solidcraft", "command": sys.executable,
                    "args": [os.path.join(HERE, "solidcraft_mcp.py")], "env": {"CLAU_CHAT_ID": jid}})
    if mcp:
        servers = {}
        for s in mcp:
            servers[s["name"]] = {"type": "stdio", "command": s["command"],
                                  "args": s.get("args", []), "env": s.get("env", {})}
        mp = os.path.join(d, "mcp.json")
        wj(mp, {"mcpServers": servers})
        a.append("--mcp-config=" + mp)
    for sk in spec.get("skills") or []:
        src = sk if os.path.isabs(sk) else os.path.expanduser(f"~/.claude/skills/{sk}")
        if os.path.isdir(src):
            dst = os.path.join(work, ".claude", "skills", os.path.basename(src.rstrip("/")))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.exists(dst):
                os.symlink(src, dst)
    a += ["--append-system-prompt", REGELN + ("\n" + spec["systemprompt_zusatz"] if spec.get("systemprompt_zusatz") else "")]
    return a


def build_prompt(spec):
    parts = [spec["aufgabe"]]
    if spec.get("kontext"):
        parts.append("## Kontext\n" + spec["kontext"])
    for f in spec.get("kontext_dateien") or []:
        try:
            parts.append(f"## Datei {f}\n" + open(os.path.expanduser(f), encoding="utf-8", errors="replace").read()[:60000])
        except OSError:
            parts.append(f"## Datei {f}\n(nicht lesbar)")
    return "\n\n".join(parts)


def cmd_start(src):
    spec = merge_spec(json.load(sys.stdin if src == "-" else open(src, encoding="utf-8")))
    jid = time.strftime("%y%m%d-%H%M%S-") + uuid.uuid4().hex[:4]
    os.makedirs(jdir(jid), exist_ok=True)
    work, orig, is_wt = prepare_workdir(spec, jid)
    args = build_args(spec, jid, work)
    with open(os.path.join(jdir(jid), "args.bin"), "wb") as f:
        f.write(b"".join(x.encode() + b"\0" for x in args))
    with open(os.path.join(jdir(jid), "prompt.txt"), "w", encoding="utf-8") as f:
        f.write(build_prompt(spec))
    wj(os.path.join(jdir(jid), "job.json"), {
        "id": jid, "spec": spec, "work": work, "orig": orig, "worktree": is_wt,
        "modell": spec.get("modell") or "", "gestartet": time.time(), "status": "wartet_auf_slot"})
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "_run", jid], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(jid)


def set_status(jid, **kw):
    j = rj(os.path.join(jdir(jid), "job.json"), {})
    j.update(kw)
    wj(os.path.join(jdir(jid), "job.json"), j)


def cmd_run(jid, resume_text=None):
    """Hintergrundprozess: Slot-Sperre je Modell, dann clau.sh --headless."""
    d = jdir(jid)
    j = rj(os.path.join(d, "job.json"))
    spec = j["spec"]
    os.makedirs(LOCKS, exist_ok=True)
    lockf = open(os.path.join(LOCKS, (j["modell"] or "default").replace(":", "_").replace("/", "_") + ".lock"), "w")
    fcntl.flock(lockf, fcntl.LOCK_EX)  # Warteschlange: ein Lauf je Modell
    set_status(jid, status="laeuft", slot_seit=time.time())
    prompt = open(os.path.join(d, "prompt.txt"), encoding="utf-8").read()
    cmd = [CLAU_BIN]
    if j["modell"]:
        cmd += ["-m", j["modell"]]
    cmd += ["--headless", "-p", resume_text or prompt]
    env = dict(os.environ, CLAU_HEADLESS_ARGS_FILE=os.path.join(d, "args.bin"))
    logf = open(os.path.join(d, "log.jsonl"), "ab")
    zeit = int((spec.get("limits") or {}).get("zeit_s") or 3600)
    p = subprocess.Popen(cmd, cwd=j["work"], env=env, stdout=logf, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    set_status(jid, pid=p.pid)
    try:
        rc = p.wait(timeout=zeit)
        status = "fertig" if rc == 0 else "fehler"
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGTERM)
        status, rc = "zeitlimit", -1
    if rj(os.path.join(d, "job.json"), {}).get("status") == "gestoppt":
        status = "gestoppt"
    set_status(jid, status=status, rc=rc, beendet=time.time())


def events(jid):
    out = []
    try:
        with open(os.path.join(jdir(jid), "log.jsonl"), encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def summarize(jid, n=8):
    j = rj(os.path.join(jdir(jid), "job.json"))
    if not j:
        raise SystemExit(f"Unbekannter Job: {jid}")
    ev = events(jid)
    schritte, letzter_text, final = [], "", None
    for e in ev:
        if e.get("type") == "assistant":
            for b in (e.get("message") or {}).get("content") or []:
                if b.get("type") == "tool_use":
                    inp = json.dumps(b.get("input"), ensure_ascii=False)
                    schritte.append(f"{b.get('name')} {inp[:120]}")
                elif b.get("type") == "text" and b.get("text", "").strip():
                    letzter_text = b["text"].strip()
        elif e.get("type") == "result":
            final = e
    fp = os.path.join(j["work"], "FORTSCHRITT.md")
    fortschritt = open(fp, encoding="utf-8", errors="replace").read()[-3000:] if os.path.exists(fp) else ""
    return j, schritte[-n:], letzter_text, fortschritt, final, len(schritte)


def diff_of(j):
    if not j.get("worktree"):
        return ""
    w = j["work"]
    git(["add", "-N", "."], w)
    r = git(["diff", "HEAD", "--stat", "--patch", "--", ".", ":(exclude).claude", ":(exclude)FORTSCHRITT.md"], w)
    return r.stdout[-30000:]


def cmd_status(jid):
    j, schritte, text, fort, final, n = summarize(jid)
    print(json.dumps({"id": jid, "status": j.get("status"), "modell": j.get("modell"),
                      "laufzeit_s": int((j.get("beendet") or time.time()) - j["gestartet"]),
                      "schritte_gesamt": n, "letzte_schritte": schritte, "letzter_text": text[-1500:],
                      "fortschritt_md": fort}, ensure_ascii=False, indent=1))


def cmd_result(jid):
    j, schritte, text, fort, final, n = summarize(jid)
    if j.get("status") in ("wartet_auf_slot", "laeuft"):
        print(json.dumps({"id": jid, "status": j["status"], "hinweis": "läuft noch – job_zwischenstand nutzen"},
                         ensure_ascii=False))
        return
    res = (final or {}).get("result") or text
    print(json.dumps({"id": jid, "status": j["status"], "ergebnis": res,
                      "arbeitsordner": j["work"], "branch": f"delegate/{jid}" if j.get("worktree") else None,
                      "diff": diff_of(j)}, ensure_ascii=False, indent=1))


def cmd_wait(jid, secs):
    end = time.time() + secs
    while time.time() < end:
        if rj(os.path.join(jdir(jid), "job.json"), {}).get("status") not in ("wartet_auf_slot", "laeuft"):
            break
        time.sleep(3)
    cmd_result(jid)


def cmd_more(jid, text):
    j = rj(os.path.join(jdir(jid), "job.json"))
    if j.get("status") in ("wartet_auf_slot", "laeuft"):
        raise SystemExit("Job läuft noch; erst warten oder stoppen")
    set_status(jid, status="wartet_auf_slot", beendet=None)
    sid = next((e.get("session_id") for e in reversed(events(jid)) if e.get("session_id")), None)
    extra = f"Ergänzung zur bisherigen Aufgabe (keine Rückfragen):\n{text}"
    if sid:  # --resume über Zusatzargument-Datei
        with open(os.path.join(jdir(jid), "args.bin"), "ab") as f:
            f.write(b"--resume\0" + sid.encode() + b"\0")
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "_run2", jid, extra], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(jid)


def cmd_stop(jid):
    j = rj(os.path.join(jdir(jid), "job.json"))
    set_status(jid, status="gestoppt")
    if j.get("pid"):
        try:
            os.killpg(j["pid"], signal.SIGTERM)
        except OSError:
            pass
    print("gestoppt")


def cmd_list():
    for jid in sorted(os.listdir(JOBS)) if os.path.isdir(JOBS) else []:
        j = rj(os.path.join(jdir(jid), "job.json"), {})
        print(f"{jid}\t{j.get('status')}\t{j.get('modell')}\t{(j.get('spec') or {}).get('aufgabe', '')[:70]}")


def main(a):
    c = a[1] if len(a) > 1 else ""
    if c == "start" and len(a) > 2:
        cmd_start(a[2])
    elif c == "_run":
        cmd_run(a[2])
    elif c == "_run2":
        cmd_run(a[2], a[3])
    elif c == "status" and len(a) > 2:
        cmd_status(a[2])
    elif c == "result" and len(a) > 2:
        cmd_result(a[2])
    elif c == "wait" and len(a) > 2:
        cmd_wait(a[2], int(a[3]) if len(a) > 3 else 600)
    elif c == "more" and len(a) > 3:
        cmd_more(a[2], a[3])
    elif c == "stop" and len(a) > 2:
        cmd_stop(a[2])
    elif c == "list":
        cmd_list()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
