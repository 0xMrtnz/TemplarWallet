#!/usr/bin/env python3
"""Tiny stand-in for a Templar Protocol site's web side (docs/connector-protocol.md §5).

Serves the JSON fixtures in docs/fixtures/protocol/ and accepts the wallet's
callbacks, printing every POST body so the connect / sign flows can be
exercised end-to-end before the real site lands.

    python3 scripts/protocol_fixture_server.py            # 127.0.0.1:8765
    open "templar://connect?url=http://127.0.0.1:8765/connect.json&nonce=fixture-nonce-connect"
    open "templar://sign?url=http://127.0.0.1:8765/sign.json&nonce=fixture-nonce-sign"

The sign fixture spends a fake loan escrow whose contract names the key of
the BIP39 test mnemonic "abandon … about" (fingerprint 73c5da0a); import
that phrase as a software wallet with Liquid enabled, on Liquid testnet.
Callbacks answer `{"ok":true,"next":...}` or `{"ok":false,"error":...}`
when the body misses a field, like the real server.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent.parent / "docs" / "fixtures" / "protocol"
HOST, PORT = "127.0.0.1", 8765

REQUIRED = {
    "/callback/connect": ["version", "nonce", "network", "ct_descriptor", "escrow_xpub",
                          "receive_address", "wallet_name", "signer"],
    "/callback/sign": ["version", "id", "nonce", "pset"],
}


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        target = FIXTURES / path.lstrip("/")
        if path in ("/connect.json", "/sign.json") and target.is_file():
            self._json(200, json.loads(target.read_text()))
        else:
            self._json(404, {"ok": False, "error": f"no fixture at {path}"})

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"ok": False, "error": "body is not JSON"})
            return
        shown = dict(body)
        if "pset" in shown:
            shown["pset"] = f"<{len(shown['pset'])} chars>"
        print(f"POST {self.path}\n{json.dumps(shown, indent=2)}", flush=True)
        required = REQUIRED.get(self.path)
        if required is None:
            self._json(404, {"ok": False, "error": f"unknown callback {self.path}"})
            return
        missing = [k for k in required if not body.get(k)]
        if missing:
            self._json(400, {"ok": False, "error": f"missing {', '.join(missing)}"})
            return
        self._json(200, {"ok": True, "next": f"http://{HOST}:{PORT}/done"})

    def log_message(self, fmt, *args):  # quieter default log
        sys.stderr.write("%s %s\n" % (self.command, self.path))


if __name__ == "__main__":
    print(f"protocol fixture server on http://{HOST}:{PORT}  (fixtures: {FIXTURES})", flush=True)
    HTTPServer((HOST, PORT), Handler).serve_forever()
