#!/usr/bin/env python3
"""
atomic_setup.py — Hilfsbaustein für die optionale Engine "atomic" (https://github.com/bastani-inc/atomic, MIT).

atomic ist eine eigene Agent-Laufzeit (TypeScript, pi-Abkömmling). ccclau bindet sie nur als zusätzliche Engine ein
(kein Fork, nichts vendored): die Quelle wird bei Bedarf von GitHub geholt (clau.sh: _ensure_atomic).
Dieses Skript erzeugt die isolierte Konfiguration unter ~/.local/share/clau/atomic/agent/models.json:
  * Provider "direkt…": die Direkt-Modelle aus backends.json/_quellen (z.B. Karten-Tor), OpenAI-kompatibel
  * Provider "owl": QuiteQue /v1 (nur wenn erreichbar), mit den üblichen Zuordnungs-Headern

  atomic_setup.py sync                  models.json schreiben
  atomic_setup.py model-arg <owl:ID>    "provider/modell-id" für atomic --model
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backends  # noqa: E402

AGENT_DIR = os.environ.get("CLAU_ATOMIC_AGENT_DIR") or os.path.join(
    os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "clau", "atomic", "agent")
OWL_BASE = os.environ.get("OWL_BASE_URL", "http://11.0.0.13:7077").rstrip("/")
COMPAT = {"supportsDeveloperRole": False, "supportsReasoningEffort": False}  # llama.cpp & Co. kennen beides nicht


def _provider_name(url, urls):
    return "direkt" if urls.index(url) == 0 else f"direkt{urls.index(url) + 1}"


def _modell(mid, name, ctx):
    m = {"id": mid, "name": name, "input": ["text"], "reasoning": True,
         "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}
    if ctx:
        m["contextWindow"] = int(ctx)
        m["maxTokens"] = int(min(32768, max(4096, ctx // 4)))
    return m


def _quitequeue_modelle():
    """Chat-Modelle von QuiteQue (nur wenn erreichbar). -> [(id, name, ctx)]"""
    hdr = {"X-User": os.environ.get("CLAU_USER_TAG") or os.environ.get("USER", "clau"),
           "X-Agent-Tool": os.environ.get("CLAU_AGENT_TOOL") or "ccclau-atomic"}
    try:
        req = urllib.request.Request(OWL_BASE + "/v1/models", headers=hdr)
        with urllib.request.urlopen(req, timeout=2.5) as r:
            data = json.load(r).get("data") or []
    except Exception:
        return []
    out = []
    for m in data:
        ctx = m.get("context_window") or 0
        if ctx <= 0 or m.get("status") == "DISABLED" or m.get("owned_by") in ("searchllm", "ohrwurm"):
            continue
        out.append((str(m.get("numerical_id") or m["id"]), (m.get("name") or "")[:70], ctx))
    return out


def sync():
    cfg = backends.load()
    urls = []
    for e in cfg.values():
        if e["url"] not in urls:
            urls.append(e["url"])
    providers = {}
    for url in urls:
        key = _provider_name(url, urls)
        entry = {"baseUrl": url, "api": "openai-completions", "compat": COMPAT,
                 "apiKey": next((e["api_key"] for e in cfg.values() if e["url"] == url and e["api_key"]), "") or "lokal", "models": []}
        gesehen = set()
        for e in cfg.values():
            if e["url"] == url and e["model"] not in gesehen:
                gesehen.add(e["model"])
                entry["models"].append(_modell(e["model"], e["name"], e["ctx"]))
        providers[key] = entry
    qq = _quitequeue_modelle()
    if qq:
        headers = {"X-OwlTrail-User": os.environ.get("CLAU_QQ_USER", "ccclau"),
                   "X-Agent-Tool": os.environ.get("OWL_HDR_AGENT_TOOL", "ccclau-atomic")}
        for k, env in (("X-Request-Context", "OWL_HDR_REQUEST_CONTEXT"), ("X-Project", "OWL_HDR_PROJECT"), ("X-User", "OWL_HDR_USER")):
            if os.environ.get(env):
                headers[k] = os.environ[env]
        providers["owl"] = {"baseUrl": OWL_BASE + "/v1", "api": "openai-completions", "compat": COMPAT, "apiKey": "owl",
                            "headers": headers, "models": [_modell(i, n, c) for i, n, c in qq]}
    os.makedirs(AGENT_DIR, exist_ok=True)
    path = os.path.join(AGENT_DIR, "models.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"providers": providers}, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)
    return path, {k: len(v["models"]) for k, v in providers.items()}


def model_arg(spec):
    """owl:d137 / owl:d-<name> -> direkt/<modell>; owl:137 -> owl/137."""
    mid = spec[4:] if spec.startswith("owl:") else spec
    cfg = backends.load()
    if mid in cfg:
        urls = []
        for e in cfg.values():
            if e["url"] not in urls:
                urls.append(e["url"])
        return f"{_provider_name(cfg[mid]['url'], urls)}/{cfg[mid]['model']}"
    return f"owl/{mid}"


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
