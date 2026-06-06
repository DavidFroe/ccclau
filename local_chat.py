#!/usr/bin/env python3
"""CLI-Chat-Client für owlAPI (OpenAI-kompatibel, Port 4040)."""

import sys
import json
import os
import argparse
import requests

OWL_BASE_URL = "http://11.0.0.1:4040/v1"
TIMEOUT = 120

# Kuratierte Modell-Gruppen für das Menü
# Format: (owl-ID, Label, Kosten-Hinweis)
OWL_MENU_GROUPS = {
    "lokal": [
        ("120",  "Qwen3.6-27B Q6_K    (PropellerA, Coding+Vision)",  "GRATIS"),
        ("121",  "Qwopus-9B           (PropellerA, schnell)",         "GRATIS"),
        ("124",  "Gemma-12B           (lokal)",                       "GRATIS"),
    ],
    "free-cloud": [
        ("38",   "QwQ-Plus            (Alibaba, Reasoning)",          "GRATIS"),
        ("113",  "Grok-4.3            (xAI)",                         "GRATIS"),
        ("316",  "Qwen3-Coder         (OR Free)",                     "GRATIS"),
        ("116",  "Websearch-schnell   (SearchLLM)",                   "GRATIS"),
        ("117",  "Websearch-gründlich (SearchLLM)",                   "GRATIS"),
    ],
    "günstig": [
        ("35",   "Qwen3.5-Flash       (Alibaba)",                     "$0.05/$0.15"),
        ("503",  "Gemini-2.5-Flash-Lite (Google)",                    "$0.10/$0.40"),
        ("71",   "GPT-4.1-mini        (OpenAI)",                      "$0.40/$1.60"),
        ("250",  "DeepSeek-V4-Flash   (DeepSeek)",                    "$0.14/$0.28"),
    ],
    "stark": [
        ("21",   "Claude-Sonnet-4.6   (Anthropic via owl)",           "$3.00/$15.00"),
        ("501",  "Gemini-2.5-Pro      (Google)",                      "$1.25/$10.00"),
        ("84",   "GPT-5               (OpenAI)",                      "$1.25/$10.00"),
        ("357",  "Claude-Opus-4.8     (OpenRouter)",                  "$5.00/$25.00"),
        ("43",   "Qwen3-Coder-Plus    (Alibaba)",                     "$0.40/$2.40"),
    ],
}


def stream_chat(model_id, messages):
    payload = {
        "model": model_id,
        "messages": messages,
        "stream": True,
        "stream_options": {"include_usage": True},
    }

    try:
        resp = requests.post(
            f"{OWL_BASE_URL}/chat/completions",
            json=payload,
            headers={"Content-Type": "application/json"},
            stream=True,
            timeout=TIMEOUT,
        )
        resp.raise_for_status()
    except requests.exceptions.ConnectionError:
        print(f"\n[Fehler: owlAPI nicht erreichbar – {OWL_BASE_URL}]", file=sys.stderr)
        return None, None
    except requests.exceptions.HTTPError as e:
        print(f"\n[HTTP-Fehler: {e}]", file=sys.stderr)
        return None, None
    except requests.exceptions.Timeout:
        print(f"\n[Fehler: Timeout nach {TIMEOUT}s]", file=sys.stderr)
        return None, None

    full = ""
    usage_info = None

    for line in resp.iter_lines():
        if not line:
            continue
        if not line.startswith(b"data: "):
            continue
        data = line[6:]
        if data == b"[DONE]":
            break
        try:
            chunk = json.loads(data)
            # Letzter Chunk mit usage
            if chunk.get("usage"):
                usage_info = chunk["usage"]
            delta = chunk.get("choices", [{}])[0].get("delta", {}).get("content", "")
            if delta:
                print(delta, end="", flush=True)
                full += delta
        except (json.JSONDecodeError, KeyError, IndexError):
            pass

    print()
    return full, usage_info


def format_cost(usage):
    if not usage:
        return ""
    cost = usage.get("cost_usd") or usage.get("cost", {}).get("total_usd")
    if cost is None:
        return ""
    if cost == 0:
        return "  [GRATIS]"
    return f"  [${cost:.6f}]"


