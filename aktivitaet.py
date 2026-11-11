#!/usr/bin/env python3
"""
aktivitaet.py — Denkprotokoll und Fortschritt einer clau-Session, mitgeschnitten im owl_proxy (Default AUS).

Der Proxy sieht den ganzen Stream: Denken (reasoning_content), Zwischentext, Tool-Aufrufe, und in der nächsten Anfrage
die Tool-Ergebnisse. Eingeschaltet (CLAU_TRACE=1, per Steuerung `clau --verfolgen an` oder MCP `trace_setzen`) landen sie
als nummerierte Ereignisse in einem Ring-Puffer (optional zusätzlich als JSONL-Datei) und lassen sich abfragen:
  * lesen(seit)        Ereignisse seit Nummer N (Polling, z.B. MCP aktivitaet_lesen)
  * fortschritt()      Kurzstand: was passiert gerade, die letzten größeren Schritte, Zähler
  * live-Strom (SSE)   /stream am Steuer-Port des Proxys (clau --verfolgen live)

Ereignisarten: auftrag, anfrage, denken, text, tool, tool_ergebnis, schritt_ende, eskalation, konfig.
Ein "Schritt" ist eine Modellantwort (Denken + Text + Tool-Aufrufe) – die größeren Etappen zwischen den Werkzeugläufen.
"""
import json
import os
import sys
import threading
import time

MAX_TEXT = 4000
MAX_DATEI = 20 * 1024 * 1024
ARTEN = ("auftrag", "anfrage", "denken", "text", "tool", "tool_ergebnis", "schritt_ende", "eskalation", "konfig")


def _t(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") if isinstance(b, dict) and b.get("type") == "text" else
                         (b.get("content", "") if isinstance(b, dict) and isinstance(b.get("content"), str) else "")
                         for b in content)
    return ""


class Schritt:
    def __init__(self, nr, modell):
        self.nr, self.modell, self.t0 = nr, modell, time.monotonic()
        self.buf = {"denken": "", "text": ""}
        self.letzter_flush = time.monotonic()
        self.denken_zeichen = 0
        self.text_gesamt = ""
        self.tools = []


