"""A fake of the symbol endpoints (docs/API.md §5.3) for testing ios/upload-symbols: records every request body."""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT = sys.argv[2]
UPLOADS = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def answer(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        return self.headers.get("Authorization", "").startswith("Bearer scr_up_")

    def do_POST(self):
        raw = self.body()
        if not self.authorized():
            return self.answer(401, {"error": {"code": "unauthorized", "message": "token"}})
        if self.path == "/m/v1/symbols/missing":
            req = json.loads(raw)
            open(os.path.join(OUT, "missing.json"), "wb").write(raw)
            return self.answer(200, {"missing": req["files"]})
        if self.path == "/m/v1/symbols":
            req = json.loads(raw)
            n = len(UPLOADS) + 1
            open(os.path.join(OUT, f"upload-{n}.json"), "wb").write(raw)
            UPLOADS[str(n)] = req
            port = self.server.server_address[1]
            return self.answer(201, {"id": str(n), "upload": {"method": "PUT", "url": f"http://127.0.0.1:{port}/put/{n}",
                                                            "headers": {"Content-Type": "application/octet-stream",
                                                                        "Content-Length": str(req["size"])},
                                                            "expires_at": "2030-01-01T00:00:00Z"}})
        if self.path.startswith("/m/v1/symbols/") and self.path.endswith("/complete"):
            n = self.path.split("/")[4]
            ok = UPLOADS.get(n, {}).get("received")
            open(os.path.join(OUT, f"complete-{n}"), "w").write("ok" if ok else "missing")
            return self.answer(202 if ok else 409, {})
        self.answer(404, {"error": {"code": "not_found", "message": self.path}})

    def do_PUT(self):
        raw = self.body()
        n = self.path.split("/")[-1]
        req = UPLOADS.get(n)
        if req and len(raw) == req["size"] and hashlib.sha256(raw).hexdigest() == req["sha256"]:
            req["received"] = True
            self.send_response(200)
        else:
            self.send_response(400)
        self.send_header("Content-Length", "0")
        self.end_headers()


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
