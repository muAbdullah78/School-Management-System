#!/usr/bin/env bash
# =============================================================================
# The website's prices must match what the console actually charges, in BOTH
# directions.
#
# WHY THIS EXISTS
#
# The site prints the price list as literal text, and `plans` holds it as data.
# site/wire.js rewrites the cards from `plans` at page load, but the literals
# are what a visitor reads when Supabase is slow or unreachable, what a crawler
# indexes, what the JSON-LD offers say and what the WhatsApp share card shows.
# A stale literal is a price you will be held to.
#
# The literals come from ONE hand copy, PLANS in scripts/build-site.py, which
# the build writes into the cards, the "from" lines, the two meta descriptions
# that quote a price and the JSON-LD. This compares that copy and everything
# built from it against public.plans.
#
# WHAT THE OLD VERSION MISSED, each of which is now a check below:
#
#   - It looped over the database's plans only. A card or JSON-LD offer for a
#     plan the database had retired was never looked at, so the site could go
#     on selling Institution at Rs 5,500 and this printed success. Every card,
#     offer and PLANS entry is now matched to an ACTIVE plan, and the other way
#     round.
#   - It skipped the three month figure when the database's was zero, so a
#     quarterly price nobody sold could stay on the cards.
#   - It required at least three priced plans and named an unset $HTML in the
#     refusal, so with the two priced plans of migration 0155 it crashed under
#     `set -u` even when the site was right.
#   - Its JSON-LD check read five fields into four variables, so the yearly
#     comparison compared nothing.
#   - A "from" price only had to equal SOME plan's price, so "From Rs 4,000" on
#     a page would have passed. It must now be the cheapest.
#   - It read build-og.mjs but not og.png, and the PNG said Rs 950 for weeks
#     after the source said Rs 2,000. The PNG now carries its own words in a
#     text chunk and that is what is read.
#   - web/src/auth/doors.ts quoted the price and was not in its list.
#
# ENTERPRISE (by_arrangement) has no list price: its row holds zeros and no
# pupil limit. Its card must exist, say "Priced with you", and show no rupee
# figure at all; its JSON-LD offer must carry no price.
#
# Usage:  bash supabase/check-site-prices.sh
#         (needs PG* env vars pointing at a database with the migrations
#         applied, python3, and the built site in site/)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

for f in site/pricing.html site/index.html scripts/build-site.py scripts/build-og.mjs site/og.png; do
  if [ ! -f "$f" ]; then
    echo "REFUSING TO REPORT SUCCESS: $f does not exist. Run python3 scripts/build-site.py" >&2
    exit 1
  fi
done
if ! command -v python3 >/dev/null 2>&1; then
  echo "REFUSING TO REPORT SUCCESS: python3 is needed to read the pages and the JSON-LD" >&2
  exit 1
fi

# Every plan, active or not: the retired ones are needed to prove they are gone.
plans=$(psql -tA -v ON_ERROR_STOP=1 -c "
  select coalesce(json_agg(json_build_object(
           'code', code, 'name', name, 'active', active,
           'by_arrangement', by_arrangement,
           'min', min_students, 'limit', student_limit,
           'monthly', price_monthly::bigint,
           'quarterly', price_quarterly::bigint,
           'yearly', price_yearly::bigint)
         order by sort_order, code), '[]')
    from public.plans") || {
  echo "could not read plans: are the PG* env vars set, and is 0155 applied?" >&2
  exit 1
}

PLANS_JSON="$plans" python3 - <<'PY'
import importlib.util
import json
import os
import re
import sys

# Loading scripts/build-site.py below would otherwise leave a __pycache__ in
# scripts/ on every run.
sys.dont_write_bytecode = True
from html.parser import HTMLParser
from pathlib import Path

fails: list[str] = []


def fail(msg: str) -> None:
    fails.append(msg)


def refuse(msg: str) -> None:
    # Whatever was already found is printed too, so a refusal never hides it.
    for f in fails:
        print('  ' + f)
    print(f'REFUSING TO REPORT SUCCESS: {msg}', file=sys.stderr)
    sys.exit(1)