class Aktivitaet:
    def __init__(self, hauptmodell, datei="", aktiv=False, ring=1500):
        self.haupt = str(hauptmodell)
        self.datei = datei
        self.aktiv = aktiv
        self.ring = []
        self.max_ring = ring
        self.seq = 0
        self.cv = threading.Condition()
        self.nr = 0
        self.gesehen = set()
        self.datei_bytes = 0
        self.zaehler = {"schritte": 0, "tools": 0, "tool_fehler": 0}

    # ---- Aufnahme ------------------------------------------------------------------
    def setze(self, aktiv):
        with self.cv:
            self.aktiv = bool(aktiv)
        self._emit("konfig", aktiv=bool(aktiv))
        return self.aktiv

    def _emit(self, typ, **d):
        if not self.aktiv and typ != "konfig":
            return
        e = {"typ": typ, "ts": round(time.time(), 2)}
        e.update(d)
        with self.cv:
            self.seq += 1
            e["seq"] = self.seq
            self.ring.append(e)
            if len(self.ring) > self.max_ring:
                del self.ring[:len(self.ring) - self.max_ring]
            self.cv.notify_all()
        if self.datei and self.datei_bytes < MAX_DATEI:
            try:
                z = json.dumps(e, ensure_ascii=False) + "\n"
                with open(self.datei, "a", encoding="utf-8") as f:
                    f.write(z)
                self.datei_bytes += len(z)
            except OSError:
                pass

    def anfrage(self, messages, system, modell, est_tokens, neue_aktion):
        """Beginn einer Modellanfrage. Liefert ein Schritt-Handle (None = aus)."""
        if not self.aktiv:
            return None
        msgs = messages or []
        namen = {}
        for m in msgs:
            if isinstance(m, dict) and isinstance(m.get("content"), list):
                for b in m["content"]:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        namen[b.get("id")] = b.get("name", "")
        for m in msgs:
            if isinstance(m, dict) and isinstance(m.get("content"), list):
                for b in m["content"]:
                    if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") not in self.gesehen:
                        self.gesehen.add(b.get("tool_use_id"))
                        ok = not b.get("is_error")
                        self.zaehler["tool_fehler"] += 0 if ok else 1
                        self._emit("tool_ergebnis", name=namen.get(b.get("tool_use_id"), ""), ok=ok,
                                   kurz=_t(b.get("content"))[:300])
        if neue_aktion and msgs and isinstance(msgs[-1], dict):
            c = msgs[-1].get("content")
            teile = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"] if isinstance(c, list) else [str(c or "")]
            echt = [t for t in teile if t.strip() and not t.lstrip().startswith("<system-reminder>")]  # Claude Code hängt Erinnerungen an
            self._emit("auftrag", text=(echt[-1] if echt else (teile[-1] if teile else ""))[:500])
        self.nr += 1
        h = Schritt(self.nr, str(modell))
        self._emit("anfrage", nr=h.nr, modell=h.modell, tokens_ca=est_tokens)
        return h

    def delta(self, h, art, text):
        if h is None or not text:
            return
        andere = "text" if art == "denken" else "denken"
        if h.buf[andere]:
            self._flush(h)  # Reihenfolge Denken -> Text erhalten
        h.buf[art] += text
        if art == "denken":
            h.denken_zeichen += len(text)
        else:
            h.text_gesamt += text
        if len(h.buf[art]) >= 300 or time.monotonic() - h.letzter_flush >= 0.7:
            self._flush(h)

    def _flush(self, h):
        for art in ("denken", "text"):
            if h.buf[art]:
                self._emit(art, nr=h.nr, text=h.buf[art][:MAX_TEXT])
                h.buf[art] = ""
        h.letzter_flush = time.monotonic()

    def tool(self, h, name, args):
        if h is None:
            return
        self._flush(h)
        self.zaehler["tools"] += 1
        h.tools.append(name)
        self._emit("tool", nr=h.nr, name=name, eingabe=(args or "")[:600])

    def ende(self, h, stop_reason="", tok_in=0, tok_out=0):
        if h is None:
            return
        self._flush(h)
        self.zaehler["schritte"] += 1
        self._emit("schritt_ende", nr=h.nr, modell=h.modell, dauer_s=round(time.monotonic() - h.t0, 1),
                   tokens_ein=int(tok_in or 0), tokens_aus=int(tok_out or 0), stop=stop_reason,
                   denken_zeichen=h.denken_zeichen, kurz=h.text_gesamt.strip()[:200], tools=h.tools)

    def ereignis(self, typ, **d):
        self._emit(typ, **d)

    # ---- Abfrage -------------------------------------------------------------------
    def lesen(self, seit=0, arten=None, maximal=200, warte_s=0.0):
        """Ereignisse mit seq > seit. warte_s > 0: bis dahin auf neue warten (Long-Polling)."""
        arten = set(arten or [])
        ende = time.monotonic() + warte_s
        with self.cv:
            while True:
                neu = [e for e in self.ring if e["seq"] > seit and (not arten or e["typ"] in arten)]
                if neu or time.monotonic() >= ende:
                    break
                self.cv.wait(timeout=max(0.05, ende - time.monotonic()))
            erster = self.ring[0]["seq"] if self.ring else 0
            verpasst = bool(seit and erster > seit + 1)
            neu = neu[-maximal:] if maximal else neu
            return {"aktiv": self.aktiv, "ereignisse": neu, "naechste": self.seq, "luecke": verpasst}

    def fortschritt(self, n=8):
        with self.cv:
            ring = list(self.ring)
        letzte = ring[-1] if ring else None
        schritte = [e for e in ring if e["typ"] == "schritt_ende"][-n:]
        auftrag = next((e["text"] for e in reversed(ring) if e["typ"] == "auftrag"), "")
        zustand = "keine Daten" if letzte is None else "leerlauf"
        if letzte is not None:
            alter = time.time() - letzte["ts"]
            if letzte["typ"] in ("anfrage", "denken"):
                zustand = "denkt" if alter < 600 else "unklar (lange still)"
            elif letzte["typ"] == "text":
                zustand = "schreibt"
            elif letzte["typ"] == "tool":
                zustand = f"führt Werkzeug aus: {letzte.get('name')}"
            elif letzte["typ"] == "tool_ergebnis":
                zustand = "wertet Werkzeugergebnis aus"
            elif letzte["typ"] == "schritt_ende":
                zustand = "Schritt beendet, wartet auf Werkzeug/Eingabe"
        letzter_text = next((e["text"] for e in reversed(ring) if e["typ"] == "text"), "")
        return {"aktiv": self.aktiv, "zustand": zustand, "auftrag": auftrag, "anfragen": self.nr, **self.zaehler,
                "letzte_schritte": [{"nr": e["nr"], "modell": e["modell"], "dauer_s": e["dauer_s"], "kurz": e["kurz"],
                                     "tools": e["tools"], "tokens": f"{e['tokens_ein']}/{e['tokens_aus']}"} for e in schritte],
                "letzter_text": letzter_text[-600:], "naechste": self.seq}


