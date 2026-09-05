#!/usr/bin/env python3
"""Refuse a site build that would be invisible, duplicated or self-contradicting.

WHY EACH CHECK IS HERE, because a checklist nobody can justify gets deleted:

  BUILD DRIFT. site/*.html is generated and committed, because the deployment
  is a hand upload and the uploader needs files. So somebody will one day edit
  the OUTPUT, and the next build will silently throw that edit away. This
  rebuilds into a temporary directory and compares, so the drift is a failed
  check rather than lost work.

  DUPLICATE TITLES AND DESCRIPTIONS are the first thing Search Console
  complains about after a template is introduced, and the commonest defect a
  template causes.

  CANONICAL POINTING AT A URL THAT DOES NOT SERVE. Cloudflare serves
  /fee-management for fee-management.html, so the extensionless URL is the
  canonical one. If a canonical names a path with no file behind it, every
  crawler is told the real page lives at a 404.

  BROKEN INTERNAL LINKS. On a one-page site every link was an anchor and could
  not 404. With fourteen pages they can, and a broken internal link is both a
  dead end for a visitor and a wasted crawl.

  ORPHANS. A page reachable from nothing is a page Google will not find and a
  visitor cannot get to, which makes writing it pointless.

  SITEMAP AGREEMENT in both directions: every page listed, and nothing listed
  that does not exist.

  THE REVIEWS PAGE AGREEING WITH ITS OWN DATA. It is the one page built from
  data rather than prose, and a marked-up rating that does not match the words
  under it is a lie about customers rather than a formatting slip.

  MORE THAN ONE H1, OR NONE. The h1 is what the page is about. Two h1s is two
  answers and no h1 is none. And two PAGES sharing an h1 compete for the same
  query, which is the cannibalisation splitting the site was meant to avoid.

  JSON-LD THAT DOES NOT PARSE is worse than no JSON-LD: it is a claim Google
  reads as an error, and it fails silently in a browser.

Usage:  python3 scripts/check-site-seo.py
"""
import html
import json
import xml.dom.minidom
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / 'site'
DOMAIN = 'https://theschoolmanager.site'

# Google truncates a title around 580px, which is about 60 characters, and a
# description around 160. Longer is not an error, it is a promise the search
# result will not keep, so these are warnings with a hard ceiling above them.
TITLE_SOFT, TITLE_HARD = 62, 75
DESC_SOFT_LOW, DESC_SOFT_HIGH, DESC_HARD = 110, 165, 200

fails: list[str] = []
warns: list[str] = []


def fail(msg: str) -> None:
    fails.append(msg)


def warn(msg: str) -> None:
    warns.append(msg)


def built_pages() -> list[Path]:
    """Every generated page.

    Every .html under site/ except guide.html, which is built by
    scripts/build-guide.py and checked by its own rules.

    The templates deliberately live OUTSIDE site/ in site-src/, because site/
    is uploaded to Cloudflare as-is and everything in it becomes a public URL.
    An earlier layout kept them in site/src/ and /src/layout.html was therefore
    served to the world as a page full of {{TITLE}} placeholders.
    """
    out = [p for p in SITE.rglob('*.html') if p.name != 'guide.html']
    return sorted(out)


def url_for(path: Path) -> str:
    rel = path.relative_to(SITE).as_posix()
    if rel == 'index.html':
        return '/'
    return '/' + rel[: -len('.html')]


def one(pattern: str, text: str, flags=re.I | re.S) -> str | None:
    m = re.search(pattern, text, flags)
    return m.group(1).strip() if m else None


