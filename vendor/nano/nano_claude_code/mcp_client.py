"""Minimaler MCP-Client (stdio, newline-delimited JSON-RPC) für nano.

Konfiguration: Env NANO_MCP_CONFIG = Pfad zu einer JSON-Datei im Claude-Code-Format
{"mcpServers": {"name": {"command": ..., "args": [...], "env": {...}}}}.
Tools erscheinen als mcp__<server>__<tool>.
"""

from __future__ import annotations

import atexit
import json
import os
import queue
import subprocess
import sys
import threading
from typing import Any

PROTOCOL = "2024-11-05"
INIT_TIMEOUT = 20.0
LIST_TIMEOUT = 20.0
CALL_TIMEOUT = float(os.environ.get("NANO_MCP_CALL_TIMEOUT") or 300)


class McpServer:
    def __init__(self, name: str, spec: dict[str, Any]):
        self.name = name
        self.spec = spec
        self.proc: subprocess.Popen | None = None
        self.lines: "queue.Queue[str | None]" = queue.Queue()
        self.next_id = 0
        self.lock = threading.Lock()
        self.tools: list[dict[str, Any]] = []

    def start(self) -> None:
        env = dict(os.environ)
        env.update({str(k): str(v) for k, v in (self.spec.get("env") or {}).items()})
        self.proc = subprocess.Popen(
            [self.spec["command"], *[str(a) for a in self.spec.get("args", [])]],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1, env=env,
        )
        threading.Thread(target=self._reader, daemon=True).start()
        self._request("initialize", {
            "protocolVersion": PROTOCOL, "capabilities": {},
            "clientInfo": {"name": "nano-claude-code", "version": "0.2.0"},
        }, INIT_TIMEOUT)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        cursor = None
        while True:
            res = self._request("tools/list", {"cursor": cursor} if cursor else {}, LIST_TIMEOUT)
            self.tools.extend(res.get("tools", []))
            cursor = res.get("nextCursor")
            if not cursor:
                break

    def _reader(self) -> None:
        assert self.proc and self.proc.stdout
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _send(self, msg: dict[str, Any]) -> None:
        assert self.proc and self.proc.stdin
        self.proc.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def _request(self, method: str, params: dict[str, Any], timeout: float) -> dict[str, Any]:
        with self.lock:
            self.next_id += 1
            rid = self.next_id
            self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            while True:
                try:
                    line = self.lines.get(timeout=timeout)
                except queue.Empty:
                    raise TimeoutError(f"MCP {self.name}: keine Antwort auf {method} nach {timeout:.0f}s")
                if line is None:
                    raise RuntimeError(f"MCP {self.name}: Server beendet")
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("id") != rid:
                    continue  # Notifications / Server-Requests ignorieren
                if "error" in msg:
                    raise RuntimeError(f"MCP {self.name}: {msg['error'].get('message', msg['error'])}")
                return msg.get("result") or {}

    def call(self, tool: str, arguments: dict[str, Any]) -> str:
        res = self._request("tools/call", {"name": tool, "arguments": arguments}, CALL_TIMEOUT)
        parts = []
        for c in res.get("content", []):
            if c.get("type") == "text":
                parts.append(c.get("text", ""))
            else:
                parts.append(f"[{c.get('type', 'inhalt')} nicht darstellbar]")
        text = "\n".join(parts) if parts else json.dumps(res, ensure_ascii=False)
        return f"Error: {text}" if res.get("isError") else text

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


_servers: dict[str, McpServer] | None = None


def _load() -> dict[str, McpServer]:
    global _servers
    if _servers is not None:
        return _servers
    _servers = {}
    path = os.environ.get("NANO_MCP_CONFIG")
    if not path:
        return _servers
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f).get("mcpServers", {})
    except (OSError, ValueError) as e:
        print(f"[mcp] Konfiguration unlesbar: {e}", file=sys.stderr)
        return _servers
    for name, spec in cfg.items():
        if spec.get("type", "stdio") != "stdio" or "command" not in spec or "__" in name:
            print(f"[mcp] {name}: nur stdio-Server unterstützt, übersprungen", file=sys.stderr)
            continue
        srv = McpServer(name, spec)
        try:
            srv.start()
        except Exception as e:
            print(f"[mcp] {name}: Start fehlgeschlagen: {e}", file=sys.stderr)
            srv.stop()
            continue
        _servers[name] = srv
    atexit.register(lambda: [s.stop() for s in _servers.values()])
    return _servers


def mcp_tool_defs() -> list[dict[str, Any]]:
    defs = []
    for name, srv in _load().items():
        for t in srv.tools:
            defs.append({
                "name": f"mcp__{name}__{t['name']}",
                "description": t.get("description", ""),
                "input_schema": t.get("inputSchema") or {"type": "object", "properties": {}},
            })
    return defs


def is_mcp_tool(name: str) -> bool:
    return name.startswith("mcp__")


def call_mcp_tool(name: str, arguments: dict[str, Any]) -> str:
    try:
        _, server, tool = name.split("__", 2)
        srv = _load()[server]
    except (ValueError, KeyError):
        return f"Error: unknown MCP tool '{name}'"
    try:
        return srv.call(tool, arguments)
    except Exception as e:
        return f"Error in {name}: {type(e).__name__}: {e}"