# ---- Client: CLI (clau --verfolgen) und Formatierung ---------------------------------
def formatiere(e):
    uhr = time.strftime("%H:%M:%S", time.localtime(e["ts"]))
    t = e["typ"]
    if t == "denken":
        return f"{uhr} 💭 {e['text'].strip()}"
    if t == "text":
        return f"{uhr} 💬 {e['text'].strip()}"
    if t == "tool":
        return f"{uhr} 🔧 {e['name']} {e.get('eingabe', '')[:160]}"
    if t == "tool_ergebnis":
        return f"{uhr} {'✓' if e['ok'] else '✗'} {e.get('name', '')}: {e.get('kurz', '')[:160].strip()}"
    if t == "schritt_ende":
        return f"{uhr} ── Schritt {e['nr']} ({e['modell']}, {e['dauer_s']} s, {e['tokens_ein']}/{e['tokens_aus']} Token, Denken {e['denken_zeichen']} Z.)"
    if t == "auftrag":
        return f"{uhr} ▶ {e['text'][:200].strip()}"
    if t == "eskalation":
        pfeil = {"eskalation": "⬆", "zurueck": "⬇"}.get(e.get("art"), "⚠")
        return f"{uhr} {pfeil} {e.get('art')}: {e.get('detail', '')}"
    if t == "anfrage":
        return f"{uhr} · Anfrage {e['nr']} an {e['modell']}"
    return f"{uhr} {t} {json.dumps({k: v for k, v in e.items() if k not in ('typ', 'ts', 'seq')}, ensure_ascii=False)}"


def _cli(argv):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import eskalation
    port = None
    if len(argv) > 1 and argv[0] == "--port":
        port, argv = argv[1], argv[2:]
    cmd = argv[0] if argv else "status"
    try:
        if cmd == "status":
            print(json.dumps(eskalation.anfrage_proxy("/fortschritt", port=port), ensure_ascii=False, indent=1))
        elif cmd == "lesen":
            r = eskalation.anfrage_proxy(f"/aktivitaet?seit={int(argv[1]) if len(argv) > 1 else 0}&max=200", port=port)
            for e in r["ereignisse"]:
                print(formatiere(e))
            print(f"# naechste={r['naechste']} aktiv={r['aktiv']}")
        elif cmd in ("an", "aus"):
            print(json.dumps(eskalation.anfrage_proxy("/trace", {"aktiv": cmd == "an"}, port=port)))
        elif cmd == "live":
            resp, p = eskalation.anfrage_proxy("/stream", port=port, stream=True, timeout=3600)
            print(f"# live von Proxy :{p['port']} ({p['modell']}) – Strg+C beendet; Protokoll muss an sein (clau --verfolgen an)", file=sys.stderr)
            for raw in resp:
                z = raw.decode("utf-8", "replace").rstrip("\n")
                if z.startswith("data: "):
                    print(formatiere(json.loads(z[6:])), flush=True)
        else:
            print("Befehle: status | lesen [seit] | live | an | aus   (optional: --port P vorneweg)")
            return 2
    except KeyboardInterrupt:
        return 0
    except Exception as e:
        print(f"Fehler: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "ctl":
        sys.exit(_cli(sys.argv[2:]))
    print(__doc__)
