#!/usr/bin/env python3
"""guest-viewer — see a guest's screen in the browser (stdlib only).

The hub's /stream endpoint requires the bearer token, so a browser tab
cannot hit it directly. This tiny proxy reads the token from
~/.vertus/token, serves a page with ``<img src="/stream/<agent>">``, and
forwards the multipart PNG stream with the Authorization header attached.
It is intentionally dumb: no caching, no TLS, one agent per page, bound to
127.0.0.1 only.

Usage:
    python3 vertus/scripts/guest-viewer.py [agent] [port]

Then open http://127.0.0.1:<port>/ — the guest's screen, live.
"""

from __future__ import annotations

import json
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_HUB = "http://127.0.0.1:8787"
_AGENT = sys.argv[1] if len(sys.argv) > 1 else "primary"
_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899

_PAGE = f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>guest: {_AGENT}</title>
<style>
  body {{ background: #000; margin: 0; display: flex; min-height: 100vh;
         align-items: center; justify-content: center; }}
  img {{ max-width: 100vw; max-height: 100vh; image-rendering: pixelated; }}
  #status {{ position: fixed; top: 8px; right: 12px; color: #7f7f7f;
            font: 12px monospace; }}
</style></head>
<body>
  <img src="/stream" alt="guest screen (boot it first)">
  <div id="status">guest: {_AGENT} — boot with: vertus-guest boot {_AGENT}</div>
</body></html>
"""


def _token() -> str:
    try:
        return Path.home().joinpath(".vertus", "token").read_text().strip()
    except OSError:
        return ""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/" or self.path == "/index.html":
            body = _PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/stream":
            self._proxy_stream()
            return
        self.send_error(404)

    def _proxy_stream(self) -> None:
        """Forward the hub's multipart PNG stream verbatim, adding the token."""
        req = urllib.request.Request(
            f"{_HUB}/api/fleet/guests/{_AGENT}/stream",
            headers={"Authorization": f"Bearer {_token()}"})
        try:
            upstream = urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as exc:
            self.send_response(exc.code)
            body = exc.read()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        except Exception as exc:  # noqa: BLE001 — hub down / guest stopped
            body = json.dumps({"error": str(exc)}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type",
                         upstream.headers.get("Content-Type",
                                              "multipart/x-mixed-replace"))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            while True:
                # read1 (not read): return as soon as ANY bytes arrive so a
                # 2 KB PNG frame is forwarded immediately, not after 16 KB
                # of the stream has buffered.
                chunk = upstream.read1(1 << 16)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            upstream.close()

    def log_message(self, fmt: str, *args) -> None:  # noqa: ANN002
        sys.stderr.write(f"[guest-viewer] {fmt % args}\n")


if __name__ == "__main__":
    print(f"guest-viewer: http://127.0.0.1:{_PORT}/  (agent: {_AGENT})")
    ThreadingHTTPServer(("127.0.0.1", _PORT), Handler).serve_forever()