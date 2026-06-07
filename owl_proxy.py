#!/usr/bin/env python3
"""
owl_proxy.py — Anthropic-API → owlAPI (OpenAI-Format) Proxy
Lauscht auf localhost:PORT, übersetzt /v1/messages für claude CLI.
"""

import json
import os

import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests

OWL_BASE = os.environ.get("OWL_BASE_URL", "http://11.0.0.1:4040/v1")
OWL_MODEL = os.environ.get("OWL_MODEL", "120")
PORT = int(os.environ.get("OWL_PROXY_PORT", "8325"))
# ── Format-Konvertierung ───────────────────────────────────────────────────────

def content_to_str(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if b.get("type") == "text")
    return str(content)


def messages_ant_to_oai(messages, system=None):
    result = []
    if system:
        if isinstance(system, list):
            system = "\n".join(b.get("text", "") for b in system if b.get("type") == "text")
        result.append({"role": "system", "content": system})

    for msg in messages:
        role = msg["role"]
        content = msg["content"]

        if isinstance(content, str):
            result.append({"role": role, "content": content})
            continue

        text_blocks = [b for b in content if b.get("type") == "text"]
        tool_use_blocks = [b for b in content if b.get("type") == "tool_use"]
        tool_result_blocks = [b for b in content if b.get("type") == "tool_result"]

        if role == "assistant":
            if tool_use_blocks:
                tool_calls = []
                for tu in tool_use_blocks:
                    tool_calls.append({
                        "id": tu["id"],
                        "type": "function",
                        "function": {
                            "name": tu["name"],
                            "arguments": json.dumps(tu.get("input", {}))
                        }
                    })
                out = {"role": "assistant", "tool_calls": tool_calls}
                if text_blocks:
                    out["content"] = content_to_str(text_blocks)
                result.append(out)
            else:
                result.append({"role": "assistant", "content": content_to_str(content)})

        elif role == "user":
            if tool_result_blocks:
                for tr in tool_result_blocks:
                    tr_content = tr.get("content", "")
                    if isinstance(tr_content, list):
                        tr_content = content_to_str(tr_content)
                    result.append({
                        "role": "tool",
                        "tool_call_id": tr["tool_use_id"],
                        "content": tr_content or ""
                    })
                if text_blocks:
                    result.append({"role": "user", "content": content_to_str(text_blocks)})
            else:
                result.append({"role": "user", "content": content_to_str(content)})

    return result


def tools_ant_to_oai(tools):
    if not tools:
        return None
    return [{
        "type": "function",
        "function": {
            "name": t["name"],
            "description": t.get("description", ""),
            "parameters": t.get("input_schema", {"type": "object", "properties": {}})
        }
    } for t in tools]


def oai_resp_to_ant(oai_resp, model_name):
    choice = oai_resp.get("choices", [{}])[0]
    message = choice.get("message", {})
    content = []

    text = message.get("content") or message.get("reasoning_content") or ""
    if text:
        content.append({"type": "text", "text": text})

    for tc in message.get("tool_calls", []):
        try:
            inp = json.loads(tc["function"]["arguments"])
        except (json.JSONDecodeError, KeyError):
            inp = {}
        content.append({
            "type": "tool_use",
            "id": tc.get("id", "call_" + uuid.uuid4().hex[:8]),
            "name": tc["function"]["name"],
            "input": inp
        })

    usage = oai_resp.get("usage", {})
    has_tool_calls = bool(message.get("tool_calls"))
    stop_reason = "tool_use" if (choice.get("finish_reason") == "tool_calls" or has_tool_calls) else "end_turn"

    return {
        "id": "msg_" + uuid.uuid4().hex[:24],
        "type": "message",
        "role": "assistant",
        "content": content,
        "model": model_name,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0)
        }
    }


# ── Streaming-Übersetzer ───────────────────────────────────────────────────────

