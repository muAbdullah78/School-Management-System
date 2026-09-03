# Marketing site

Plain HTML and CSS. No build step, no framework, no bundler. The whole page is
`index.html` plus `styles.css`, with `config.js` and `wire.js` beside them, so
it renders fast on a slow connection and there is nothing to break at deploy
time.

It makes exactly two network requests of its own, both to Supabase and both
optional: the live price list, and the current installer. If either fails the
page falls back to the figures written into the HTML, which
`supabase/check-site-prices.sh` keeps in step with the `plans` table.

## The one thing you edit: config.js

`config.js` is committed BLANK on purpose, and `supabase/check-site-links.sh`
fails the build if a real value is committed into it. Fill it in on the
DEPLOYMENT, not in the repository:

| Key | What goes in it |
| --- | --- |
| `APP_URL` | The deployed app, no trailing slash, e.g. `https://app.theschoolmanager.site` |
| `SUPABASE_URL` | The same value as the app's `VITE_SUPABASE_URL` |
| `SUPABASE_ANON_KEY` | The same value as the app's `VITE_SUPABASE_ANON_KEY` |
| `CONTACT_PHONE` | Shown in the footer and on the contact card |
| `CONTACT_WHATSAPP` | Number in international form, e.g. `923001234567` |
| `CONTACT_EMAIL` | Shown in the footer and on the contact card |
| `SIGNUP_OPEN` | `false` takes the trial buttons down and invites a call instead |

The ANON key belongs in a browser. The SERVICE ROLE key never does: not here,
not in `wrangler.jsonc`, not in a build variable. Row Level Security is what
protects the data, and `anon` can read exactly two things, the active price
list and the current release.

Nothing is left to guess at: with `APP_URL` empty, a banner at the top of the
page says the site is not yet pointed at the software, and with the contact
keys empty the contact card says so out loud. Neither can ship silently.

## Deploying

Any static host. Cloudflare Pages is free and fast from Pakistan: point it at
this folder, no build command, output directory `site`.

Six files go up: `index.html`, `styles.css`, `config.js`, `wire.js`,
`robots.txt`, `sitemap.xml`. This README does not need to, and uploading it
does no harm.

UPLOAD THEM AS A SET. A new `index.html` with an old `styles.css` renders as a
broken page, because the two are written against each other: the HTML uses
class names the old sheet has never heard of, so the page falls back to
unstyled defaults in places and looks like a different, worse design rather
than like an error. If the live site looks wrong after a deploy, check the two
files' timestamps in the Cloudflare dashboard before changing anything.

## What it looks like, and why

A clean, light product page: white with one slate tint band, the app's own
indigo as the primary, cyan as the accent, cards with real borders and shadows,
and a single dark surface at the very end where a dark band reads as a full
stop.

An earlier version of this page was drawn as PAPER: a cream ground, a serif
face, and nine facsimile documents, a fee receipt and a challan and an
attendance sheet and a ledger, stacked down the page as proof. It was rejected,
and the reason is worth keeping written down, because the instinct that
produced it will come back. A school owner buying this software is trying to
get away from the pile of paper. Showing them the pile is not proof, it is a
reminder of the problem, and it made a page about software look like a page
about stationery.

So the software is shown as software: one abstract dashboard in the hero and
two UI panels further down, drawn in HTML and CSS with no image files at all.
Nothing on the page is a picture of a document. Keep it that way.

## On the claims

Every feature named on this page is one the software actually does today.
Nothing here describes something planned. If a feature is removed, remove it
here too. A marketing page that overstates the product is the fastest way to
lose the first ten schools, and they are the ten that matter most.

Two things are stated as *not* done, deliberately: the Urdu interface, and fee
collection needing a connection. Saying so costs a few visitors and saves every
one of them from finding out on a Monday morning.
