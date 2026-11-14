from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = payload["model"]
        if self.path.split("?")[0].endswith("/messages"):
            self.send_response(200)
            self.send_header("Content-Type","text/event-stream")
            self.end_headers()
            events = [
                ("message_start", {"message":{"id":"msg_fixture","type":"message","role":"assistant","model":model,"content":[],"stop_reason":None,"usage":{"input_tokens":1,"output_tokens":0}}}),
                ("content_block_start", {"index":0,"content_block":{"type":"text","text":""}}),
                ("content_block_delta", {"index":0,"delta":{"type":"text_delta","text":"CLEAN-LINUX-MODEL-OK"}}),
                ("content_block_stop", {"index":0}),
                ("message_delta", {"delta":{"stop_reason":"end_turn","stop_sequence":None},"usage":{"output_tokens":5}}),
                ("message_stop", {}),
            ]
            for event, data in events:
                self.wfile.write((f"event: {event}\ndata: "+json.dumps({"type":event,**data})+"\n\n").encode())
            return
        choice = {"index": 0, "finish_reason": None, "delta": {"role": "assistant", "content": "CLEAN-LINUX-MODEL-OK"}}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for current in (choice, {"index": 0, "finish_reason": "stop", "delta": {}}):
            chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": model, "choices": [current]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

ThreadingHTTPServer(("127.0.0.1", 17770), Model).serve_forever()
