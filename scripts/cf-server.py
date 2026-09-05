#!/usr/bin/env python3
"""Serve site/ the way Cloudflare Pages does, for local verification.

The SPA fallback server used for the app is WRONG for this site and produced a
false clean: it serves index.html for any unknown path, so a request for
/fee-management returned the HOME page and an audit of fifteen URLs audited one
page fifteen times.

Cloudflare Pages instead maps an extensionless request to <path>.html, and
returns 404.html for a path with no file. That difference is the whole reason
the canonical URLs are extensionless, so the checker has to model it.

It also applies site/_headers, for the same reason. site/_headers carries a
Content-Security-Policy with no 'unsafe-inline' in script-src. Whether that
policy breaks the pages is a question about how browsers behave, and the only
honest way to answer it is to serve the pages under the real policy and watch a
real browser. A checker that serves them WITHOUT the headers would pass and
prove nothing, which is the same failure this file was written to fix.
"""
import http.server, os, re, socketserver, sys

ROOT = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2])


def load_headers(root):
    """Parse _headers into [(compiled pattern, [(name, value)])].

    Cloudflare matches the REQUEST path, applies every rule that matches in
    file order, and lets a later rule replace an earlier one that set the same
    header name. That is what is modelled here.
    """
    path = os.path.join(root, '_headers')
    if not os.path.exists(path):
        return []
    rules, cur = [], None
    for raw in open(path, encoding='utf-8'):
        line = raw.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if line.startswith('/'):
            # * is the only wildcard. Anchor it, or /icon.svg would match
            # /decoy/icon.svg.
            rx = '^' + '.*'.join(re.escape(part) for part in line.strip().split('*')) + '$'
            cur = (re.compile(rx), [])
            rules.append(cur)
        elif line.startswith((' ', '\t')) and cur is not None:
            name, _, value = line.strip().partition(':')
            if name:
                cur[1].append((name.strip(), value.strip()))
    return rules


RULES = load_headers(ROOT)


def headers_for(path):
    out = {}
    for pattern, pairs in RULES:
        if pattern.match(path):
            for name, value in pairs:
                out[name] = value      # last matching rule wins
    return out

class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        """Cloudflare's resolution order: exact file, then <path>.html, then
        <path>/index.html, then 404.

        The order matters here and it is not academic. site/ contains BOTH
        guides.html and a guides/ directory. Checking for a directory first
        found guides/, found no index.html in it, and fell through to Python's
        automatic directory LISTING: /guides served a file index instead of the
        page, and the audit reported the guides page as having no nav, no logo
        and no structured data. Cloudflare serves guides.html and never
        produces a listing, so neither does this.
        """
        p = super().translate_path(path)
        if os.path.isfile(p):
            return p
        if os.path.isfile(p + '.html'):
            return p + '.html'
        idx = os.path.join(p, 'index.html')
        if os.path.isfile(idx):
            return idx
        nf = os.path.join(ROOT, '404.html')
        if os.path.isfile(nf):
            return nf
        return p

    def send_response(self, *a, **kw):
        super().send_response(*a, **kw)
        for name, value in headers_for(self.path.split('?')[0]).items():
            self.send_header(name, value)

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
