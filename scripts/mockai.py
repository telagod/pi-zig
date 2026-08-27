#!/usr/bin/env python3
"""mockai — 极简 OpenAI 兼容 mock:SSE 流式。
脚本:首轮回 bash echo 工具调用;带 tool 结果的轮回最终答复;否则直接答复。
配合 ~/.piz/models.json 的 mock provider(127.0.0.1:8899/v1)使用。
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

def sse(obj):
    return ("data: " + json.dumps(obj) + "\n\n").encode()

def chunk(mid, delta, finish=None):
    return {"id": mid, "object": "chat.completion.chunk", "created": 1, "model": "mock-slow",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.endswith("/models"):
            body = json.dumps({"object": "list", "data": [{"id": "mock-slow", "object": "model"}]}).encode()
            self.send_response(200); self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        msgs = req.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        out = []
        if has_tool_result:
            words = "工具结果已收到。以上是 mock 的最终答复,覆盖流式渲染路径。".split("，")
            for i, wseg in enumerate(words):
                out.append(sse(chunk("m2", {"role": "assistant", "content": wseg}, None)))
            out.append(sse(chunk("m2", {}, "stop")))
        else:
            out.append(sse(chunk("m1", {"role": "assistant", "content": "先看下目录。"}, None)))
            out.append(sse(chunk("m1", {"tool_calls": [{"index": 0, "id": "call_1",
                "type": "function", "function": {"name": "bash", "arguments": json.dumps(
                    {"command": "echo hello-from-mock-tool && ls | head -3"})}}]}, None)))
            out.append(sse(chunk("m1", {}, "tool_calls")))
        out.append(b"data: [DONE]\n\n")
        for b in out:
            self.wfile.write(b); self.wfile.flush()
            import time; time.sleep(0.05)

HTTPServer(("127.0.0.1", 8899), H).serve_forever()
