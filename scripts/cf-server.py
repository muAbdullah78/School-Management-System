#!/usr/bin/env python3
"""Serve site/ the way Cloudflare Pages does, for local verification.

The SPA fallback server used for the app is WRONG for this site and produced a
false clean: it serves index.html for any unknown path, so a request for
/fee-management returned the HOME page and an audit of fifteen URLs audited one
page fifteen times.

Cloudflare Pages instead maps an extensionless request to <path>.html, and
returns 404.html for a path with no file. That difference is the whole reason
the canonical URLs are extensionless, so the checker has to model it.
"""
import http.server, os, socketserver, sys

ROOT = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2])

class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        p = super().translate_path(path)
        if os.path.isdir(p):
            idx = os.path.join(p, 'index.html')
            if os.path.exists(idx):
                return idx
        if not os.path.exists(p):
            if os.path.exists(p + '.html'):
                return p + '.html'
            nf = os.path.join(ROOT, '404.html')
            if os.path.exists(nf):
                return nf
        return p

    def send_head(self):
        # 404.html must be served WITH a 404 status, or a checker cannot tell a
        # real page from a missing one.
        p = self.translate_path(self.path)
        if os.path.abspath(p) == os.path.join(ROOT, '404.html') and \
           self.path.rstrip('/') not in ('/404', '/404.html'):
            self.send_response(404)
            body = open(p, 'rb').read()
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            return __import__('io').BytesIO(body)
        return super().send_head()

    def log_message(self, *a):
        pass

os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', PORT), H).serve_forever()
