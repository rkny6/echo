#!/usr/bin/env python3
"""echo 本地 MCP 测试服务器（零依赖，仅用 Python 标准库）。

作用：验证 echo iOS 客户端的 MCP Streamable HTTP 链路：
  initialize 握手 → notifications/initialized → tools/list → tools/call

会把你收到的每个请求（Header + Body）打印到终端，
方便确认 iOS 客户端到底发了什么、有没有正确回传 Mcp-Session-Id。

启动：
    python3 scripts/mcp_test_server.py
    # 默认监听 http://127.0.0.1:8000
"""

import datetime
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOL_VERSION = "2025-06-18"
SESSION_ID = "echo-test-session-001"  # 固定的假会话 ID，用于验证客户端会回传

TOOLS = [
    {
        "name": "get_weather",
        "description": "查询指定城市的天气",
        "inputSchema": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "城市名"}
            },
            "required": ["city"],
        },
    },
    {
        "name": "get_time",
        "description": "获取服务器当前时间",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "ping",
        "description": "连通性测试",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 关闭默认访问日志，用我们自己的输出
        pass

    # ---- helpers ----

    def _send_json(self, obj, status=200, extra_headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _dump_request(self, raw: str):
        print("\n───── 收到请求 ─────")
        for k, v in self.headers.items():
            print(f"  {k}: {v}")
        print(f"  Body: {raw}")
        print("────────────────────")

    # ---- POST: 所有 JSON-RPC 消息都走这里 ----

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace")
        self._dump_request(raw)

        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            self._send_json(
                {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}},
                status=400,
            )
            return

        method = msg.get("method")
        msg_id = msg.get("id")

        # 通知（没有 id）→ 只确认，不响应 body
        if msg_id is None:
            print(f"  [notification] {method} params={msg.get('params')}")
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "echo-test-server", "version": "1.0.0"},
                "instructions": "这是一个本地测试 MCP 服务器",
            }
            # 关键：返回 Mcp-Session-Id，验证客户端后续请求会带回来
            self._send_json(
                {"jsonrpc": "2.0", "id": msg_id, "result": result},
                extra_headers={"Mcp-Session-Id": SESSION_ID},
            )
        elif method == "tools/list":
            self._send_json(
                {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}}
            )
        elif method == "tools/call":
            params = msg.get("params", {})
            name = params.get("name", "")
            args = params.get("arguments", {}) or {}
            if name == "get_weather":
                city = args.get("city", "未知城市")
                text = f"{city}：晴，25°C，微风，适合出门散步。"
            elif name == "get_time":
                text = f"服务器当前时间：{datetime.datetime.now().isoformat()}"
            elif name == "ping":
                text = "pong"
            else:
                self._send_json(
                    {
                        "jsonrpc": "2.0",
                        "id": msg_id,
                        "result": {
                            "content": [{"type": "text", "text": f"未知工具: {name}"}],
                            "isError": True,
                        },
                    }
                )
                return
            self._send_json(
                {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "content": [{"type": "text", "text": text}],
                        "isError": False,
                    },
                }
            )
        else:
            self._send_json(
                {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "error": {"code": -32601, "message": f"Method not found: {method}"},
                }
            )

    def do_GET(self):
        # Streamable HTTP 允许 GET 建会话，但测试服务器只实现 POST 部分
        self._send_json(
            {
                "jsonrpc": "2.0",
                "error": {"code": -32601, "message": "此测试服务器仅支持 POST（Streamable HTTP）"},
            },
            status=405,
        )


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8000), Handler)
    print("echo MCP 测试服务器已启动: http://127.0.0.1:8000")
    print("按 Ctrl+C 停止\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")