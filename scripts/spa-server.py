#!/usr/bin/env python3
"""Serve a built SPA with a history fallback, for local verification only.

    python3 scripts/spa-server.py web/dist 8801

Cloudflare Workers Static Assets serves index.html for an unknown path, which
is what makes client-side routes like /login work on a hard refresh. Python's
own http.server returns 404 instead, so without this a browser check of /login
tests a 404 page rather than the app. Used by scripts/check-cold-start.mjs.
"""
import http.server, os, socketserver, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        p = self.translate_path(self.path)
        if not os.path.exists(p) or os.path.isdir(p):
            self.path = '/index.html'      # SPA fallback, like Workers
        return super().do_GET()
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', int(sys.argv[2])), H).serve_forever()
