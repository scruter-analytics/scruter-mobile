#!/usr/bin/env python3
"""A local stand-in for Scruter's collection host, for ios/scripts/macos-run.sh: answers the configuration request
(`GET /m/v1/config`) and keeps every batch (`POST /m/v1/batch`) it receives, gunzipped, as `batch-NNN.json` in a
directory, with its arrival time in `batch-NNN.received`.

Usage: fake_batch_server.py PORT OUT_DIR
"""
import gzip
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, OUT = int(sys.argv[1]), sys.argv[2]
CONFIG = {"v": 1, "on": 1, "e": "etag-macos-run", "tz": "Europe/Paris", "aa": 0, "cr": 1, "xs": [], "tp": 0, "ttl": 3600}
count = 0


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.split("?")[0].endswith("/m/v1/config"):
            self._send(200, CONFIG)
        else:
            self._send(404, {"error": "not_found"})

    def do_POST(self):
        global count
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        if not self.path.split("?")[0].endswith("/m/v1/batch"):
            self._send(404, {"error": "not_found"})
            return
        count += 1
        name = os.path.join(OUT, "batch-%03d" % count)
        with open(name + ".json", "wb") as f:
            f.write(body)
        with open(name + ".received", "w") as f:
            f.write("%.3f" % time.time())
        self._send(202, {})

    def log_message(self, *args):
        pass


class Server(ThreadingHTTPServer):
    # HTTPServer.server_bind looks the host's name up (socket.getfqdn) before listening: a reverse DNS query that can
    # take half a minute behind a VPN. The name serves nothing here.
    def server_bind(self):
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        self.server_name, self.server_port = self.server_address[0], self.server_address[1]


Server(("127.0.0.1", PORT), Handler).serve_forever()
