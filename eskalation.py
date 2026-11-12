#!/usr/bin/env python3
"""
eskalation.py — Laufzeit-Eskalation auf ein größeres Modell (Teil von owl_proxy.py, per Proxy-API steuerbar).

Der Proxy sieht jede Anfrage von Claude Code. Zählt er in einem gleitenden Fenster zu viele
  - Kompaktierungen   (Claude Codes Zusammenfassungs-Anfrage),
  - Tool-/Backend-Fehler, Kontext-Überläufe,
  - Abbrüche          (Client trennt mitten im Stream),
  - Schleifen         (derselbe Tool-Aufruf mehrfach hintereinander),
lenkt er das Hauptmodell ab der nächsten Anfrage auf das Ziel-Modell um (der Verlauf reist mit, die API
ist zustandslos). Damit Claude Code dabei auch das größere Fenster nutzt, meldet der Proxy danach die
Token umgerechnet auf das alte Fenster (alt/neu), so dass Auto-Compact entsprechend später greift.

Standard: AUS. Einschalten per Umgebung (CLAU_ESC=1 …, siehe clau.sh), per Proxy-API
(POST /_clau/eskalation) oder über den MCP (clau_delegate_mcp.py: eskalation_*).

  eskalation.py report <esc.jsonl> [<usage.jsonl>]   Statistik am Sessionende
  eskalation.py ctl [--port P] status|an|aus|jetzt|zurueck|ziel <id>|set k=v ...   Steuerung laufender Proxys
"""
import json
import os
import re
import sys
import threading
import time

STANDARD = {"aktiv": False, "ziel": "", "compact_max": 3, "fehler_max": 5, "abbrueche_max": 3,
            "schleife_max": 4, "ueberlauf_max": 1, "fenster": 60, "zurueck_nach": 0, "skalieren": True}
SCHLUESSEL_INT = ("compact_max", "fehler_max", "abbrueche_max", "schleife_max", "ueberlauf_max", "fenster", "zurueck_nach")

_COMPACT = re.compile(r"create a detailed summary of (?:the|this) conversation", re.I)


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") if isinstance(b, dict) and b.get("type") == "text" else
                         (b.get("content", "") if isinstance(b, dict) and isinstance(b.get("content"), str) else "")
                         for b in content)
    return ""


