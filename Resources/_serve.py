#!/usr/bin/env python3
"""Static file server for the Servers tab.

Usage: _serve.py PORT DIR [INDEX]

Serves DIR; requests for "/" (or any directory path) resolve to INDEX when
given (e.g. `_serve.py 8123 .../codemap/renderer codemap.html`), otherwise to
the handler's normal index.html lookup. No-cache headers so edits show up on
plain reload during development.

This is spawned as a detached child by LocalStarter and copied into the app's
Contents/Resources by make-app.sh. It stays a separate process on purpose: a
static server has to hold a port, and being a detached child is what lets a dev
server outlive the notch app — the same lifetime it had when a launchd daemon
started it. Everything else the old daemon did is now in LocalStarter.swift.
"""
import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
DIR = sys.argv[2]
INDEX = sys.argv[3] if len(sys.argv) > 3 else None


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIR, **kwargs)

    def send_response_only(self, code, message=None):
        super().send_response_only(code, message)
        self.send_header("Cache-Control", "no-store")

    def translate_path(self, path):
        full = super().translate_path(path)
        if INDEX and os.path.isdir(full):
            candidate = os.path.join(full, INDEX)
            if os.path.isfile(candidate):
                return candidate
        return full


if __name__ == "__main__":
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
