#!/usr/bin/env python3
"""Build the marketing site: one layout, many pages, one sitemap.

WHY THERE IS A BUILD STEP AT ALL

The site was ONE long scrolling page, and that is a real ceiling rather than a
matter of taste. A page can rank for one intent. A school owner searching "fee
challan software" and one searching "school attendance register app" are asking
different questions, and a single page answering both answers neither as well
as two pages would. So the site is now twelve pages plus the handbook.

Twelve pages hand-written means twelve copies of the nav, twelve copies of the
footer, and a guarantee that they drift apart on the next change. So the shell
lives once in site-src/layout.html, each page is a body fragment with a small
front matter block in site-src/pages/, and this script assembles them.

Python standard library only, no dependencies, same as scripts/build-guide.py.
The OUTPUT is committed, because the deployment is a hand upload of site/ to
Cloudflare and the person uploading needs files, not a toolchain.

URL SHAPE, and why the files are flat .html

Cloudflare Pages serves /fee-management for an uploaded fee-management.html and
301s /fee-management.html to the extensionless path. So the extensionless URL is
the one that answers 200 with no redirect, which is the one that must be
canonical and the one every internal link uses. Directories with index.html
would work too, but then whether /x or /x/ is canonical depends on the host's
trailing-slash policy, and getting that wrong points every canonical at a
redirect.

    python3 scripts/build-site.py          # build
    python3 scripts/check-site-seo.py      # then verify the result

FRONT MATTER, terminated by a line of three dashes:

    path: /fee-management        the URL, no extension. "/" for the home page.
    title: ...                  the <title>, unique, aim for under 60 chars
    description: ...            the meta description, unique, 120 to 160 chars
    nav: Fees                   nav label, or omit to keep it out of the nav
    nav_order: 1
    og_type: website            website (default) or article
    schema: software            which JSON-LD block, from SCHEMAS below
    breadcrumb: Fee management  the trail's last crumb; omit on the home page
    priority: 1.0               sitemap priority
    sitemap: no                 keep this page out of sitemap.xml
    ---
"""
import json
import re
import sys
from datetime import date
from html import escape as html_escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'site-src'
OUT = ROOT / 'site'
SITE = 'https://theschoolmanager.site'

# THE PRICE LIST, typed once. public.plans is the truth (migration 0155 sets
# it); this is the site's one hand copy of it. The pricing cards, every "from"
# price, the two meta descriptions that quote a price and the JSON-LD offers are
# all filled from here at build time through {{PLAN_<code>_<field>}} and
# {{FROM_PRICE}} placeholders (see plan_tokens below), so a price rise is one
# edit here and a rebuild.
#
# supabase/check-site-prices.sh compares this list, the built cards and the
# JSON-LD against the database in BOTH directions: an active plan missing here
# fails, and so does an entry for a plan the database has retired.
#
# Not read from the database at build time on purpose: the build is standard
# library only and runs with no credentials, and CI holds the two together.
#
# by_arrangement: Enterprise has no list price. We agree a monthly price with
# each school, so it carries no figures and the page says "Priced with you".
PLANS = [
    {'code': 'starter', 'name': 'Starter', 'min': 1, 'limit': 280,
     'monthly': 2000, 'quarterly': 5400, 'yearly': 20000},
    {'code': 'growth', 'name': 'Growth', 'min': 281, 'limit': 1000,
     'monthly': 4000, 'quarterly': 10800, 'yearly': 40000},
    {'code': 'enterprise', 'name': 'Enterprise', 'min': 1001, 'limit': None,
     'by_arrangement': True},
]


def rupees(n: int) -> str:
    """2000 -> 'Rs 2,000', the way every page prints money."""
    return f'Rs {n:,}'