def check_build_is_current() -> None:
    """The committed output must be exactly what the builder produces."""
    with tempfile.TemporaryDirectory() as tmp:
        # Build into a copy, so a drifted checkout is reported rather than
        # quietly repaired by the checker itself.
        stage = Path(tmp) / 'site'
        stage.mkdir()
        for f in ('styles.css', 'wire.js', 'config.js', 'robots.txt'):
            if (SITE / f).exists():
                (stage / f).write_bytes((SITE / f).read_bytes())
        script = (ROOT / 'scripts' / 'build-site.py').read_text(encoding='utf-8')
        # BOTH paths pinned. The script is copied into a temp directory, so
        # its own ROOT resolves there and SRC would look for /tmp/.../site-src.
        # Pinning only OUT made the check report "the builder itself fails",
        # which is a true statement about the copy and useless about the repo.
        script = script.replace(
            "OUT = ROOT / 'site'", f"OUT = Path({str(stage)!r})", 1
        ).replace(
            "SRC = ROOT / 'site-src'", f"SRC = Path({str(ROOT / 'site-src')!r})", 1
        )
        runner = Path(tmp) / 'build.py'
        runner.write_text(script, encoding='utf-8')
        r = subprocess.run([sys.executable, str(runner)], capture_output=True, text=True)
        if r.returncode != 0:
            fail(f'the builder itself fails: {r.stderr.strip().splitlines()[-1:]}')
            return
        for page in built_pages():
            mirror = stage / page.relative_to(SITE)
            if not mirror.exists():
                fail(f'{page.relative_to(ROOT)} is not produced by the builder: '
                     'it is either stale or hand-written')
                continue
            if mirror.read_text(encoding='utf-8') != page.read_text(encoding='utf-8'):
                fail(f'{page.relative_to(ROOT)} differs from the build. '
                     'Somebody edited the OUTPUT; edit site-src/ and re-run '
                     'python3 scripts/build-site.py')


