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
            if href in ('/styles.css', '/wire.js', '/config.js', '/og.png', '/robots.txt',
                        '/sitemap.xml'):
                continue
            if href == '/guide.html':
                if not (SITE / 'guide.html').exists():
                    fail(f'{rel}: links to /guide.html which does not exist')
                linked_to.add(href)
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
