#!/usr/bin/env python3
"""A stale app shell must not be able to produce a silent blank page.

WHY THIS EXISTS

A school reported the sign-in page loading for about a minute and then going
completely white, with nothing on it. Reproduced exactly, and the mechanism is
worth stating because every part of it is working as designed:

  * Vite fingerprints its output, so each build has new asset filenames.
  * A browser holding an OLD index.html therefore asks for a filename that is
    no longer deployed.
  * web/wrangler.jsonc sets not_found_handling to "single-page-application",
    which answers a path with no file by returning index.html, at 200, as
    text/html.
  * So a request for a script receives a page. Chrome refuses to execute HTML
    as a module script, and the result is measured:

        #root innerHTML length: 0
        BODY TEXT: ""
        CONSOLE error: Failed to load module script: Expected a
          JavaScript-or-Wasm module script but the server responded with a
          MIME type of "text/html".

A blank page, a 200 in the network tab, and one line in a console no school
will ever open. And nothing in the application can help, because when the
module does not execute NO application code runs at all.

WHAT THIS ASSERTS, AND WHY EACH ONE IS LOAD-BEARING

  1. THE RESCUE IN index.html EXISTS AND IS A CLASSIC SCRIPT. It is the only
     thing that can act when modules fail, so `type="module"` on it would make
     it fail by the same mechanism it exists to catch.
  2. IT LISTENS FOR THE MODULE SCRIPT'S ERROR EVENT. A timeout would either be
     too short (killing a slow download on a bad line, making things worse) or
     too long to help. The error event is immediate and cannot false-positive.
  3. A BROWSER IS TOLD TO REVALIDATE EVERY PAGE. Asked by resolving _headers
     the way Cloudflare resolves it, for the paths people actually open: /,
     /login, /parents, /portal. The rule this replaced was on /index.html, and
     nobody navigates to /index.html, so the protection existed and covered
     nothing.
  4. AND THE FINGERPRINTED ASSETS ARE STILL CACHED HARD, because a later rule
     replaces an earlier one and getting the order wrong would silently make
     every load re-download the bundle.
  5. THE SERVICE WORKER TESTS A CACHED ENTRY BEFORE SERVING IT, and versions
     its cache. A page cached under a script's URL is served from disk,
     instantly, for ever, which is what turned one bad moment into a
     permanently blank app; and an unversioned cache name means `activate`
     only runs when sw.js itself changes, so such an entry outlives every
     deploy in between.

WHAT IT DELIBERATELY DOES NOT ASSERT. That the worker never hands respondWith a
non-Response, and that it never caches HTML for an asset, are properties of
BEHAVIOUR. An earlier version of this file claimed both by grepping for one
spelling of the old defect, and reintroducing that defect in a different
spelling was reported as clean. Those two are proved in a real browser by
scripts/check-blank-page.mjs, which needs Playwright and is run by hand.

Usage:  python3 scripts/check-stale-shell.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / "web" / "index.html"
HEADERS = ROOT / "web" / "public" / "_headers"
SW = ROOT / "web" / "public" / "sw.js"

problems: list[str] = []


def need(path: Path) -> str:
    if not path.exists():
        problems.append(f"{path.relative_to(ROOT)} is missing")
        return ""
    return path.read_text()


index = need(INDEX)
headers = need(HEADERS)
sw = need(SW)

# --- 1 and 2: the rescue ----------------------------------------------------
if index:
    # The rescue block, isolated: everything before the module script tag.
    before_module = index.split('<script type="module"')[0]
    if "addEventListener('error'" not in before_module.replace('"', "'"):
        problems.append(
            "web/index.html has no error listener before its module script. That "
            "listener is the ONLY thing that can notice the bundle failing to "
            "load, because nothing in src/ runs when it does.")
    if "'module'" not in before_module.replace('"', "'"):
        problems.append(
            "web/index.html's rescue does not check for a module script, so it "
            "cannot tell the bundle failing from any other error event.")
    # The rescue must not itself be a module.
    for tag in re.findall(r"<script[^>]*>", before_module):
        if "type=" in tag and "module" in tag:
            problems.append(
                "web/index.html's rescue script is a module. It would fail by the "
                "same mechanism it exists to catch. It has to be a classic script.")
    if "sessionStorage" not in before_module:
        problems.append(
            "web/index.html's rescue does not guard against repeating itself. A "
            "reload loop on the sign-in page is worse than a blank one: a blank "
            "page can at least be described over the telephone.")

# --- 3 and 4: the cache rules, decided the way Cloudflare decides them ------
#
# ASKED AS A QUESTION ABOUT A REQUEST PATH, not about line numbers. The first
# version compared the line of the /* rule against the line of /assets/*, and
# it reported success on the exact regression it was written to catch: this
# file has TWO /* blocks (the security headers are the first), so it found line
# 3, saw that it came before /assets/*, and was satisfied while the
# Cache-Control rule sat below.
#
# Cloudflare applies every rule whose pattern matches the REQUEST path, in file
# order, and lets a later one replace an earlier one that set the same header.
# scripts/cf-server.py already models that for the marketing site. Modelling it
# here too means the assertion is about what a browser is actually told, which
# is the only thing that matters and cannot be fooled by the layout.
def blocks(text: str) -> list[tuple[str, dict[str, str]]]:
    out: list[tuple[str, dict[str, str]]] = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line:
            continue
        if not line.startswith((" ", "\t")):
            out.append((line.strip(), {}))
        elif out:
            if ":" in line:
                name, _, value = line.strip().partition(":")
                out[-1][1][name.strip().lower()] = value.strip()
    return out


def matches(pattern: str, path: str) -> bool:
    if pattern.endswith("*"):
        return path.startswith(pattern[:-1])
    return pattern == path


def header_for(text: str, path: str, name: str) -> str | None:
    found = None
    for pattern, hdrs in blocks(text):
        if matches(pattern, path) and name in hdrs:
            found = hdrs[name]
    return found


if headers:
    # The page every school actually opens. NOT /index.html: nobody navigates
    # there. wrangler.jsonc serves index.html for /login, but it serves it
    # UNDER THAT PATH, and Cloudflare matches the request path.
    for page in ("/", "/login", "/parents", "/portal"):
        cc = header_for(headers, page, "cache-control")
        if cc is None:
            problems.append(
                f"web/public/_headers tells a browser nothing about caching {page}, "
                "so it can be served a stale index.html pointing at a build that "
                "no longer exists. A rule on /index.html does not cover this: "
                "the SPA fallback serves the page under its own path.")
        elif "no-cache" not in cc and "no-store" not in cc:
            problems.append(
                f"web/public/_headers sends `{cc}` for {page}. A page that is not "
                "revalidated is how a school stays on a build whose assets have "
                "been replaced, which renders completely blank.")

    # And the fingerprinted assets must still be cached hard, or every load
    # re-downloads 350 kB over a Pakistani mobile connection.
    asset_cc = header_for(headers, "/assets/index-abc123.js", "cache-control")
    if asset_cc is None or "immutable" not in asset_cc:
        problems.append(
            "web/public/_headers no longer caches /assets/* immutably (got "
            f"`{asset_cc}`). Cloudflare lets a later rule replace an earlier one "
            "that set the same header, so the /assets/* rule has to come AFTER "
            "the page rule, not before it.")

# --- 5: the service worker, and only what text can honestly prove ----------
#
# CHECKED AGAINST CODE, NOT COMMENTS. The first version of this guard failed on
# the very file it protects: sw.js QUOTES the old broken pattern in its header,
# to explain what went wrong, and the regex found it there. A guard that trips
# on documentation is a guard somebody deletes.
#
# AND IT USED TO CLAIM MORE THAN IT COULD SHOW. It asserted that sw.js "refuses
# an HTML response for an asset" and "always answers with a Response" by
# grepping for one spelling of the old defect. Tested by reintroducing the
# defect in a different spelling, and the guard reported success: it was
# checking for a string, not for a property, which is the failure this
# repository's other guards are covered in warnings about.
#
# So the two BEHAVIOURAL properties are proved in a real browser instead, by
# scripts/check-blank-page.mjs, which installs the old worker, poisons its
# cache, deploys the new one and asserts the app boots. What is left here is
# what text really can decide.
def strip_comments(js: str) -> str:
    js = re.sub(r"/\*.*?\*/", " ", js, flags=re.S)
    js = re.sub(r"^\s*//.*$", " ", js, flags=re.M)
    return js


sw_code = strip_comments(sw) if sw else ""

if sw:
    # A CALL SITE, not a definition. `isHtml` merely existing proves nothing:
    # the property that matters is that a cached entry is TESTED with it before
    # being served, because a cached page under a script's URL is what made the
    # blank page permanent.
    if not re.search(r"isHtml\(\s*cached\s*\)", sw_code):
        problems.append(
            "web/public/sw.js does not test a CACHED entry with isHtml() before "
            "serving it. A page cached under a script's URL is served from disk, "
            "instantly, for ever, and that is what turns one bad moment into a "
            "permanently blank app. Behaviour proved by "
            "scripts/check-blank-page.mjs.")
    if not re.search(r"const\s+CACHE\s*=\s*'sm-shell-v(\d+)'", sw_code):
        problems.append(
            "web/public/sw.js has no versioned cache name. Without one, activate "
            "only runs when this file itself changes, so a poisoned cache "
            "survives every deploy in between. Raise the version whenever the "
            "caching behaviour changes.")

if problems:
    print("A STALE SHELL COULD PRODUCE A SILENT BLANK PAGE:\n")
    for p in problems:
        print(f"  * {p}\n")
    sys.exit(1)

print("stale-shell guards hold:")
print("  the rescue in index.html is a classic script listening for a module error,")
print("    guarded against repeating itself")
print("  _headers revalidates every page and still caches fingerprinted assets")
print("  sw.js versions its cache and tests a cached entry before serving it")
print("  (the worker's behaviour under a poisoned cache is proved in a browser by")
print("   scripts/check-blank-page.mjs, which needs Playwright and is run by hand)")