def main() -> int:
    pages = built_pages()
    if len(pages) < 8:
        print(f'REFUSING: only {len(pages)} built page(s) found in site/. '
              'Run python3 scripts/build-site.py', file=sys.stderr)
        return 1

    check_build_is_current()

    titles: dict[str, str] = {}
    descs: dict[str, str] = {}
    canonicals: dict[str, str] = {}
    h1s_seen: dict[str, str] = {}
    linked_to: set[str] = set()
    all_urls = {url_for(p) for p in pages}

    for page in pages:
        rel = page.relative_to(ROOT)
        text = page.read_text(encoding='utf-8')
        url = url_for(page)
        head = text[: text.index('</head>')] if '</head>' in text else text

        # --- title ---
        title = one(r'<title>(.*?)</title>', head)
        if not title:
            fail(f'{rel}: no <title>')
        else:
            plain = html.unescape(title)
            if plain in titles:
                fail(f'{rel}: title duplicates {titles[plain]}')
            titles[plain] = str(rel)
            if len(plain) > TITLE_HARD:
                fail(f'{rel}: title is {len(plain)} chars, over the {TITLE_HARD} ceiling')
            elif len(plain) > TITLE_SOFT:
                warn(f'{rel}: title is {len(plain)} chars; Google shows about {TITLE_SOFT}')

        # --- description ---
        desc = one(r'<meta name="description" content="(.*?)">', head)
        if not desc:
            fail(f'{rel}: no meta description')
        else:
            plain = html.unescape(desc)
            if plain in descs:
                fail(f'{rel}: description duplicates {descs[plain]}')
            descs[plain] = str(rel)
            if len(plain) > DESC_HARD:
                fail(f'{rel}: description is {len(plain)} chars, over the {DESC_HARD} ceiling')
            elif not (DESC_SOFT_LOW <= len(plain) <= DESC_SOFT_HIGH):
                warn(f'{rel}: description is {len(plain)} chars; aim for '
                     f'{DESC_SOFT_LOW} to {DESC_SOFT_HIGH}')

        # --- canonical, and that it resolves to this very file ---
        canon = one(r'<link rel="canonical" href="(.*?)">', head)
        if not canon:
            fail(f'{rel}: no canonical')
        else:
            if canon in canonicals:
                fail(f'{rel}: canonical duplicates {canonicals[canon]}: two pages '
                     'claiming to be the same URL means one of them is dropped')
            canonicals[canon] = str(rel)
            expect = f'{DOMAIN}/' if url == '/' else f'{DOMAIN}{url}'
            if canon != expect:
                fail(f'{rel}: canonical is {canon}, but this file is served at {expect}')

        # --- open graph and the share card ---
        for tag in ('og:title', 'og:description', 'og:url', 'og:image', 'og:type'):
            if f'property="{tag}"' not in head:
                fail(f'{rel}: no {tag}')
        if 'twitter:card' not in head:
            fail(f'{rel}: no twitter:card')
        if 'content="summary_large_image"' in head and not (SITE / 'og.png').exists():
            fail(f'{rel}: declares a large share card but site/og.png does not exist. '
                 'Run node scripts/build-og.mjs')

        # --- the favicon, which is why Google showed a grey globe ---
        #
        # The tag was present and the icon still did not appear, because the
        # href was a data: URI. Google fetches the favicon in its own request,
        # separate from the page, so it needs an address. A data: URI is not an
        # address. Nothing about the page looks wrong, which is what makes this
        # worth a guard rather than a comment.
        # Comments are stripped first. A browser does not act on a tag inside a
        # comment and neither should this: the comment above these links quotes
        # the old data: URI as an example, and scanning it flagged every page.
        head_live = re.sub(r'<!--.*?-->', '', head, flags=re.S)
        icon_links = re.findall(r'<link[^>]*rel="(?:icon|apple-touch-icon)"[^>]*>',
                                head_live, re.I)
        if not icon_links:
            fail(f'{rel}: no <link rel="icon">, so the browser tab and the search '
                 'result both fall back to a generic icon')
        for link in icon_links:
            href = one(r'href="([^"]+)"', link)
            if not href:
                fail(f'{rel}: an icon link has no href: {link}')
            elif href.startswith('data:'):
                fail(f'{rel}: the favicon is a data: URI. It has no URL, and Google '
                     'fetches the favicon separately from the page, so there is '
                     'nothing for it to fetch. Use a real file.')
            elif href.startswith('/') and not (SITE / href.lstrip('/')).exists():
                fail(f'{rel}: icon link points at {href}, which does not exist. '
                     'Run node scripts/build-icons.mjs')
        manifest_href = one(r'<link[^>]*rel="manifest"[^>]*href="([^"]+)"', head_live)
        if manifest_href and manifest_href.startswith('/') \
                and not (SITE / manifest_href.lstrip('/')).exists():
            fail(f'{rel}: manifest link points at {manifest_href}, which does not exist')

        # --- every image the page loads must exist ---
        # The brand mark in the nav and the footer is an <img> pointing at the
        # shared icon file, precisely so it cannot drift away from the favicon.
        # That trade needs this check, or a rename breaks the logo on all
        # sixteen pages at once and nothing says so.
        for src in re.findall(r'<img[^>]*src="(/[^"]+)"', text):
            if not (SITE / src.lstrip('/')).exists():
                fail(f'{rel}: <img src="{src}"> has no file behind it')

        # --- exactly one h1, and no two pages sharing one ---
        h1s = re.findall(r'<h1[^>]*>(.*?)</h1>', text, re.I | re.S)
        if len(h1s) != 1:
            fail(f'{rel}: {len(h1s)} <h1> elements, expected exactly 1')
        else:
            plain = re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', h1s[0])).strip()
            if plain in h1s_seen:
                # Two pages claiming the same subject compete for the same query
                # and neither wins it. The fee page shipped with the home page's
                # h1 word for word, which is exactly the cannibalisation the
                # split was supposed to avoid.
                fail(f'{rel}: h1 duplicates {h1s_seen[plain]}: {plain!r}')
            h1s_seen[plain] = str(rel)

        # --- language and viewport, which decide whether a phone can read it ---
        if 'lang="en-PK"' not in text[:400]:
            fail(f'{rel}: <html> has no lang="en-PK"')
        if 'name="viewport"' not in head:
            fail(f'{rel}: no viewport meta, so a phone renders it at 980px and zooms out')

        # --- every JSON-LD block must parse ---
        for i, block in enumerate(
            re.findall(r'<script type="application/ld\+json">(.*?)</script>', text, re.S), 1
        ):
            try:
                doc = json.loads(block)
            except json.JSONDecodeError as e:
                fail(f'{rel}: JSON-LD block {i} does not parse: {e}')
                continue
            if '@context' not in doc:
                fail(f'{rel}: JSON-LD block {i} has no @context')

        # --- internal links: they must resolve, and they feed the orphan check ---
        for href in re.findall(r'href="(/[^"#?]*)"', text):
            # The handbook is the one page that really is a .html URL, because
            # it is built by a different script and never had a clean path.
            if href == '/guide.html':
                if not (SITE / 'guide.html').exists():
                    fail(f'{rel}: links to /guide.html which does not exist')
                linked_to.add(href)
                continue
            # Anything else with an extension is a FILE: /styles.css,
            # /favicon.ico, /og.png, /site.webmanifest. It must exist, but it is
            # not a page and it plays no part in the orphan check. This used to
            # be a hand-kept list of six names, so every asset added afterwards
            # was reported as a missing page.
            if '.' in href.rsplit('/', 1)[-1]:
                if not (SITE / href.lstrip('/')).exists():
                    fail(f'{rel}: links to {href}, which does not exist')
                continue
            target = SITE / 'index.html' if href == '/' else SITE / (href.lstrip('/') + '.html')
            if not target.exists():
                fail(f'{rel}: link to {href} has no page behind it '
                     f'(looked for site/{target.relative_to(SITE)})')
            else:
                linked_to.add(href)

    # --- orphans ---
    for url in sorted(all_urls):
        # / is reached by the brand mark on every page and by every crawler
        # anyway; /404 exists to be served on a wrong URL and is linked from
        # nothing on purpose.
        if url in ('/', '/404'):
            continue
        if url not in linked_to:
            fail(f'{url} is linked from no page: a crawler will not find it and a '
                 'visitor cannot reach it')

    # --- sitemap, both directions ---
    smap = SITE / 'sitemap.xml'
    if not smap.exists():
        fail('site/sitemap.xml is missing')
    else:
        listed = set(re.findall(r'<loc>(.*?)</loc>', smap.read_text(encoding='utf-8')))
        for url in sorted(all_urls):
            if url == '/404':
                continue
            expect = f'{DOMAIN}/' if url == '/' else f'{DOMAIN}{url}'
            if expect not in listed:
                fail(f'{expect} is a real page but is not in sitemap.xml')
        for loc in sorted(listed):
            path = loc[len(DOMAIN):]
            if path in ('/', '/guide.html'):
                continue
            if not (SITE / (path.lstrip('/') + '.html')).exists():
                fail(f'sitemap.xml lists {loc}, which has no page behind it')
        if f'{DOMAIN}/404' in listed:
            fail('sitemap.xml lists /404, which must never be offered as a destination')

    # --- reviews: the page, the data and the markup must all agree ---
    #
    # /reviews is the one page whose content is DATA rather than prose, baked in
    # by build-site.py from site-src/data/reviews.json, which
    # scripts/fetch-reviews.py writes out of the database. Three ways that can
    # go wrong, and all three would be a lie about customers:
    #
    #   * the JSON says twelve reviews and the page shows eleven
    #   * an aggregateRating is emitted with no reviews behind it, which Google
    #     treats as invalid and a reader treats as a claim
    #   * the rating in the markup does not match the rating on the page
    #
    # It cannot detect a hand-written review, because nothing can: that is
    # fabrication, not drift. What it can do is make sure the number in the
    # markup came from the same file as the words on the page.
    rjson = ROOT / 'site-src' / 'data' / 'reviews.json'
    rpage = SITE / 'reviews.html'
    if rpage.exists():
        text = rpage.read_text(encoding='utf-8')
        shown = len(re.findall(r'<article class="review">', text))
        agg = re.search(r'"reviewCount":\s*(\d+)', text)
        avg = re.search(r'"ratingValue":\s*"([\d.]+)"', text)
        if not rjson.exists():
            fail('site/reviews.html exists but site-src/data/reviews.json does not. '
                 'Run python3 scripts/fetch-reviews.py')
        else:
            data = json.loads(rjson.read_text(encoding='utf-8'))
            total = int((data.get('summary') or {}).get('total') or 0)
            listed = len(data.get('reviews') or [])
            if total != listed:
                fail(f'reviews.json says {total} reviews and lists {listed}')
            if shown != total:
                fail(f'/reviews shows {shown} review(s) and reviews.json says {total}. '
                     'Re-run scripts/build-site.py')
            if total == 0 and agg:
                fail('/reviews emits an aggregateRating with no reviews behind it. '
                     'A rating of nothing from nobody is a claim, not a rating.')
            if total > 0:
                if not agg:
                    fail(f'/reviews shows {total} review(s) but emits no aggregateRating')
                elif int(agg.group(1)) != total:
                    fail(f'the aggregateRating claims {agg.group(1)} reviews, the page has {total}')
                page_avg = str((data.get('summary') or {}).get('average'))
                if avg and avg.group(1) != page_avg:
                    fail(f'the marked-up rating is {avg.group(1)} and the data says {page_avg}')

    # --- the icon set itself ---
    #
    # Google will use a favicon only if it can fetch it, and it prefers a square
    # whose side is a multiple of 48. These are generated from one source by
    # scripts/build-icons.mjs; the checks are here so that a hand edit, a
    # rename or a half-finished regeneration is caught before it is uploaded.
    src_icon = ROOT / 'site-src' / 'icon.svg'
    if not src_icon.exists():
        fail('site-src/icon.svg is missing: it is the source of every icon')
    elif not (SITE / 'icon.svg').exists():
        fail('site/icon.svg is missing. Run node scripts/build-icons.mjs')
    elif src_icon.read_bytes() != (SITE / 'icon.svg').read_bytes():
        # The nav logo, the footer logo and the favicon all point at
        # site/icon.svg. If it stops matching its source, the site is showing a
        # mark that no longer comes from the file everything is generated from,
        # which is how the website and the app ended up with two different logos.
        fail('site/icon.svg has drifted from site-src/icon.svg. '
             'Run node scripts/build-icons.mjs')

    # icon.svg is loaded as an EXTERNAL image by the nav and the footer, so a
    # browser parses it as XML and rejects the whole file if it is not well
    # formed, silently: the logo is just missing. Inline SVG in a page is
    # parsed as HTML, which is lenient, so the icon generator will happily
    # produce perfect PNGs from a file no browser will load as an image.
    # This shipped once with "--brand" inside an XML comment, which is illegal
    # because XML forbids a double hyphen there, and every page lost its logo.
    for svg in (src_icon, SITE / 'icon.svg'):
        if svg.exists():
            try:
                xml.dom.minidom.parse(str(svg))
            except Exception as e:
                fail(f'{svg.relative_to(ROOT)} is not well-formed XML: {e}. A browser '
                     'will refuse to render it as an image, and say nothing.')

    ico = SITE / 'favicon.ico'
    if not ico.exists():
        fail('site/favicon.ico is missing. It is the address Google tries when a '
             'page declares no icon, and the last line of defence against a grey '
             'globe. Run node scripts/build-icons.mjs')
    else:
        raw = ico.read_bytes()
        if len(raw) < 22 or raw[0:4] != b'\x00\x00\x01\x00':
            fail('site/favicon.ico is not an ICO file')
        else:
            count = int.from_bytes(raw[4:6], 'little')
            sizes = {raw[6 + i * 16] or 256 for i in range(count)}
            if 48 not in sizes:
                fail(f'site/favicon.ico carries {sorted(sizes)} and no 48. Google asks '
                     'for a multiple of 48 and may skip anything smaller.')

    # PNG dimensions come out of the IHDR chunk, which is always the first
    # chunk and always at a fixed offset. No image library needed.
    def png_size(path):
        raw = path.read_bytes()
        if raw[:8] != b'\x89PNG\r\n\x1a\n':
            return None
        return int.from_bytes(raw[16:20], 'big'), int.from_bytes(raw[20:24], 'big')

    # The three Google may choose from must be multiples of 48. icon-512 is the
    # Android home-screen size referenced from the manifest, where no such rule
    # applies, so it is checked for squareness only.
    for name, side, google_facing in (('icon-48.png', 48, True), ('icon-96.png', 96, True),
                                      ('icon-192.png', 192, True), ('icon-512.png', 512, False),
                                      ('icon-maskable-512.png', 512, False),
                                      ('apple-touch-icon.png', 180, False)):
        f = SITE / name
        if not f.exists():
            fail(f'site/{name} is missing. Run node scripts/build-icons.mjs')
            continue
        got = png_size(f)
        if got is None:
            fail(f'site/{name} is not a PNG')
        elif got != (side, side):
            fail(f'site/{name} is {got[0]}x{got[1]}, expected {side}x{side}')
        elif google_facing and side % 48:
            fail(f'site/{name} is {side}px, which is not a multiple of 48')

    manifest = SITE / 'site.webmanifest'
    if not manifest.exists():
        fail('site/site.webmanifest is missing')
    else:
        try:
            mdata = json.loads(manifest.read_text(encoding='utf-8'))
        except json.JSONDecodeError as e:
            fail(f'site/site.webmanifest does not parse: {e}')
        else:
            for icon in mdata.get('icons') or []:
                src = icon.get('src', '')
                if src.startswith('/') and not (SITE / src.lstrip('/')).exists():
                    fail(f'site.webmanifest lists {src}, which does not exist')
            # Android crops a maskable icon to a circle 80% of the width. The
            # app's manifest used to declare the SAME artwork as "any" and
            # "maskable", which put the tassel inside the crop zone on every
            # Android phone.
            purposes = {}
            for icon in mdata.get('icons') or []:
                purposes.setdefault(icon.get('purpose', 'any'), set()).add(icon.get('src'))
            shared = purposes.get('any', set()) & purposes.get('maskable', set())
            if shared:
                fail(f'site.webmanifest declares {sorted(shared)} as both "any" and '
                     '"maskable". A maskable icon needs its own artwork with the '
                     'mark inside the safe area, or Android crops it.')

    # robots.txt must not put the icons out of reach. Google fetches a favicon
    # as a separate request and obeys robots.txt when it does, so a Disallow
    # covering the icons is another way to end up with a grey globe.
    robots = SITE / 'robots.txt'
    if robots.exists():
        for line in robots.read_text(encoding='utf-8').splitlines():
            if line.lower().startswith('disallow:'):
                rule = line.split(':', 1)[1].strip()
                if rule and any(
                    p.startswith(rule) for p in ('/favicon.ico', '/icon.svg', '/icon-192.png')
                ):
                    fail(f'robots.txt has "Disallow: {rule}", which blocks the favicon')

    # --- _headers: one CSP, and no path given Cache-Control twice ---
    #
    # Two Content-Security-Policy headers are enforced together, so a second
    # rule meant to relax the policy for one page tightens it everywhere
    # instead, silently. Two Cache-Control rules on one path is simply
    # ambiguous. Both are invisible until something breaks in production.
    headers = SITE / '_headers'
    if not headers.exists():
        fail('site/_headers is missing: the site would ship with no CSP and no '
             'X-Content-Type-Options')
    else:
        rules, cur = [], None
        for line in headers.read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            if line.startswith('/'):
                cur = (line.strip(), [])
                rules.append(cur)
            elif line.startswith((' ', '\t')) and cur is not None:
                cur[1].append(line.strip().split(':', 1)[0].lower())
        csps = [pat for pat, names in rules if 'content-security-policy' in names]
        if len(csps) != 1:
            fail(f'site/_headers has {len(csps)} Content-Security-Policy rules '
                 f'({csps}). A browser enforces every CSP header it receives, so a '
                 'second one can only ever tighten the first.')
        cc = [pat for pat, names in rules if 'cache-control' in names]
        if '/*' in cc and len(cc) > 1:
            fail('site/_headers sets Cache-Control on /* and on specific paths, so '
                 'those paths get two values')
        if len(cc) != len(set(cc)):
            fail('site/_headers sets Cache-Control twice for the same path')
        required = {'content-security-policy', 'x-content-type-options', 'referrer-policy'}
        catchall = {n for pat, names in rules if pat == '/*' for n in names}
        for missing in sorted(required - catchall):
            fail(f'site/_headers does not set {missing} for /*')

    # --- robots.txt must point at the sitemap, or nothing reads it ---
    robots = SITE / 'robots.txt'
    if not robots.exists():
        fail('site/robots.txt is missing')
    else:
        body = robots.read_text(encoding='utf-8')
        if f'Sitemap: {DOMAIN}/sitemap.xml' not in body:
            fail('robots.txt does not name the sitemap at the live domain')
        if re.search(r'^\s*Disallow:\s*/\s*$', body, re.M):
            fail('robots.txt disallows the whole site')

    for w in warns:
        print(f'  warning: {w}')
    if fails:
        print()
        for f in fails:
            print(f'  {f}')
        print()
        print('::error::the built site would not index correctly')
        return 1

    print(f'{len(pages)} pages: unique titles and descriptions, canonicals that resolve, '
          f'one h1 each, valid JSON-LD, no broken internal links, no orphans, '
          f'sitemap and robots agree'
          + (f' ({len(warns)} warning(s))' if warns else ''))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