def check_plans() -> None:
    """Refuse a price list the page copy would describe wrongly.

    The pricing page says, in words, that three months is 10% off and a year is
    two months free, and it prints the saving in rupees. Those sentences are
    not filled in from here, so a list where they stop being true has to stop
    the build rather than publish a page that contradicts its own figures.
    """
    codes = [p['code'] for p in PLANS]
    if len(set(codes)) != len(codes):
        sys.exit('PLANS: a plan code is listed twice')
    previous_limit = 0
    for p in PLANS:
        if previous_limit is None:
            sys.exit(f'PLANS: {p["code"]} comes after the plan with no limit, so no '
                     'school could ever be on it')
        if not re.fullmatch(r'[a-z0-9]+', p['code']):
            sys.exit(f'PLANS: code {p["code"]!r} must be lower case letters and digits')
        # The bands must meet with no gap and no overlap, or a school of some
        # size has no plan on the page (601 to 1,000 pupils once had none).
        if p['min'] != previous_limit + 1:
            sys.exit(f'PLANS: {p["code"]} starts at {p["min"]} pupils, but the plan '
                     f'before it stops at {previous_limit}')
        if p.get('by_arrangement'):
            if p['limit'] is not None or any(k in p for k in ('monthly', 'quarterly', 'yearly')):
                sys.exit(f'PLANS: {p["code"]} is by arrangement, so it has no limit and no prices')
            previous_limit = None
            continue
        m, q, y = p['monthly'], p['quarterly'], p['yearly']
        if q * 10 != m * 3 * 9:
            sys.exit(f'PLANS: {p["code"]} three months is {rupees(q)}, which is not 10% off '
                     f'3 x {rupees(m)}, and the pricing page says it is')
        if y != m * 10:
            sys.exit(f'PLANS: {p["code"]} a year is {rupees(y)}, which is not two months free '
                     f'on {rupees(m)} a month, and the pricing page says it is')
        previous_limit = p['limit']
    if not any(not p.get('by_arrangement') for p in PLANS):
        sys.exit('PLANS: no priced plan, so there is no "from" price to print')


check_plans()


def band(p: dict) -> str:
    """The pupils a plan is for, in the words the cards print."""
    if p['limit'] is None:
        return f'More than {p["min"] - 1:,} pupils'
    return f'{p["min"]:,} to {p["limit"]:,} pupils'


def plan_tokens() -> dict[str, str]:
    """Every {{...}} a page may use to print a price, name or band."""
    tokens: dict[str, str] = {}
    priced = [p for p in PLANS if not p.get('by_arrangement')]
    # "From" is a claim about the minimum, so it is the cheapest monthly price
    # and never simply the first plan in the list.
    tokens['FROM_PRICE'] = rupees(min(p['monthly'] for p in priced))
    for p in PLANS:
        k = f'PLAN_{p["code"]}_'
        tokens[k + 'name'] = p['name']
        tokens[k + 'band'] = band(p)
        tokens[k + 'min'] = f'{p["min"]:,}'
        if p['limit'] is not None:
            tokens[k + 'limit'] = f'{p["limit"]:,}'
        if p.get('by_arrangement'):
            continue
        m, q, y = p['monthly'], p['quarterly'], p['yearly']
        tokens[k + 'monthly'] = rupees(m)
        tokens[k + 'quarterly'] = rupees(q)
        tokens[k + 'yearly'] = rupees(y)
        tokens[k + 'save3'] = rupees(3 * m - q)
        tokens[k + 'save12'] = rupees(12 * m - y)
    return tokens


TOKENS = plan_tokens()


def fill_plans(text: str, where: str) -> str:
    """Replace the price placeholders, refusing one that names nothing.

    A typo such as {{PLAN_growht_monthly}} must stop the build. Left alone it
    would be caught as an unreplaced placeholder anyway, but this names the
    plans and fields that do exist, which is the message worth reading.
    """
    def one(m: re.Match) -> str:
        key = m.group(1)
        if key not in TOKENS:
            sys.exit(f'{where}: {{{{{key}}}}} is not a plan figure. Known: '
                     + ', '.join(sorted(TOKENS)))
        return TOKENS[key]
    return re.sub(r'\{\{((?:PLAN_|FROM_)\w+)\}\}', one, text)


