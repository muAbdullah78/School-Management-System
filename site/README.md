# Marketing site

Fifteen pages of plain HTML plus one stylesheet. No framework, no bundler, no
runtime routing. Everything in this folder is uploaded as-is and served as-is.

It reads three things from Supabase, all optional: the live price list
(`plans`), the current installer (`app_releases`) and, on /reviews, the
published reviews. If a read fails the page keeps what the build wrote into the
HTML, which for prices `supabase/check-site-prices.sh` keeps in step with the
`plans` table.

## Prices

Three plans, from `public.plans` (migration 0155): Starter for 1 to 280 pupils
at Rs 2,000 a month, Rs 5,400 for three months (10% off) or Rs 20,000 a year
(two months free); Growth for 281 to 1,000 pupils at Rs 4,000, Rs 10,800 or
Rs 40,000; and Enterprise for more than 1,000 pupils, with no pupil limit and a
monthly price agreed with each school. Enterprise has no figure anywhere on the
site: its card says "Priced with you".

The site's one hand copy of that list is `PLANS` in `scripts/build-site.py`.
The build writes it into the pricing cards, every "from" price, the two meta
descriptions that quote a price, and the JSON-LD offers, through placeholders
such as `{{PLAN_starter_monthly}}` and `{{FROM_PRICE}}` in `site-src/`. Never
type a price into a page; use a placeholder.

When a price changes (only ever by migration):

1. change `PLANS` and run `python3 scripts/build-site.py`;
2. if the cheapest monthly price moved, change `FROM` in
   `scripts/build-og.mjs` and run `node scripts/build-og.mjs`, then bump the
   `?v=` on `og:image` in `site-src/layout.html` so WhatsApp fetches the new
   card instead of its cached one;
3. run `bash supabase/check-site-prices.sh` against a database with the
   migration applied. It compares the cards, `PLANS`, the JSON-LD, every
   "from" line, the meta descriptions and the text inside `og.png` with
   `plans` in both directions, so a retired plan left on the site fails as
   surely as a missing one.

At page load `wire.js` writes the live names, bands of pupils, the three term
prices and the two savings onto the Starter and Growth cards, and the cheapest
monthly price into the home page hero. It leaves Enterprise's words alone.

## It is GENERATED. Do not edit site/*.html

The pages are built from `site-src/`:

```
site-src/layout.html        the shell: head, nav, footer, action bar
site-src/pages/*.page       one file per page, front matter then a body
site-src/schema/*.json      extra JSON-LD for a specific page

python3 scripts/build-site.py     rebuild every page and the sitemap
python3 scripts/check-site-seo.py verify the result
```

`check-site-seo.py` rebuilds into a temporary directory and compares, so an
edit made to a built file fails CI instead of being silently thrown away by the
next build. The sources deliberately live OUTSIDE this folder: everything in
`site/` becomes a public URL, and a template full of `{{TITLE}}` placeholders
should not be one.

The Open Graph share card is generated too, by `node scripts/build-og.mjs`, the
icons by `node scripts/build-icons.mjs`, and the handbook by
`python3 scripts/build-guide.py`. All three need a browser or screenshots, so
none of them runs in CI; the committed output is what ships.

Two more checks need a browser and are therefore run by hand, not by CI:

```
python3 scripts/cf-server.py site 8803 &
node scripts/check-site-render.mjs    16 pages x 7 widths: overflow, clipping,
                                      contrast, stray text, console errors
node scripts/check-site-csp.mjs 8803  the pages under the REAL response
                                      headers: CSP violations, every icon URL
                                      answering 200, the logo actually loading
```

Use `cf-server.py` and not the app's `spa-server.py`. The SPA server answers
every unknown path with `index.html`, so an audit of sixteen URLs once audited
the home page sixteen times and reported all of them clean.

## Why fifteen pages and not one

A page ranks for one intent. A school owner searching "fee challan software"
and one searching "school attendance register" are asking different questions,
and one page answering both answers neither as well as two pages would. Each
page owns one query and says so in its front matter.