class Eskalation:
    def __init__(self, hauptmodell, ctx_fn, logfile="", log=lambda m: None, env=None):
        env = os.environ if env is None else env
        self.haupt = str(hauptmodell)
        self.ctx_fn = ctx_fn            # Modell-ID -> Kontextfenster (0 = unbekannt)
        self.logfile = logfile
        self.log = log
        self.lock = threading.Lock()
        self.cfg = dict(STANDARD)
        self.cfg["aktiv"] = env.get("OWL_ESC", "0") == "1"
        self.cfg["ziel"] = self._norm(env.get("OWL_ESC_TARGET", ""))
        for k in SCHLUESSEL_INT:
            v = env.get("OWL_ESC_" + k.upper())
            if v and v.isdigit():
                self.cfg[k] = int(v)
        self.n_req = 0
        self.ereignisse = []            # (n_req, typ)
        self.eskaliert = False
        self.seit = None                # (n_req, zeit, grund)
        self.gesehen = set()
        self.gemeldet_schleife = {}
        self.skala = 1.0
        self.hook = None                # optional: Callback(ereignis-dict), z.B. fürs Denkprotokoll

    @staticmethod
    def _norm(m):
        m = str(m or "").strip()
        return m[4:] if m.startswith("owl:") else m

    def _ereignis(self, typ, detail="", **extra):
        e = {"ts": round(time.time(), 1), "req": self.n_req, "typ": typ, "detail": str(detail)[:200]}
        e.update(extra)
        if self.hook:
            try:
                self.hook(e)
            except Exception:
                pass
        if self.logfile:
            try:
                with open(self.logfile, "a", encoding="utf-8") as f:
                    f.write(json.dumps(e, ensure_ascii=False) + "\n")
            except OSError:
                pass

    def _zaehle(self, typen):
        fe = self.cfg["fenster"]
        return sum(1 for n, t in self.ereignisse if t in typen and (not fe or n > self.n_req - fe))

    def _notiere(self, typ, detail=""):
        self.ereignisse.append((self.n_req, typ))
        self._ereignis(typ, detail, modell=self.aktuell())
        self.log(f"Eskalation: Ereignis {typ} ({detail[:80]})")

    def aktuell(self):
        return self.cfg["ziel"] if self.eskaliert else self.haupt

    def _pruefe(self):
        c = self.cfg
        if not c["aktiv"] or self.eskaliert or not c["ziel"] or c["ziel"] == self.haupt:
            return
        regeln = (("kompaktierung", ("compact",), c["compact_max"]),
                  ("fehler", ("tool_fehler", "backend_fehler"), c["fehler_max"]),
                  ("abbrueche", ("abbruch",), c["abbrueche_max"]),
                  ("schleife", ("schleife",), c["schleife_max"] and 1),
                  ("kontext_ueberlauf", ("ueberlauf",), c["ueberlauf_max"]))
        for name, typen, grenze in regeln:
            if grenze and self._zaehle(typen) >= grenze:
                self._eskaliere(f"{name}: {self._zaehle(typen)} >= {grenze} in {c['fenster'] or 'ganzer Session'} Anfragen")
                return

    def _eskaliere(self, grund):
        alt, neu = self.ctx_fn(self.haupt), self.ctx_fn(self.cfg["ziel"])
        self.skala = (alt / neu) if (self.cfg["skalieren"] and alt and neu and neu > alt) else 1.0
        self.eskaliert = True
        self.seit = (self.n_req, time.time(), grund)
        self._ereignis("eskalation", grund, von=self.haupt, nach=self.cfg["ziel"], ctx_alt=alt, ctx_neu=neu, skala=round(self.skala, 3))
        self.log(f"ESKALATION {self.haupt} → {self.cfg['ziel']} ({grund}); Token-Skalierung {self.skala:.2f}")

    def _zurueck(self, grund):
        if self.eskaliert:
            self._ereignis("zurueck", grund, von=self.cfg["ziel"], nach=self.haupt)
            self.eskaliert, self.skala = False, 1.0
            self.ereignisse = [(n, t) for n, t in self.ereignisse if n > self.n_req]  # Zähler neu beginnen

    # ---- vom Proxy aufgerufen -------------------------------------------------
    def anfrage(self, messages, system, target):
        """Beobachtet eine Anfrage und liefert das Ziel (evtl. umgelenkt). Nur das Hauptmodell wird umgelenkt."""
        with self.lock:
            self.n_req += 1
            msgs = messages or []
            sys_text = _text(system)
            letzte = _text(msgs[-1].get("content")) if msgs and isinstance(msgs[-1], dict) else ""
            if _COMPACT.search(letzte) or _COMPACT.search(sys_text):
                self._notiere("compact", "Zusammenfassungs-Anfrage von Claude Code")
            tu = []
            for m in msgs:
                if not isinstance(m, dict) or not isinstance(m.get("content"), list):
                    continue
                for b in m["content"]:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_result" and b.get("is_error") and b.get("tool_use_id") not in self.gesehen:
                        self.gesehen.add(b.get("tool_use_id"))
                        self._notiere("tool_fehler", _text(b.get("content"))[:80])
                    elif b.get("type") == "tool_use":
                        tu.append(b.get("name", "") + json.dumps(b.get("input"), sort_keys=True, default=str))
            if tu:
                letzte_n = tu[-12:]
                for k in set(letzte_n):
                    n = letzte_n.count(k)
                    if n >= self.cfg["schleife_max"] and self.gemeldet_schleife.get(k) != n:
                        self.gemeldet_schleife[k] = n
                        self._notiere("schleife", f"{k[:60]} x{n}")
            if self.eskaliert and self.cfg["zurueck_nach"] and self.n_req - self.seit[0] >= self.cfg["zurueck_nach"]:
                self._zurueck(f"nach {self.cfg['zurueck_nach']} Anfragen")
            self._pruefe()
            if not self.cfg["aktiv"] and self.eskaliert:
                self._zurueck("abgeschaltet")
            return self.cfg["ziel"] if (self.eskaliert and str(target) == self.haupt) else target

    def melde(self, typ, detail=""):
        """typ: backend_fehler | abbruch | ueberlauf"""
        with self.lock:
            self._notiere(typ, detail)
            self._pruefe()

    def skala_fuer(self, target):
        return self.skala if (self.eskaliert and str(target) == self.cfg["ziel"]) else 1.0

    # ---- Steuerung von außen --------------------------------------------------
    def setze(self, d):
        with self.lock:
            for k, v in (d or {}).items():
                if k in ("aktiv", "skalieren"):
                    self.cfg[k] = bool(v)
                elif k == "ziel":
                    self.cfg[k] = self._norm(v)
                elif k in SCHLUESSEL_INT:
                    self.cfg[k] = max(0, int(v))
            self._ereignis("konfig", json.dumps({k: self.cfg[k] for k in d if k in self.cfg}, ensure_ascii=False))
            if d.get("jetzt") and self.cfg["ziel"] and not self.eskaliert:
                self.cfg["aktiv"] = True
                self._eskaliere("manuell (von außen)")
            if d.get("zurueck"):
                self._zurueck("manuell (von außen)")
            if not self.cfg["aktiv"] and self.eskaliert:
                self._zurueck("abgeschaltet")
            return self.status_unlocked()

    def status_unlocked(self):
        z = {t: self._zaehle((t,)) for t in ("compact", "tool_fehler", "backend_fehler", "abbruch", "schleife", "ueberlauf")}
        return {"konfig": dict(self.cfg), "haupt": self.haupt, "aktuell": self.aktuell(), "eskaliert": self.eskaliert,
                "skalierung": round(self.skala, 3), "anfragen": self.n_req, "im_fenster": z,
                "seit": {"anfrage": self.seit[0], "grund": self.seit[2]} if self.seit else None}

    def status(self):
        with self.lock:
            return self.status_unlocked()