def rupees(n: int) -> str:
    return f'Rs {n:,}'


def figure(s: str) -> int:
    return int(s.replace(',', ''))


rows = json.loads(os.environ['PLANS_JSON'])
active = [r for r in rows if r['active']]
priced = [r for r in active if not r['by_arrangement']]
arranged = [r for r in active if r['by_arrangement']]
retired = [r for r in rows if not r['active']]
active_codes = {r['code'] for r in active}
by_code = {r['code']: r for r in rows}

if not priced:
    refuse('the database has no active priced plan, so there is nothing to compare')
for r in priced:
    if not (r['monthly'] > 0 and r['quarterly'] > 0 and r['yearly'] > 0):
        fail(f'{r["code"]}: active and not by arrangement, but a term price is zero '
             f'({r["monthly"]}/{r["quarterly"]}/{r["yearly"]}); the site cannot show a price '
             'the console would refuse to charge')
    if r['limit'] is None:
        fail(f'{r["code"]}: a priced plan with no pupil limit; the cards print a band of pupils')
    # The pricing page and the JSON-LD say these in words. If the database
    # stops making them true, the words are a promise nobody keeps.
    if r['quarterly'] * 10 != r['monthly'] * 27:
        fail(f'{r["code"]}: three months is {rupees(r["quarterly"])}, not 10% off '
             f'3 x {rupees(r["monthly"])}, and the pricing page says 10% off')
    if r['yearly'] != r['monthly'] * 10:
        fail(f'{r["code"]}: a year is {rupees(r["yearly"])}, not two months free on '
             f'{rupees(r["monthly"])} a month, and the pricing page says two months free')
if fails:
    for f in fails:
        print('  ' + f)
    sys.exit(1)

cheapest = min(r['monthly'] for r in priced)
CHEAP = rupees(cheapest)
monthlies = {r['monthly'] for r in priced}
quarterlies = {r['quarterly'] for r in priced}
yearlies = {r['yearly'] for r in priced}


def band(r: dict) -> str:
    if r['limit'] is None:
        return f'More than {r["min"] - 1:,} pupils'
    return f'{r["min"]:,} to {r["limit"]:,} pupils'


# --- 1. PLANS, the hand copy in scripts/build-site.py -----------------------
spec = importlib.util.spec_from_file_location('build_site', 'scripts/build-site.py')
build = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(build)
except SystemExit as e:
    refuse(f'scripts/build-site.py refused its own PLANS: {e}')
hand = {p['code']: p for p in build.PLANS}
for code in sorted(set(hand) - active_codes):
    state = 'retired' if code in by_code else 'not in the database'
    fail(f'PLANS in scripts/build-site.py lists {code}, which is {state}')
for r in active:
    p = hand.get(r['code'])
    if p is None:
        fail(f'PLANS in scripts/build-site.py has no entry for the active plan {r["code"]}')
        continue
    want = {'name': r['name'], 'min': r['min'], 'limit': r['limit'],
            'by_arrangement': bool(r['by_arrangement'])}
    got = {'name': p['name'], 'min': p['min'], 'limit': p['limit'],
           'by_arrangement': bool(p.get('by_arrangement'))}
    if not r['by_arrangement']:
        for k in ('monthly', 'quarterly', 'yearly'):
            want[k] = r[k]
            got[k] = p.get(k)
    for k in want:
        if want[k] != got[k]:
            fail(f'PLANS {r["code"]}.{k} is {got[k]!r}; the database says {want[k]!r}')


# --- the pages ---------------------------------------------------------------
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
        'source', 'track', 'wbr', 'path', 'circle', 'rect', 'line', 'polyline',
        'polygon', 'stop', 'use'}
# Text in two different cells must never read as one phrase: "you save Rs 600"
# followed by the next row's "A year" is not a yearly price of Rs 600.
BLOCK = {'p', 'div', 'li', 'ul', 'ol', 'td', 'th', 'tr', 'table', 'caption', 'h1',
         'h2', 'h3', 'h4', 'section', 'header', 'footer', 'nav', 'br', 'dd', 'dt'}