class StreamTranslator:
    def __init__(self, model_name):
        self.model = model_name
        self.msg_id = "msg_" + uuid.uuid4().hex[:24]
        self.text_started = False
        self.text_index = 0
        self.tool_buffers = {}   # oai_index → {id, name, args, block_index}
        self.output_tokens = 0

    def _evt(self, name, data):
        return f"event: {name}\ndata: {json.dumps(data)}\n\n"

    def start(self):
        return (
            self._evt("message_start", {
                "type": "message_start",
                "message": {
                    "id": self.msg_id, "type": "message", "role": "assistant",
                    "content": [], "model": self.model,
                    "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 0, "output_tokens": 0}
                }
            }) +
            self._evt("ping", {"type": "ping"})
        )

    def chunk(self, data):
        out = []
        choices = data.get("choices", [])

        if data.get("usage"):
            self.output_tokens = data["usage"].get("completion_tokens", self.output_tokens)

        if not choices:
            return ""

        choice = choices[0]
        delta = choice.get("delta", {})
        finish_reason = choice.get("finish_reason")

        # Text — some models (DeepSeek reasoning variants) put output in reasoning_content
        text = delta.get("content") or delta.get("reasoning_content") or ""
        if text:
            if not self.text_started:
                self.text_started = True
                out.append(self._evt("content_block_start", {
                    "type": "content_block_start", "index": self.text_index,
                    "content_block": {"type": "text", "text": ""}
                }))
            out.append(self._evt("content_block_delta", {
                "type": "content_block_delta", "index": self.text_index,
                "delta": {"type": "text_delta", "text": text}
            }))

        # Tool calls
        for tc in delta.get("tool_calls", []):
            oai_idx = tc.get("index", 0)
            block_idx = (1 if self.text_started else 0) + oai_idx

            if oai_idx not in self.tool_buffers:
                tid = tc.get("id") or ("call_" + uuid.uuid4().hex[:8])
                tname = (tc.get("function") or {}).get("name") or ""
                self.tool_buffers[oai_idx] = {"id": tid, "name": tname, "args": "", "bidx": block_idx}
                out.append(self._evt("content_block_start", {
                    "type": "content_block_start", "index": block_idx,
                    "content_block": {"type": "tool_use", "id": tid, "name": tname, "input": {}}
                }))

            buf = self.tool_buffers[oai_idx]
            if tc.get("id"):
                buf["id"] = tc["id"]
            func = tc.get("function") or {}
            if func.get("name"):
                buf["name"] = func["name"]
            args_delta = func.get("arguments") or ""
            if args_delta:
                buf["args"] += args_delta
                out.append(self._evt("content_block_delta", {
                    "type": "content_block_delta", "index": buf["bidx"],
                    "delta": {"type": "input_json_delta", "partial_json": args_delta}
                }))

        # Finish
        if finish_reason in ("stop", "tool_calls", "length"):
            # Empty response fallback — model returned nothing (content filter / refusal)
            if not self.text_started and not self.tool_buffers:
                self.text_started = True
                out.append(self._evt("content_block_start", {
                    "type": "content_block_start", "index": self.text_index,
                    "content_block": {"type": "text", "text": ""}
                }))
                out.append(self._evt("content_block_delta", {
                    "type": "content_block_delta", "index": self.text_index,
                    "delta": {"type": "text_delta",
                              "text": f"[Modell {OWL_MODEL} hat leere Antwort zurückgegeben — möglicherweise Inhaltsfilter. Bitte Anfrage umformulieren.]"}
                }))
            if self.text_started:
                out.append(self._evt("content_block_stop", {
                    "type": "content_block_stop", "index": self.text_index
                }))
            for buf in self.tool_buffers.values():
                out.append(self._evt("content_block_stop", {
                    "type": "content_block_stop", "index": buf["bidx"]
                }))
            stop_reason = "tool_use" if (finish_reason == "tool_calls" or self.tool_buffers) else "end_turn"
            out.append(self._evt("message_delta", {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": self.output_tokens}
            }))
            out.append(self._evt("message_stop", {"type": "message_stop"}))

        return "".join(out)


# ── HTTP-Handler ───────────────────────────────────────────────────────────────

class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # kein Log-Spam

    def _base_path(self):
        return self.path.split("?")[0]

    def do_HEAD(self):
        # Claude CLI sendet HEAD / als Health-Check
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        if "/health" in self.path:
            self._json(200, {"status": "ok", "proxy": "owl_proxy", "model": OWL_MODEL})
        else:
            self.send_response(200)
            self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n))
        except json.JSONDecodeError:
            self.send_error(400, "Bad JSON")
            return
        # Pfad ohne Query-String prüfen (claude sendet ?beta=true etc.)
        if not self._base_path().endswith("/messages"):
            self.send_error(404, f"Unknown: {self.path}")
            return
        self._handle(req)

    def _handle(self, req):
        model_name = req.get("model", "claude-sonnet-4-6")
        stream = req.get("stream", False)

        oai_payload = {
            "model": OWL_MODEL,
            "messages": messages_ant_to_oai(req.get("messages", []), req.get("system")),
            "stream": stream,
            "temperature": req.get("temperature", 0.3),
        }
        if req.get("max_tokens"):
            oai_payload["max_tokens"] = req["max_tokens"]
        tools = tools_ant_to_oai(req.get("tools"))
        if tools:
            oai_payload["tools"] = tools
        if stream:
            oai_payload["stream_options"] = {"include_usage": True}
        try:
            resp = requests.post(
                f"{OWL_BASE}/chat/completions",
                json=oai_payload,
                headers={"Content-Type": "application/json"},
                stream=stream,
                timeout=120
            )
            resp.raise_for_status()
        except requests.exceptions.RequestException as e:
            self.send_error(502, f"owlAPI error: {e}")
            return

        if stream:
            self._stream(resp, model_name)
        else:
            self._single(resp, model_name)

    def _single(self, owl_resp, model_name):
        try:
            body = json.dumps(oai_resp_to_ant(owl_resp.json(), model_name)).encode()
        except Exception:
            self.send_error(502, "Bad owlAPI response")
            return
        self._json_raw(200, body)

    def _stream(self, owl_resp, model_name):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        tr = StreamTranslator(model_name)
        try:
            self.wfile.write(tr.start().encode())
            self.wfile.flush()
            for line in owl_resp.iter_lines():
                if not line or not line.startswith(b"data: "):
                    continue
                data = line[6:]
                if data == b"[DONE]":
                    break
                try:
                    out = tr.chunk(json.loads(data))
                    if out:
                        self.wfile.write(out.encode())
                        self.wfile.flush()
                except (json.JSONDecodeError, KeyError):
                    pass
        except BrokenPipeError:
            pass

    def _json(self, code, obj):
        self._json_raw(code, json.dumps(obj).encode())

    def _json_raw(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else PORT
    srv = HTTPServer(("127.0.0.1", port), ProxyHandler)
    print(f"owl_proxy :{port} → {OWL_BASE} model={OWL_MODEL}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
