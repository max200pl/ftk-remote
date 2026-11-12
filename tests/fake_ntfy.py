#!/usr/bin/env python3
"""Minimal ntfy.sh stand-in for tests: POST /<topic> stores, GET /<topic>/json returns NDJSON."""
import json, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
msgs = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        topic = self.path.strip("/").split("?")[0]
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        e = {"id": str(len(msgs.get(topic, []))), "time": int(time.time()), "event": "message",
             "topic": topic, "title": self.headers.get("Title", ""), "message": body}
        msgs.setdefault(topic, []).append(e)
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(e).encode())
    def do_GET(self):
        topic = self.path.strip("/").split("/")[0]
        data = "".join(json.dumps(e) + "\n" for e in msgs.get(topic, []))
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.end_headers()
        self.wfile.write(data.encode())
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
