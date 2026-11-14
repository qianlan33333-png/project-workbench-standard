from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = payload["model"]
        choice = {"index": 0, "finish_reason": None, "delta": {"role": "assistant", "content": "CLEAN-LINUX-MODEL-OK"}}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for current in (choice, {"index": 0, "finish_reason": "stop", "delta": {}}):
            chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": model, "choices": [current]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

ThreadingHTTPServer(("127.0.0.1", 17770), Model).serve_forever()