# ---- Bericht --------------------------------------------------------------------------
def _lese(f):
    out = []
    try:
        for line in open(f, encoding="utf-8"):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    except OSError:
        pass
    return out


def bericht(esc_file, usage_file=""):
    ev = _lese(esc_file)
    if not ev:
        return ""
    z = {}
    for e in ev:
        if e["typ"] not in ("konfig", "eskalation", "zurueck"):
            z[e["typ"]] = z.get(e["typ"], 0) + 1
    esk = [e for e in ev if e["typ"] in ("eskalation", "zurueck")]
    konfig = [e for e in ev if e["typ"] == "konfig"]
    if not esk and not konfig and not z:
        return ""
    zeilen = ["Eskalations-Statistik:"]
    namen = {"compact": "Kompaktierungen", "tool_fehler": "Tool-Fehler", "backend_fehler": "Backend-Fehler",
             "abbruch": "Abbrüche", "schleife": "Schleifen", "ueberlauf": "Kontext-Überläufe"}
    zeilen.append("  Ereignisse: " + (", ".join(f"{namen.get(k, k)} {v}" for k, v in z.items()) or "keine"))
    for e in esk:
        uhr = time.strftime("%H:%M:%S", time.localtime(e["ts"]))
        if e["typ"] == "eskalation":
            zeilen.append(f"  ⬆ {uhr} nach Anfrage {e['req']}: {e.get('von')} → {e.get('nach')}  ({e['detail']}); "
                          f"Kontext {e.get('ctx_alt') or '?'} → {e.get('ctx_neu') or '?'}, Token-Skalierung {e.get('skala')}")
        else:
            zeilen.append(f"  ⬇ {uhr} nach Anfrage {e['req']}: zurück auf {e.get('nach')}  ({e['detail']})")
    if not esk:
        zeilen.append("  Keine Eskalation ausgelöst" + (" (Funktion war aktiv)." if any('"aktiv": true' in k["detail"] for k in konfig) else "."))
    if usage_file:
        u = _lese(usage_file)
        if u:
            je = {}
            for e in u:
                t = je.setdefault(e["model"], [0, 0, 0])
                t[0] += 1; t[1] += e["in"]; t[2] += e["out"]
            zeilen.append("  Anfragen je Modell: " + ", ".join(
                f"{m} {t[0]}× ({t[1]:,} ein / {t[2]:,} aus)".replace(",", ".") for m, t in je.items()))
    return "\n".join(zeilen)


