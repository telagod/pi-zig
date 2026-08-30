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
    MD_DOC = "# 项目结构总览\n\n这是一个 **Zig** 编写的 *AI agent* 命令行工具,支持三种运行形态。详见 [架构文档](https://example.com/docs)。\n\n## 核心能力\n\n- 交互式 TUI(默认)\n- print 模式(`-p` 一次性问答)\n- Web UI(`piz web`)\n\n### 构建步骤\n\n1. 安装 Zig 0.15+\n2. 运行 `zig build`\n3. 产物在 `zig-out/bin/piz`\n\n| 模块 | 职责 | 测试 |\n| --- | --- | --- |\n| core | 会话与事件 | 120 |\n| tui | 终端界面 | 96 |\n| webui | 浏览器前端 | 44 |\n\n> 会话池上限 4 个并发会话,每个会话独立的 Agent 实例与工作线程。\n\n```zig\nconst std = @import(\"std\");\n\npub fn main() !void {\n    const stdout = std.io.getStdOut().writer();\n    try stdout.print(\"hello, {s}!\\n\", .{\"piz\"});\n}\n```\n\n- [x] 流式渲染\n- [x] 工具卡片折叠\n- [ ] 语法高亮\n\n---\n\n**注意**:`--no-token` 仅用于可信单机环境。"

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        msgs = req.get("messages", [])
        has_tool_result = any(m.get("role") == "tool" for m in msgs)
        want_md = any("markdown" in (m.get("content") or "").lower() for m in msgs if m.get("role") == "user") and not has_tool_result
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        out = []
        if want_md:
            for seg in self.MD_DOC.split("\n"):
                out.append(sse(chunk("m3", {"role": "assistant", "content": seg + "\n"}, None)))
            out.append(sse(chunk("m3", {}, "stop")))
        elif has_tool_result:
            words = "工具结果已收到。以上是 mock 的最终答复,覆盖流式渲染路径。".split("，")
            for i, wseg in enumerate(words):
                out.append(sse(chunk("m2", {"role": "assistant", "content": wseg}, None)))
            out.append(sse(chunk("m2", {}, "stop")))
        else:
            last_user = next((m.get("content") or "" for m in reversed(msgs) if m.get("role") == "user"), "")
            if "慢" in last_user:
                tool_name, args = "bash", {"command": "sleep 6 && echo slow-done"}
                pre = "跑个慢命令。"
            elif "fail" in last_user.lower():
                tool_name, args = "bash", {"command": "ls /nonexistent-piz-dir"}
                pre = "试一个会失败的命令。"
            elif "改文件" in last_user:
                tool_name, args = "write", {"path": "/tmp/piz_mock_demo.md", "content": "# demo\n\nhello piz\n"}
                pre = "写一个文件看看。"
            else:
                tool_name, args = "bash", {"command": "echo hello-from-mock-tool && ls | head -3"}
                pre = "先看下目录。"
            out.append(sse(chunk("m1", {"role": "assistant", "content": pre}, None)))
            out.append(sse(chunk("m1", {"tool_calls": [{"index": 0, "id": "call_1",
                "type": "function", "function": {"name": tool_name, "arguments": json.dumps(args)}}]}, None)))
            out.append(sse(chunk("m1", {}, "tool_calls")))
        out.append(b"data: [DONE]\n\n")
        for b in out:
            self.wfile.write(b); self.wfile.flush()
            import time; time.sleep(0.05)

HTTPServer(("127.0.0.1", 8899), H).serve_forever()