#!/usr/bin/env python3
"""A local stand-in for Scruter's ingest, for the CMP example apps' UI tests: it serves the kit's golden configuration
(protocol/cmp/bodies/config.json, pointed at itself and at the example apps' bundle ids), its texts in other languages,
generated media and the SDK catalogue, and keeps every beacon it receives (hits, proofs, SDK reports) in OUT_DIR as
`<schema>--NNN.json`, for protocol/validate.mjs.

With the IAB TCF ("tcf"): protocol/cmp/bodies/config-tcf.json and the kit's GVL 186 vendor subset and translations
(protocol/cmp/tcf); "tcf-gvl": GVL 187, where the vendors changed what advertising rests on, so the server bumped its
revision (docs/CMP.md §4.4 rule 5, job cmp_reask_apply).

Control, for the tests: POST /_stub/mode {"config": "base" | "reask" | "off" | "tcf" | "tcf-gvl", "consent": "ok" | "fail"},
GET /_stub/received (the beacons so far), POST /_stub/clear.

Usage: cmp_stub_ingest.py PORT OUT_DIR
"""
import copy
import json
import os
import struct
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, OUT = int(sys.argv[1]), sys.argv[2]
BASE = f"http://127.0.0.1:{PORT}"
HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, "..", "..", "protocol", "cmp")
os.makedirs(OUT, exist_ok=True)
lock = threading.Lock()
state = {"config": "base", "consent": "ok", "received": [], "count": 0}


def png(width, height, pixel):
    """A PNG from a function (x, y) -> (r, g, b), no dependency."""
    rows = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


HERO = png(240, 90, lambda x, y: (200 - y // 2, 150 + x // 8, 120 + (x + y) // 6))
ICON = png(96, 96, lambda x, y: (180, 68, 30) if (x - 48) ** 2 + (y - 48) ** 2 < 900 else (250, 244, 238))


def golden(tcf=False):
    with open(os.path.join(KIT, "bodies", "config-tcf.json" if tcf else "config.json"), encoding="utf-8") as f:
        c = json.load(f)
    cfg = c["config"]
    cfg["endpoint"] = BASE
    cfg["ui"]["logo_url"] = BASE + "/cmp/assets/logos/icon.png"
    cfg["ui"]["hero"]["poster"] = [{"url": BASE + "/cmp/media/hero.jpg", "type": "image/jpeg", "w": 960}]
    c["app"]["icon"] = BASE + "/cmp/assets/logos/icon.png"
    # The example apps of the native modules and of the React Native and Flutter wrappers.
    c["app"]["ids"] = ["net.scruter.example.cmp", "net.scruter.example.cmp.uikit", "net.scruter.rnexample",
                       "net.scruter.scruter_flutter_example", "net.scruter.scruterflutterexample"]
    c["ttl"] = 60
    c["config"]["ui"]["texts"]["fr"]["preferences_intro"] = "Ces choix valent pour cette app, sur cet appareil."
    return c


def config():
    mode = state["config"]
    if mode == "off":
        return {"v": 1, "on": 0, "ttl": 300}
    c = golden(mode.startswith("tcf"))
    if mode == "tcf-gvl":
        t = c["config"]["tcf"]
        t["gvl_version"] = 187
        t["vendors_url"] = "/cmp/ATMONA02/vendors-187.json?r=43"
        t["translations_url"] = "/cmp/tcf/187/{lang}.json"
        c["config"]["consent_rev"] = 4
        c["config"]["config_rev"] = 43
        for p in c["config"]["purposes"]:
            if p["key"] == "advertising":
                p["rev"] = 4
    if mode == "reask":
        # A new provider for advertising: those who granted it are asked again.
        c["config"]["consent_rev"] = 4
        c["config"]["config_rev"] = 43
        for p in c["config"]["purposes"]:
            if p["key"] == "advertising":
                p["rev"] = 4
        c["config"]["ui"]["providers"]["advertising"].append("AppLovin")
    return c


def texts(lang):
    t = copy.deepcopy(golden()["config"]["ui"]["texts"]["fr"])
    words = {
        "en": ("Your data, your choices", "Accept all", "Reject all", "Customise", "Save", "Continue without accepting"),
        "de": ("Ihre Daten, Ihre Wahl", "Alle akzeptieren", "Alle ablehnen", "Anpassen", "Speichern", "Weiter ohne Zustimmung"),
    }.get(lang)
    if words is None:
        return None
    t["title"], t["accept_all"], t["reject_all"], t["customize"], t["save"], t["close"] = words
    return {"lang": lang, "dir": "ltr", "hash": ("de" if lang == "de" else "e0") * 32, "texts": t}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, body, ctype="application/json", headers=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        with lock:
            if path == "/m/v1/cmp":
                c = config()
                etag = '"a-' + format(zlib.crc32(json.dumps(c, sort_keys=True).encode()), "020x") + '"'
                if self.headers.get("If-None-Match") == etag:
                    return self._send(304, b"", headers={"ETag": etag})
                return self._send(200, c, headers={"ETag": etag, "Cache-Control": "public, max-age=300"})
            if path == "/_stub/received":
                return self._send(200, state["received"])
        if path.startswith("/cmp/ATMONA02/texts-"):
            lang = path.rsplit("-", 1)[1].split(".")[0]
            t = texts(lang)
            return self._send(200, t) if t else self._send(404, {"error": "not_found"})
        if path.startswith("/cmp/ATMONA02/vendors-") and path.endswith(".json"):
            gvl = int(path.rsplit("-", 1)[1].split(".")[0])
            with open(os.path.join(KIT, "tcf", "vendors-186.json"), encoding="utf-8") as f:
                v = json.load(f)
            v["vendorListVersion"] = gvl
            return self._send(200, v)
        if path.startswith("/cmp/tcf/"):
            lang = path.rsplit("/", 1)[1].split(".")[0]
            name = os.path.join(KIT, "tcf", f"186-{lang}.json")
            if not os.path.exists(name):
                return self._send(404, {"error": "not_found"})
            with open(name, encoding="utf-8") as f:
                return self._send(200, json.load(f))
        if path == "/cmp/media/hero.jpg":
            return self._send(200, HERO, "image/png")
        if path == "/cmp/assets/logos/icon.png":
            return self._send(200, ICON, "image/png")
        if path == "/m/v1/cmp/sdks/1.json":
            return self._send(200, {"v": 1, "sdks": [{"k": "firebase_analytics", "ios": ["FIRAnalytics"]},
                                                     {"k": "uikit_marker", "ios": ["UIViewController"]}]})
        return self._send(404, {"error": "not_found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with lock:
            if path == "/_stub/mode":
                state.update({k: v for k, v in json.loads(body or b"{}").items() if k in ("config", "consent")})
                return self._send(200, {"ok": True})
            if path == "/_stub/clear":
                state["received"] = []
                return self._send(200, {"ok": True})
            schema = {"/cmp/hit": "cmp-hit", "/cmp/consent": "cmp-consent", "/m/v1/cmp/sdks": "cmp-sdks"}.get(path)
            if schema is None:
                return self._send(404, {"error": "not_found"})
            try:
                parsed = json.loads(body)
            except ValueError:
                return self._send(400, {"error": "invalid_payload"})
            if schema == "cmp-consent" and state["consent"] == "fail":
                return self._send(503, {"error": "unavailable"}, headers={"Retry-After": "1"})
            state["count"] += 1
            state["received"].append({"schema": schema, "body": parsed})
            with open(os.path.join(OUT, f"{schema}--stub-{state['count']:03d}.json"), "wb") as f:
                f.write(json.dumps(parsed).encode())
        return self._send(202, {})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
