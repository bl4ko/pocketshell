# /// script
# requires-python = ">=3.9"
# ///
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = sys.argv[2] if len(sys.argv) > 2 else "psh-test-key"


def chunk(delta, finish=None):
    body = {
        "id": "chatcmpl-psh",
        "object": "chat.completion.chunk",
        "model": "gpt-6-luna",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    return f"data: {json.dumps(body)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.headers.get("Authorization") != f"Bearer {KEY}":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"bad key"}}')
            return
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        last = (request.get("messages") or [{}])[-1]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if last.get("role") == "tool":
            agents = json.loads(last.get("content") or "{}").get("agents")
            text = "All quiet on localbox." if isinstance(agents, list) else "The agent list failed."
            parts = [chunk({"role": "assistant", "content": text}), chunk({}, "stop")]
        else:
            call = {
                "index": 0,
                "id": "call_psh",
                "type": "function",
                "function": {"name": "list_agents", "arguments": "{}"},
            }
            parts = [
                chunk({"role": "assistant", "content": "Hmm, let me check."}),
                chunk({"tool_calls": [call]}),
                chunk({}, "tool_calls"),
            ]
        for part in parts + [b"data: [DONE]\n\n"]:
            self.wfile.write(part)
            self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