def offer(p: dict) -> dict:
    """One JSON-LD Offer.

    A priced plan carries its monthly price as the Offer price and all three
    terms as UnitPriceSpecifications, so a crawler reads "Rs 2,000 a month"
    rather than a one-off Rs 2,000. Enterprise has no list price, so its Offer
    has a description and no price: inventing a figure for it would be a price
    nobody will honour.
    """
    if p.get('by_arrangement'):
        return {
            '@type': 'Offer',
            'name': p['name'],
            'description': (f'For schools with more than {p["min"] - 1:,} pupils. No pupil '
                            'limit. We agree a monthly price with each school; three '
                            'months is 10% off it and a year is two months free, unless we '
                            'agree those too.'),
            'priceCurrency': 'PKR',
            'availability': 'https://schema.org/InStock',
        }
    m, q, y = p['monthly'], p['quarterly'], p['yearly']

    def spec(name: str, price: int, duration: str, unit: str) -> dict:
        return {
            '@type': 'UnitPriceSpecification',
            'name': name,
            'price': str(price),
            'priceCurrency': 'PKR',
            'billingDuration': duration,
            'unitText': unit,
        }

    return {
        '@type': 'Offer',
        'name': p['name'],
        'description': f'For schools with {band(p)}.',
        'price': str(m),
        'priceCurrency': 'PKR',
        'availability': 'https://schema.org/InStock',
        'priceSpecification': [
            spec('Monthly', m, 'P1M', 'MONTH'),
            spec('Three months, 10% off', q, 'P3M', 'THREE MONTHS'),
            spec('A year, two months free', y, 'P1Y', 'YEAR'),
        ],
    }

def load_profiles() -> dict:
    """site-src/data/profiles.json: where this business exists elsewhere.

    sameAs tells Google that the Google Business Profile, the G2 listing and
    this website are one company rather than several with similar names. It is
    only worth anything if every URL resolves, because a sameAs is a claim
    Google can check, so the file ships empty and anything that is not an
    https:// URL stops the build rather than being quietly dropped. A silently
    dropped entry would look filled in and do nothing.
    """
    path = SRC / 'data' / 'profiles.json'
    if not path.exists():
        return {}
    raw = json.loads(path.read_text(encoding='utf-8'))
    data = {k: v for k, v in raw.items() if not k.startswith('_')}
    for url in data.get('sameAs') or []:
        if not isinstance(url, str) or not url.startswith('https://'):
            sys.exit(f'profiles.json: sameAs entries must be https:// URLs, got {url!r}')
    if len(set(data.get('sameAs') or [])) != len(data.get('sameAs') or []):
        sys.exit('profiles.json: the same URL is listed twice in sameAs')
    email = data.get('email') or ''
    if email and ('@' not in email or email.startswith('@') or ' ' in email):
        sys.exit(f'profiles.json: email does not look like an address: {email!r}')
    return data


PROFILES = load_profiles()

# The logo, as its own node so Organization and anything else can point at it
# by @id instead of repeating it. Google's logo guidance asks for a crawlable
# image of at least 112x112; this is the 512 icon that scripts/build-icons.mjs
# generates from the one mark, so the logo in a Knowledge Panel and the favicon
# in a search result cannot end up being different pictures.
LOGO = {
    '@type': 'ImageObject',
    '@id': f'{SITE}/#logo',
    'url': f'{SITE}/icon-512.png',
    'contentUrl': f'{SITE}/icon-512.png',
    'width': 512,
    'height': 512,
    'caption': 'The School Manager',
}

ORGANISATION = {
    '@type': 'Organization',
    '@id': f'{SITE}/#org',
    'name': 'The School Manager',
    'url': f'{SITE}/',
    'description': 'School management software built in Pakistan for Pakistani private schools.',
    'areaServed': {'@type': 'Country', 'name': 'Pakistan'},
    'knowsLanguage': ['en', 'ur'],
    'logo': LOGO,
    'image': {'@id': f'{SITE}/#logo'},
}
if PROFILES.get('sameAs'):
    ORGANISATION['sameAs'] = PROFILES['sameAs']
if PROFILES.get('email'):
    ORGANISATION['email'] = PROFILES['email']

SOFTWARE = {
    '@type': 'SoftwareApplication',
    '@id': f'{SITE}/#software',
    'name': 'The School Manager',
    'applicationCategory': 'BusinessApplication',
    'applicationSubCategory': 'School management software',
    'operatingSystem': 'Any modern web browser, Windows desktop',
    'url': f'{SITE}/',
    'publisher': {'@id': f'{SITE}/#org'},
    'inLanguage': 'en-PK',
    'offers': [offer(p) for p in PLANS],
    'featureList': [
        'Family fee collection: one payment across all siblings',
        'Expected versus collected reconciliation',
        'Gapless receipt numbering with reversals',
        'Daily attendance that works offline',
        'Exam computation and printed result cards',
        'Expense ledger, payroll and monthly profit',
        'Parent portal with fee balance and results',
    ],
}