# ---- Steuerung laufender Proxys (CLI und MCP) -----------------------------------------
REG_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "clau", "proxies")


def proxies():
    """Laufende owl_proxy-Instanzen aus der Registry (tote Einträge werden entfernt)."""
    out = []
    try:
        namen = sorted(os.listdir(REG_DIR))
    except OSError:
        return out
    for n in namen:
        try:
            d = json.load(open(os.path.join(REG_DIR, n), encoding="utf-8"))
            os.kill(d["pid"], 0)
            out.append(d)
        except (OSError, ValueError, KeyError):
            try:
                os.remove(os.path.join(REG_DIR, n))
            except OSError:
                pass
    return out


def proxy_waehlen(port=None, cwd=None):
    ps = proxies()
    if port is not None:
        ps = [p for p in ps if p["port"] == int(port)]
    if cwd is not None:
        ps = [p for p in ps if os.path.realpath(p.get("cwd", "")) == os.path.realpath(cwd)]
    if not ps:
        raise RuntimeError("Kein laufender owl_proxy" + (f" auf Port {port}" if port else "") + (f" in {cwd}" if cwd else ""))
    if len(ps) > 1:
        raise RuntimeError("Mehrere Proxys laufen, bitte Port angeben: " + ", ".join(
            f"{p['port']} ({p['modell']}, {p['cwd']})" for p in ps))
    return ps[0]


def anfrage_proxy(pfad="/", daten=None, port=None, cwd=None, timeout=40, stream=False):
    """HTTP-Aufruf an den Steuer-Port eines Proxys (mit Token). daten None = GET, sonst POST (JSON)."""
    import urllib.request
    p = proxy_waehlen(port, cwd)
    req = urllib.request.Request(f"http://127.0.0.1:{p['steuerung']}{pfad}", method="POST" if daten is not None else "GET",
                                 data=json.dumps(daten).encode() if daten is not None else None,
                                 headers={"Content-Type": "application/json", "X-Clau-Token": p.get("token", "")})
    r = urllib.request.urlopen(req, timeout=timeout)
    if stream:
        return r, p
    with r:
        return dict(json.load(r), proxy={"port": p["port"], "cwd": p["cwd"], "modell": p["modell"]})


def steuern(daten=None, port=None):
    """Eskalation: GET (daten=None) oder POST an die Steuerung eines Proxys."""
    return anfrage_proxy("/", daten, port)


def _ctl(argv):
    port = None
    if len(argv) > 1 and argv[0] == "--port":
        port, argv = argv[1], argv[2:]
    cmd = argv[0] if argv else "status"
    d = {"status": None, "an": {"aktiv": True}, "aus": {"aktiv": False}, "jetzt": {"jetzt": True},
         "zurueck": {"zurueck": True}}.get(cmd, "?")
    if cmd == "ziel" and len(argv) > 1:
        d = {"ziel": argv[1]}
    elif cmd == "set":
        d = {}
        for kv in argv[1:]:
            k, _, v = kv.partition("=")
            d[k] = {"true": True, "false": False}.get(v.lower(), int(v) if v.isdigit() else v)
    if d == "?":
        print("Befehle: status | an | aus | jetzt | zurueck | ziel <id> | set k=v ...  (optional: --port P vorneweg)")
        return 2
    try:
        print(json.dumps(steuern(d, port), ensure_ascii=False, indent=1))
    except Exception as e:
        print(f"Fehler: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "ctl":
        sys.exit(_ctl(sys.argv[2:]))
    if len(sys.argv) > 2 and sys.argv[1] == "report":
        t = bericht(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
        if t:
            print(t)
    else:
        print(__doc__)