There are deliberately NO city pages ("school software in Lahore", "in
Karachi"). A set of pages identical apart from a swapped city name is the
doorway-page pattern Google's own guidelines name and demote. Cities belong
inside the real pages, in real sentences.

## The one thing you edit: config.js

`config.js` holds the deployment's values and is committed with them. Every
value in it is public by design; `supabase/check-site-links.sh` refuses any
Supabase key in `site/` other than the anon key, judged by decoding the token:

| Key | What goes in it |
| --- | --- |
| `APP_URL` | The deployed app, no trailing slash, e.g. `https://app.theschoolmanager.site` |
| `SUPABASE_URL` | The same value as the app's `VITE_SUPABASE_URL` |
| `SUPABASE_ANON_KEY` | The same value as the app's `VITE_SUPABASE_ANON_KEY` |
| `CONTACT_PHONE` | Shown in the footer and on the contact page |
| `CONTACT_WHATSAPP` | Number in international form, e.g. `923001234567` |
| `CONTACT_EMAIL` | Shown in the footer and on the contact page |
| `SIGNUP_OPEN` | `false` takes the trial buttons down and invites a call instead |

The ANON key belongs in a browser. The SERVICE ROLE key never does: not here,
not in `wrangler.jsonc`, not in a build variable. Row Level Security is what
protects the data, and the site reads only the active price list, the current
release and the published reviews.

With `APP_URL` empty, a banner at the top of every page says the site is not yet
pointed at the software, and with the contact keys empty the contact page says
so out loud. Neither can ship silently.

## Deploying

Any static host. Cloudflare Pages is free and fast from Pakistan: point it at
this folder, no build command, output directory `site`.

**Upload the whole folder.** It is a folder rather than a handful of files:

- sixteen pages, and `guides/` with three articles inside it
- `styles.css`, `wire.js`, `config.js`
- `og.png`, `guide.html`, `404.html`, `robots.txt`, `sitemap.xml`
- the icons: `favicon.ico`, `icon.svg`, `icon-48.png`, `icon-96.png`,
  `icon-192.png`, `icon-512.png`, `icon-maskable-512.png`,
  `apple-touch-icon.png`, and `site.webmanifest`
- `_headers`, which is how Cloudflare learns the security headers. It is a
  plain text file with no extension and it is easy to miss when dragging a
  folder. Without it the site still works and simply has no Content Security
  Policy, which is the kind of thing nobody notices for a year.

This README does no harm if it goes up too.

**The icons must keep their names.** Google caches a favicon against its URL, so
renaming one means waiting for a recrawl before the icon in the search result
changes. `docs/SEO.md` has the full story of why the icon was a grey globe.

**Upload it as a set.** A new page with an old `styles.css` uses class names the
old sheet has never heard of, so it falls back to unstyled defaults in places
and looks like a different, worse design rather than like an error. If the live
site looks wrong after a deploy, compare the file timestamps in the Cloudflare
dashboard before changing anything.

### Why the URLs have no .html

Cloudflare serves `/fee-management` for an uploaded `fee-management.html` and
301s `/fee-management.html` to the extensionless path. So the extensionless URL
is the one that answers 200 with no redirect, and it is what every canonical
and every internal link uses. If you ever move to a host that does not do this,
the canonicals all become redirects and want revisiting.

`404.html` is served for an unknown path, which is why there is a real 404 page
with links on it rather than the host's default.

## What it looks like, and why

A clean, light product page: white with one slate tint band, the app's own
indigo as the primary, cyan as the accent, cards with real borders and shadows,
and a single dark surface at the very end where a dark band reads as a full
stop.

An earlier version was drawn as PAPER: a cream ground, a serif face, and nine
facsimile documents stacked down the page as proof. It was rejected, and the
reason is worth keeping written down because the instinct that produced it will
come back. A school owner buying this software is trying to get away from the
pile of paper. Showing them the pile is not proof, it is a reminder of the
problem, and it made a page about software look like a page about stationery.

So the software is shown as software: one abstract dashboard in the hero and UI
panels further down, drawn in HTML and CSS with no image files at all. Nothing
on the site is a picture of a document. Keep it that way.

## On the claims

Every feature named on these pages is one the software actually does today.
Nothing here describes something planned. If a feature is removed, remove it
here too. A marketing page that overstates the product is the fastest way to
lose the first ten schools, and they are the ten that matter most.

Several things are stated as NOT done, deliberately, each on the page where
somebody would look for it: the Urdu interface, online fee payment by parents,
credit-weighted GPA, parents opening their own accounts, and the fact that this
is not a general ledger. Saying so costs a few visitors and saves every one of
them from finding out on a Monday morning.