# ---------------------------------------------------------------------------
# Reviews, baked in from site-src/data/reviews.json (written by
# scripts/fetch-reviews.py) so the structured data is in the HTML Google fetches
# rather than in a runtime response that can silently stop arriving.
# ---------------------------------------------------------------------------
REVIEW_DATA = SRC / 'data' / 'reviews.json'


def load_reviews() -> dict:
    if not REVIEW_DATA.exists():
        return {'summary': {'total': 0, 'average': None}, 'reviews': []}
    return json.loads(REVIEW_DATA.read_text(encoding='utf-8'))


def review_schema(data: dict) -> list[dict]:
    """aggregateRating and the reviews, or NOTHING if there are none.

    An aggregateRating of 0 from 0 reviews is not a rating, and marking one up
    would be a claim about customers who have not said anything. Google also
    treats an aggregateRating with reviewCount 0 as invalid, so emitting it
    would be both dishonest and broken.
    """
    s = data.get('summary') or {}
    total = int(s.get('total') or 0)
    if total < 1 or s.get('average') is None:
        return []
    return [{
        '@type': 'AggregateRating',
        '@id': f'{SITE}/reviews#rating',
        'itemReviewed': {'@id': f'{SITE}/#software'},
        'ratingValue': str(s['average']),
        'bestRating': '5',
        'worstRating': '1',
        'ratingCount': total,
        'reviewCount': total,
    }] + [{
        '@type': 'Review',
        'itemReviewed': {'@id': f'{SITE}/#software'},
        'reviewRating': {
            '@type': 'Rating',
            'ratingValue': str(r['rating']),
            'bestRating': '5',
            'worstRating': '1',
        },
        # The reviewer is the SCHOOL, which is who wrote it and what a reader
        # cares about. No person is ever named: 0093 keeps author_name out of
        # the public view entirely.
        'author': {'@type': 'Organization', 'name': r['school_name']},
        'name': r['title'],
        'reviewBody': r['body'],
        'datePublished': r['published_on'],
    } for r in data.get('reviews') or []]


def jsonld(*blocks: dict) -> str:
    """One @graph, so the entities can reference each other by @id."""
    doc = {'@context': 'https://schema.org', '@graph': list(blocks)}
    return ('<script type="application/ld+json">\n'
            + json.dumps(doc, indent=2, ensure_ascii=False)
            + '\n</script>')


def breadcrumb_schema(label: str, path: str) -> dict:
    return {
        '@type': 'BreadcrumbList',
        'itemListElement': [
            {'@type': 'ListItem', 'position': 1, 'name': 'Home', 'item': f'{SITE}/'},
            {'@type': 'ListItem', 'position': 2, 'name': label, 'item': f'{SITE}{path}'},
        ],
    }