FIELDS = ('data-plan-name', 'data-price-monthly', 'data-price-quarterly',
          'data-price-yearly', 'data-save-quarterly', 'data-save-yearly',
          'data-price-cap')


class Page(HTMLParser):
    """Visible text, every plan card's fields, and whether the tags balance.

    The card is the element carrying data-plan and everything nested in it,
    found by nesting rather than by a marker comment. That only holds if the
    markup is balanced, so an unbalanced page is refused rather than read.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[tuple[str, int, dict]] = []
        self.text: list[str] = []
        self.cards: list[dict] = []
        self.open_cards: list[dict] = []
        self.capture: list[tuple[dict, str, int]] = []
        self.skip = 0
        self.unbalanced: list[str] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ('script', 'style'):
            self.skip += 1
        if tag in BLOCK:
            self.split()
        if tag in VOID:
            return
        depth = len(self.stack)
        self.stack.append((tag, self.getpos()[0], a))
        if 'data-plan' in a:
            card = {'code': a['data-plan'], 'text': [], 'fields': {}, 'depth': depth}
            self.cards.append(card)
            self.open_cards.append(card)
        for f in FIELDS:
            if f in a and self.open_cards:
                card = self.open_cards[-1]
                card['fields'].setdefault(f, [])
                self.capture.append((card, f, depth))

    def split(self) -> None:
        self.text.append(' | ')
        for card in self.open_cards:
            card['text'].append(' | ')

    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.skip = max(0, self.skip - 1)
        if tag in BLOCK:
            self.split()
        if tag in VOID:
            return
        if not self.stack or self.stack[-1][0] != tag:
            open_tag = f'<{self.stack[-1][0]}> from line {self.stack[-1][1]}' if self.stack else 'nothing'
            self.unbalanced.append(f'line {self.getpos()[0]}: </{tag}> closes {open_tag}')
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i][0] == tag:
                    del self.stack[i:]
                    break
        else:
            self.stack.pop()
        depth = len(self.stack)
        self.capture = [c for c in self.capture if c[2] < depth]
        self.open_cards = [c for c in self.open_cards if c['depth'] < depth]

    def handle_data(self, data):
        if self.skip:
            return
        self.text.append(data)
        for card in self.open_cards:
            card['text'].append(data)
        for card, f, _ in self.capture:
            card['fields'][f].append(data)


def squash(parts) -> str:
    return re.sub(r'\s+', ' ', ''.join(parts)).strip()


def read(path: Path) -> tuple[str, Page]:
    html = path.read_text(encoding='utf-8')
    p = Page()
    p.feed(html)
    p.close()
    return html, p


PAGES = sorted([*Path('site').glob('*.html'), *Path('site/guides').glob('*.html')])
PAGES = [p for p in PAGES if p.name != 'guide.html' or p.parent.name != 'site']
if len(PAGES) < 10:
    refuse(f'found only {len(PAGES)} built pages in site/; run python3 scripts/build-site.py')

# --- 2. the cards on /pricing ------------------------------------------------
CARDS = Path('site/pricing.html')
html, page = read(CARDS)
if page.unbalanced:
    refuse(f'{CARDS} has unbalanced markup, so a card cannot be told from its '
           f'neighbour: {page.unbalanced[0]}')
if not page.cards:
    refuse(f'{CARDS} has no element with data-plan, so no card was checked')

seen: dict[str, int] = {}
for card in page.cards:
    code = card['code']
    seen[code] = seen.get(code, 0) + 1
    if code not in active_codes:
        state = 'retired in the database' if code in by_code else 'not in the database'
        fail(f'{CARDS}: a card for "{code}", which is {state}')
for code, n in seen.items():
    if n > 1:
        fail(f'{CARDS}: {n} cards for "{code}"')

checked_cards = 0
for r in active:
    cards = [c for c in page.cards if c['code'] == r['code']]
    if not cards:
        fail(f'{CARDS}: no card for the active plan {r["code"]} (data-plan="{r["code"]}")')
        continue
    card = cards[0]
    checked_cards += 1
    text = squash(card['text'])
    fields = {k: squash(v) for k, v in card['fields'].items()}
    name = r['code']

    def expect(field: str, want: str) -> None:
        got = fields.get(field)
        if got is None:
            fail(f'{CARDS} {name}: the card has no [{field}]')
        elif got != want:
            fail(f'{CARDS} {name}: [{field}] says "{got}"; the database says "{want}"')

    expect('data-plan-name', r['name'])
    expect('data-price-cap', band(r))
    figures = {figure(x) for x in re.findall(r'Rs\.?\s?(\d[\d,]*)', text)}

    if r['by_arrangement']:
        for f in FIELDS[1:6]:
            if f in fields:
                fail(f'{CARDS} {name}: priced by arrangement, but the card has a [{f}] slot '
                     'that wire.js or a later edit could fill with a figure')
        if figures:
            fail(f'{CARDS} {name}: priced by arrangement, but the card shows '
                 + ', '.join(rupees(n) for n in sorted(figures)))
        if 'Priced with you' not in text:
            fail(f'{CARDS} {name}: priced by arrangement, but the card does not say "Priced with you"')
        if r['limit'] is None and 'no pupil limit' not in text.lower():
            fail(f'{CARDS} {name}: the plan has no pupil limit and the card does not say so')
        continue

    m, q, y = r['monthly'], r['quarterly'], r['yearly']
    expect('data-price-monthly', rupees(m))
    expect('data-price-quarterly', rupees(q))
    expect('data-price-yearly', rupees(y))
    expect('data-save-quarterly', rupees(3 * m - q))
    expect('data-save-yearly', rupees(12 * m - y))
    stray = figures - {m, q, y, 3 * m - q, 12 * m - y}
    if stray:
        fail(f'{CARDS} {name}: the card also shows '
             + ', '.join(rupees(n) for n in sorted(stray))
             + ', which is none of its prices or savings')

# The floor. Every active plan without a card is already a failure above; this
# catches the case where the extraction itself matched nothing, which would
# otherwise be a clean run over an empty check.
if checked_cards == 0:
    refuse(f'matched no card in {CARDS} for {len(active)} active plan(s)')

# --- 3. price phrases on every page, the hero, and the two meta descriptions -
PHRASES = [
    (re.compile(r'\bfrom\s+Rs\.?\s?(\d[\d,]*)', re.I), {cheapest},
     f'a "from" price, and the only true one is the cheapest monthly price, {CHEAP}'),
    (re.compile(r'Rs\.?\s?(\d[\d,]*)\s*(?:a month|/\s*month|per month|monthly)', re.I), monthlies,
     'a monthly price that no active plan charges'),
    (re.compile(r'Rs\.?\s?(\d[\d,]*)\s*(?:for (?:3|three) months|a quarter|per quarter)', re.I), quarterlies,
     'a three month price that no active plan charges'),
    (re.compile(r'Rs\.?\s?(\d[\d,]*)\s*(?:a year|/\s*year|per year|yearly|annually)', re.I), yearlies,
     'a yearly price that no active plan charges'),
]
BOUNDS = {r['limit'] for r in priced} | {r['min'] - 1 for r in arranged}
phrases = 0
for path in PAGES:
    html, page = read(path)
    text = squash(page.text)
    for rx, allowed, what in PHRASES:
        for m_ in rx.finditer(text):
            phrases += 1
            if figure(m_.group(1)) not in allowed:
                fail(f'{path}: "{m_.group(0)}" is {what}')

for path in (Path('site/index.html'), CARDS):
    html = path.read_text(encoding='utf-8')
    metas = {}
    for label in ('name="description"', 'property="og:description"'):
        m_ = re.search(r'<meta ' + re.escape(label) + r' content="([^"]*)"', html)
        if not m_:
            fail(f'{path} has no <meta {label}>, which this check expects')
            continue
        metas[label] = m_.group(1)
        content = m_.group(1)
        found = [figure(x) for x in re.findall(r'Rs\.?\s?(\d[\d,]*)', content)]
        if cheapest not in found:
            fail(f'<meta {label}> in {path} does not quote the cheapest price, {CHEAP}')
        for n in found:
            if n != cheapest:
                fail(f'<meta {label}> in {path} quotes {rupees(n)}; the only price it may '
                     f'quote is the cheapest, {CHEAP}')
        for x in re.findall(r'(?:up to|more than|over)\s+(\d[\d,]*)', content, re.I):
            if figure(x) not in BOUNDS:
                fail(f'<meta {label}> in {path} names {x} pupils, which is no plan\'s limit')
    if len(metas) == 2 and len(set(metas.values())) != 1:
        fail(f'{path}: the meta description and og:description say different things')

hero = re.search(r'id="lead-price"[^>]*>([^<]*)<', Path('site/index.html').read_text(encoding='utf-8'))
if not hero:
    fail('site/index.html has no id="lead-price", the hero\'s "from" figure')
elif hero.group(1).strip() != CHEAP:
    fail(f'site/index.html: the hero\'s "from" figure is "{hero.group(1).strip()}", not {CHEAP}')

# --- 4. the JSON-LD offers, which a crawler takes verbatim -------------------
DURATION = {'P1M': 'monthly', 'P3M': 'quarterly', 'P1Y': 'yearly'}
ld_pages = 0
for path in PAGES:
    html = path.read_text(encoding='utf-8')
    for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S):
        try:
            doc = json.loads(block)
        except json.JSONDecodeError as e:
            fail(f'{path}: a JSON-LD block does not parse ({e})')
            continue
        for node in doc.get('@graph', [doc]):
            if node.get('@type') != 'SoftwareApplication':
                continue
            ld_pages += 1
            offers = node.get('offers') or []
            names = [o.get('name') for o in offers]
            for n in sorted({x for x in names if names.count(x) > 1}):
                fail(f'{path}: JSON-LD has {names.count(n)} offers named {n}')
            active_names = {r['name']: r for r in active}
            for o in offers:
                r = active_names.get(o.get('name'))
                if r is None:
                    fail(f'{path}: JSON-LD offers "{o.get("name")}", which is not an active plan')
                    continue
                if r['by_arrangement']:
                    specs = o.get('priceSpecification') or []
                    if 'price' in o or any('price' in s for s in (specs if isinstance(specs, list) else [specs])):
                        fail(f'{path}: JSON-LD gives {r["name"]} a price, and it is priced by arrangement')
                    if f'more than {r["min"] - 1:,} pupils' not in (o.get('description') or '').lower():
                        fail(f'{path}: JSON-LD {r["name"]} does not say "more than {r["min"] - 1:,} pupils"')
                    continue
                if o.get('price') != str(r['monthly']) or o.get('priceCurrency') != 'PKR':
                    fail(f'{path}: JSON-LD {r["name"]} is priced {o.get("price")!r} '
                         f'{o.get("priceCurrency")!r}; the database says "{r["monthly"]}" PKR a month')
                if band(r) not in (o.get('description') or ''):
                    fail(f'{path}: JSON-LD {r["name"]} does not say "{band(r)}"')
                specs = o.get('priceSpecification')
                if not isinstance(specs, list):
                    fail(f'{path}: JSON-LD {r["name"]} has no list of UnitPriceSpecification')
                    continue
                durations = [s.get('billingDuration') for s in specs]
                if sorted(durations) != sorted(DURATION):
                    fail(f'{path}: JSON-LD {r["name"]} has terms {durations}; expected P1M, P3M and P1Y once each')
                for s in specs:
                    term = DURATION.get(s.get('billingDuration'))
                    if not term:
                        continue
                    if s.get('@type') != 'UnitPriceSpecification' or s.get('priceCurrency') != 'PKR':
                        fail(f'{path}: JSON-LD {r["name"]} {s.get("billingDuration")} is not a PKR UnitPriceSpecification')
                    if s.get('price') != str(r[term]):
                        fail(f'{path}: JSON-LD {r["name"]} {s.get("billingDuration")} is {s.get("price")!r}; '
                             f'the database says "{r[term]}"')
                    if term == 'monthly' and s.get('unitText') != 'MONTH':
                        fail(f'{path}: JSON-LD {r["name"]} P1M has unitText {s.get("unitText")!r}, not MONTH')
            for r in active:
                if r['name'] not in names:
                    fail(f'{path}: JSON-LD has no offer for the active plan {r["name"]}')
if ld_pages == 0:
    refuse('no page carries the SoftwareApplication schema, so the offers Google '
           'reads are not being checked at all')

# --- 5. the share card ---------------------------------------------------------
og_src = Path('scripts/build-og.mjs').read_text(encoding='utf-8')
if f"const FROM = '{CHEAP} a month'" not in og_src:
    fail(f'scripts/build-og.mjs: FROM is not \'{CHEAP} a month\'')
og = Path('site/og.png').read_bytes()
said = re.search(rb'From (Rs [0-9,]+ a month)\.', og)
if not said:
    fail('site/og.png carries no price sentence, so what it shows cannot be checked. '
         'Run node scripts/build-og.mjs')
elif said.group(1).decode('latin1') != f'{CHEAP} a month':
    fail(f'site/og.png says "From {said.group(1).decode("latin1")}", not {CHEAP} a month. '
         'Run node scripts/build-og.mjs')

# --- 6. the app's own doors ----------------------------------------------------
# The app must read its prices from the database (fn_signup_plans and the
# subscription view), so a plan figure typed into these files is a defect even
# when it happens to be right today. Any rupee figure that equals a plan price
# (current or retired) fails, and so does any rupee figure on a line that talks
# about months, years, plans or prices. The demo dashboard's "Rs 84,500
# collected" is neither, and passes.
APP = ['web/src/auth/doors.ts', 'web/src/components/AuthLayout.tsx', 'web/src/pages/Signup.tsx']
plan_figures = {r[k] for r in rows for k in ('monthly', 'quarterly', 'yearly') if r[k] > 0}
price_words = re.compile(r'month|year|quarter|from|plan|price|trial|/mo\b', re.I)
app_checked = 0
app_fails: list[str] = []
for name in APP:
    path = Path(name)
    if not path.exists():
        continue
    app_checked += 1
    # Comments may quote history or an example ("Save Rs 4,000" is a number a
    # school can weigh); only code reaches a screen. Block comments, JSX
    # comments included, are blanked with their newlines kept so the line
    # numbers still point at the file, and a // comment is dropped when it
    # starts a line or follows a space (so the // in https:// is not one).
    source = re.sub(r'/\*.*?\*/', lambda c: '\n' * c.group(0).count('\n'),
                    path.read_text(encoding='utf-8'), flags=re.S)
    for i, line in enumerate(source.splitlines(), 1):
        line = re.sub(r'(^|\s)//.*$', '', line)
        for x in re.findall(r'(?:Rs\.?|PKR)\s?(\d[\d,]*)', line):
            n = figure(x)
            if n in plan_figures or price_words.search(line):
                app_fails.append(f'{name}:{i} hard-codes {rupees(n)}: "{line.strip()[:110]}"')

if fails:
    for f in fails:
        print('  ' + f)
    print()
    print('::error::the site quotes prices or plans the console does not charge')
    print('Change scripts/build-site.py PLANS to match public.plans, rebuild with')
    print('python3 scripts/build-site.py, and regenerate the share card with')
    print('node scripts/build-og.mjs if the cheapest price moved.')
if app_fails:
    for f in app_fails:
        print('  ' + f)
    print()
    print('::error::an app screen types a plan price instead of reading it')
    print('Show the figure from fn_signup_plans() or the subscription view, or drop it.')
if fails or app_fails:
    sys.exit(1)

print(f'the site and public.plans agree: {len(priced)} priced plan(s) and {len(arranged)} '
      f'by arrangement, each with a card and no card for the {len(retired)} retired; '
      f'PLANS in build-site.py; the JSON-LD offers on {ld_pages} page(s); {phrases} price '
      f'phrase(s) across {len(PAGES)} pages, the hero and both meta descriptions at {CHEAP}; '
      f'og.png; and no plan figure typed into {app_checked} app file(s)')
PY