def pick_model_interactive():
    """Zeigt das Modell-Menü und gibt die gewählte ID zurück."""
    group_labels = {
        "lokal":      "Lokal / immer gratis",
        "free-cloud": "Cloud / gratis",
        "günstig":    "Cloud / günstig",
        "stark":      "Cloud / stark",
    }

    entries = []
    print()
    print("owlAPI – Modell wählen:")
    for group, label in group_labels.items():
        print(f"\n  [{label}]")
        for mid, desc, cost in OWL_MENU_GROUPS[group]:
            idx = len(entries) + 1
            entries.append(mid)
            print(f"  {idx:>3}) {mid:<6} {desc:<44} {cost}")

    print(f"\n    0) Modell-ID direkt eingeben (z.B. 35, 501, 38 …)")
    print()

    while True:
        try:
            choice = input(f"Auswahl [1-{len(entries)}, 0=direkt, Enter=1]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)

        if choice == "" or choice == "1":
            return entries[0]
        if choice == "0":
            try:
                mid = input("Modell-ID: ").strip()
                if mid:
                    return mid
            except (EOFError, KeyboardInterrupt):
                print()
                sys.exit(0)
        try:
            n = int(choice)
            if 1 <= n <= len(entries):
                return entries[n - 1]
        except ValueError:
            pass
        print(f"  Bitte 0-{len(entries)} eingeben.")


def run_interactive(model_id):
    try:
        import readline as rl
        histfile = os.path.expanduser("~/.local/share/ccclau/.owl_chat_history")
        try:
            rl.read_history_file(histfile)
        except FileNotFoundError:
            pass
        rl.set_history_length(500)
        have_readline = True
    except ImportError:
        have_readline = False
        histfile = None

    print(f"[owlAPI – Modell {model_id}]  Befehle: /new  /model  /exit  (Ctrl+C bricht Antwort ab)")
    print()

    messages = []
    session_cost = 0.0

    while True:
        try:
            user_input = input("Du: ").strip()
        except EOFError:
            print()
            break
        except KeyboardInterrupt:
            print()
            continue

        if not user_input:
            continue

        cmd = user_input.lower()
        if cmd in ("/exit", "/quit"):
            break
        if cmd == "/new":
            messages = []
            session_cost = 0.0
            print("[Neuer Chat – Kontext gelöscht]")
            continue
        if cmd == "/model":
            model_id = pick_model_interactive()
            messages = []
            session_cost = 0.0
            print(f"[Modell gewechselt auf {model_id} – Kontext gelöscht]")
            continue

        messages.append({"role": "user", "content": user_input})
        print("Assistent: ", end="", flush=True)

        try:
            reply, usage = stream_chat(model_id, messages)
        except KeyboardInterrupt:
            print("\n[Unterbrochen]")
            messages.pop()
            continue

        if reply is None:
            messages.pop()
            continue

        cost_str = format_cost(usage)
        if usage and usage.get("cost_usd"):
            session_cost += usage["cost_usd"]

        if cost_str or session_cost > 0:
            total_str = f"  Session: ${session_cost:.6f}" if session_cost > 0 else ""
            print(f"{cost_str}{total_str}")

        messages.append({"role": "assistant", "content": reply})
        print()

    if have_readline and histfile:
        try:
            import readline as rl
            rl.write_history_file(histfile)
        except Exception:
            pass


def run_headless(model_id, prompt):
    messages = [{"role": "user", "content": prompt}]
    reply, usage = stream_chat(model_id, messages)
    if reply is None:
        sys.exit(1)
    cost_str = format_cost(usage)
    if cost_str:
        print(cost_str, file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="owlAPI CLI-Chat")
    parser.add_argument("--model", "-m", default="", help="Modell-ID (z.B. 120, 35, 21)")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--prompt", "-p", default="")
    parser.add_argument("--list", action="store_true", help="Kuratierte Modelle anzeigen")
    args = parser.parse_args()

    if args.list:
        for group, entries in OWL_MENU_GROUPS.items():
            print(f"\n[{group}]")
            for mid, desc, cost in entries:
                print(f"  {mid:<6} {desc}  ({cost})")
        sys.exit(0)

    model_id = args.model
    if not model_id and not args.headless:
        model_id = pick_model_interactive()
    elif not model_id:
        print("--headless braucht --model", file=sys.stderr)
        sys.exit(1)

    if args.headless:
        if not args.prompt:
            print("--headless braucht --prompt", file=sys.stderr)
            sys.exit(1)
        run_headless(model_id, args.prompt)
    else:
        run_interactive(model_id)


if __name__ == "__main__":
    main()
