#!/usr/bin/env python3
"""
pi_setup.py — Hilfsbaustein für die optionale Engine "pi" (https://github.com/earendil-works/pi, MIT).

pi (pi-coding-agent) ist ein minimalistischer Terminal-Coding-Agent. ccclau bindet ihn nur als zusätzliche Engine
ein (nichts vendored): das Linux-Release wird bei Bedarf von GitHub geholt (clau.sh: _ensure_pi, SHA256-geprüft).
Die models.json hat dasselbe Format wie bei atomic (atomic ist ein pi-Abkömmling), deshalb nutzt dieses Skript
atomic_setup.py mit eigenem Zielordner ($CLAU_PI_AGENT_DIR, Standard ~/.local/share/clau/pi/agent):
  * Provider "direkt…": Direkt-Modelle aus backends.json  * Provider "owl": QuiteQue /v1 (wenn erreichbar)

  pi_setup.py sync                  models.json schreiben
  pi_setup.py model-arg <owl:ID>    "provider/modell-id" für pi --model
"""
import os
import sys

os.environ.setdefault("CLAU_AGENT_TOOL", "ccclau-pi")
os.environ.setdefault("OWL_HDR_AGENT_TOOL", "ccclau-pi")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import atomic_setup as _a  # noqa: E402

_a.AGENT_DIR = os.environ.get("CLAU_PI_AGENT_DIR") or os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "clau", "pi", "agent")

sync = _a.sync
model_arg = _a.model_arg

if __name__ == "__main__":
    c = sys.argv[1] if len(sys.argv) > 1 else ""
    if c == "sync":
        p, n = sync()
        print(f"{p}  " + ", ".join(f"{k}: {v} Modelle" for k, v in n.items()))
    elif c == "model-arg" and len(sys.argv) > 2:
        print(model_arg(sys.argv[2]))
    else:
        print(__doc__)
        sys.exit(2)