def split_front_matter(raw: str, name: str) -> tuple[dict, str]:
    if '\n---\n' not in raw:
        sys.exit(f'{name}: no front matter terminator (a line of exactly ---)')
    head, body = raw.split('\n---\n', 1)
    meta: dict[str, str] = {}
    for i, line in enumerate(head.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ':' not in line:
            sys.exit(f'{name} line {i}: front matter needs "key: value", got {line!r}')
        k, v = line.split(':', 1)
        meta[k.strip()] = v.strip()
    for required in ('path', 'title', 'description'):
        if required not in meta:
            sys.exit(f'{name}: front matter is missing {required}')
    return meta, body


def out_path(url_path: str) -> Path:
    """The file that Cloudflare will serve at this URL."""
    if url_path == '/':
        return OUT / 'index.html'
    return OUT / (url_path.strip('/') + '.html')


def render_reviews(data: dict) -> str:
    """The visible list, or an honest empty state.

    Rendered here rather than only by wire.js so the page is complete with
    JavaScript switched off and so a crawler reads the same words a visitor
    does. wire.js replaces this with the live list on top.
    """
    s = data.get('summary') or {}
    total = int(s.get('total') or 0)
    if total < 1:
        return (
            '      <div class="card" style="max-width:60ch">\n'
            '        <h3>No reviews yet</h3>\n'
            '        <p>\n'
            '          A school can only write one after using this for three weeks and\n'
            '          issuing twenty real receipts, which is deliberate: it is what makes\n'
            '          the reviews on this page worth reading. Nothing here is written by\n'
            '          us, and there is nothing here yet.\n'
            '        </p>\n'
            '      </div>'
        )

    bars = []
    for label, key in (('5', 'five'), ('4', 'four'), ('3', 'three'), ('2', 'two'), ('1', 'one')):
        n = int(s.get(key) or 0)
        pct = round(n * 100 / total)
        bars.append(
            f'        <div class="rdist__row">'
            f'<span class="rdist__k">{label}</span>'
            f'<span class="bar"><i style="width:{pct}%"></i></span>'
            f'<span class="rdist__n">{n}</span></div>'
        )

    cards = []
    for r in data.get('reviews') or []:
        who = html_escape(r['school_name'])
        if r.get('city'):
            who += ', ' + html_escape(r['city'])
        stars = int(r['rating'])
        cards.append(
            '      <article class="review">\n'
            '        <p class="review__rating">\n'
            f'          <span class="review__stars" aria-hidden="true">{"&#9733;" * stars}'
            f'{"<span>&#9734;</span>" * (5 - stars)}</span>\n'
            f'          <b>{stars} out of 5</b>\n'
            '        </p>\n'
            f'        <h3>{html_escape(r["title"])}</h3>\n'
            f'        <p>{html_escape(r["body"])}</p>\n'
            f'        <footer>{who} <span>&middot;</span> '
            f'<time datetime="{r["published_on"]}">{r["published_on"]}</time></footer>\n'
            '      </article>'
        )

    avg = s.get('average')
    return (
        '      <div class="rsum" id="reviews-summary">\n'
        f'        <div class="rsum__avg"><b>{avg}</b><span>out of 5</span></div>\n'
        '        <div class="rdist">\n' + '\n'.join(bars) + '\n        </div>\n'
        f'        <p class="rsum__n">From <b>{total}</b> school'
        f'{"" if total == 1 else "s"} that wrote a review. Every published review is '
        'counted here, including the critical ones.</p>\n'
        '      </div>\n\n'
        '      <div class="reviews" id="reviews-list">\n' + '\n'.join(cards) + '\n      </div>'
    )


def main() -> int:
    layout = (SRC / 'layout.html').read_text(encoding='utf-8')
    reviews = load_reviews()
    pages = sorted((SRC / 'pages').glob('*.page'))
    if not pages:
        sys.exit('no pages in site-src/pages')

    parsed = []
    for f in pages:
        meta, body = split_front_matter(f.read_text(encoding='utf-8'), f.name)
        parsed.append((f.name, meta, body))

    # The nav, built once from whichever pages ask to be in it, so it cannot
    # differ between pages and cannot link to a page that does not exist.
    in_nav = sorted(
        [(m, b) for _, m, b in parsed if m.get('nav')],
        key=lambda pair: int(pair[0].get('nav_order', '99')),
    )
    nav_links = ''.join(
        f'\n        <li><a href="{m["path"]}">{m["nav"]}</a></li>' for m, _ in in_nav
    )
    menu_links = ''.join(f'\n        <a href="{m["path"]}">{m["nav"]}</a>' for m, _ in in_nav)

    today = date.today().isoformat()
    written = []
    titles: dict[str, str] = {}
    descriptions: dict[str, str] = {}

    for name, meta, body in parsed:
        path = meta['path']
        # Prices may appear in the title and description as well as the body,
        # and the pricing page's description quotes them.
        title = fill_plans(meta['title'], name)
        desc = fill_plans(meta['description'], name)
        body = fill_plans(body, name)

        # Duplicate titles and descriptions are the commonest defect a template
        # introduces, and the one Search Console complains about first.
        if title in titles:
            sys.exit(f'{name}: title duplicates {titles[title]}: {title!r}')
        titles[title] = name
        if desc in descriptions:
            sys.exit(f'{name}: description duplicates {descriptions[desc]}')
        descriptions[desc] = name

        canonical = f'{SITE}/' if path == '/' else f'{SITE}{path}'

        blocks: list[dict] = []
        wanted = meta.get('schema', '')
        if 'org' in wanted:
            blocks.append(ORGANISATION)
        if 'software' in wanted:
            soft = dict(SOFTWARE)
            agg = review_schema(reviews)
            if agg:
                # By @id, so the rating is a separate node referring to the
                # software rather than a copy of it inside every page.
                soft['aggregateRating'] = {'@id': f'{SITE}/reviews#rating'}
            blocks.append(soft)
        if 'reviews' in wanted:
            blocks.extend(review_schema(reviews))
        if meta.get('breadcrumb'):
            blocks.append(breadcrumb_schema(meta['breadcrumb'], path))
        extra = (SRC / 'schema' / f'{Path(name).stem}.json')
        if extra.exists():
            blocks.append(json.loads(extra.read_text(encoding='utf-8')))

        crumb = ''
        if meta.get('breadcrumb'):
            crumb = (
                '<nav class="wrap crumb" aria-label="Breadcrumb">\n'
                '  <a href="/">Home</a>\n'
                f'  <span aria-hidden="true">/</span>\n'
                f'  <span aria-current="page">{meta["breadcrumb"]}</span>\n'
                '</nav>'
            )

        body = body.replace(
            '{{REVIEWS}}',
            '    <div id="reviews-live">\n' + render_reviews(reviews) + '\n    </div>',
        )

        html = (layout
                .replace('{{TITLE}}', title)
                .replace('{{DESCRIPTION}}', desc)
                .replace('{{CANONICAL}}', canonical)
                .replace('{{OG_TYPE}}', meta.get('og_type', 'website'))
                .replace('{{SITE}}', SITE)
                .replace('{{SCHEMA}}', jsonld(*blocks) if blocks else '')
                .replace('{{NAV_LINKS}}', nav_links)
                .replace('{{MENU_LINKS}}', menu_links)
                .replace('{{BREADCRUMB}}', crumb)
                .replace('{{BODY}}', body.rstrip() + '\n'))

        left = re.findall(r'\{\{(\w+)\}\}', html)
        if left:
            sys.exit(f'{name}: unreplaced placeholders {sorted(set(left))}')

        target = out_path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(html, encoding='utf-8')
        written.append((path, meta, target))

    # The sitemap, generated so it cannot list a page that does not exist or
    # miss one that does. Both were true of the hand-written version, which
    # named exactly one URL.
    urls = []
    for path, meta, _ in sorted(written, key=lambda w: w[0]):
        # sitemap: no  keeps a page out of it. The only current member is /404,
        # which exists to be served on a wrong URL and must never be offered to
        # a crawler as a destination.
        if meta.get('sitemap', 'yes').lower() == 'no':
            continue
        loc = f'{SITE}/' if path == '/' else f'{SITE}{path}'
        urls.append(
            '  <url>\n'
            f'    <loc>{loc}</loc>\n'
            f'    <lastmod>{meta.get("lastmod", today)}</lastmod>\n'
            f'    <changefreq>{meta.get("changefreq", "monthly")}</changefreq>\n'
            f'    <priority>{meta.get("priority", "0.6")}</priority>\n'
            '  </url>'
        )
    # The handbook is a real page of content that people search for, so it
    # belongs in the sitemap even though it is built by build-guide.py.
    if (OUT / 'guide.html').exists():
        urls.append(
            '  <url>\n'
            f'    <loc>{SITE}/guide.html</loc>\n'
            f'    <lastmod>{today}</lastmod>\n'
            '    <changefreq>monthly</changefreq>\n'
            '    <priority>0.5</priority>\n'
            '  </url>'
        )
    (OUT / 'sitemap.xml').write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!-- GENERATED by scripts/build-site.py. Do not edit. -->\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + '\n'.join(urls)
        + '\n</urlset>\n',
        encoding='utf-8',
    )

    print(f'built {len(written)} page(s) and a sitemap of {len(urls)} URL(s)')
    for path, _, target in sorted(written, key=lambda w: w[0]):
        print(f'  {path:26} -> site/{target.relative_to(OUT)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
