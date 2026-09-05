# Search: what is built, what you must do, and what nobody can promise

## The honest part first

**You cannot rank in the top three for "schools", "manager" or "management
system", and trying would waste your money.** Not because of effort or budget.
Because of what those words mean to Google:

| Query | What Google decides it means | Who is searching |
| --- | --- | --- |
| `schools` | Schools near the searcher | A parent looking for a school |
| `manager` | The dictionary word, and job adverts | Nobody buying software |
| `management system` | An encyclopedic definition | A student writing an essay |

A software product cannot be the best answer to "schools", and a person who
types it is not buying school software. Anybody who promises you those rankings
is selling you something.

**What is winnable is worth far more.** These are the queries a Pakistani school
owner actually types when they have your problem. Low competition, high intent,
and the searcher is already looking to buy:

| Query cluster | The page that owns it |
| --- | --- |
| school management software Pakistan | `/` |
| school fee management software, fee challan software | `/fee-management` |
| school attendance software, attendance register app | `/attendance` |
| result card software, exam marks software | `/exams-and-results` |
| school accounts software, school payroll | `/accounts` |
| parent portal for schools | `/parent-portal` |
| school management software price in Pakistan | `/pricing` |
| how to make a fee challan, what a challan must contain | `/guides/fee-challan-pakistan` |
| school fee collection problems, missing fee income | `/guides/expected-vs-collected` |
| moving school records from paper, school data entry | `/guides/moving-from-paper-registers` |

One page per query, stated in each page's front matter. Two pages targeting the
same query compete with each other and neither wins, which is why
`scripts/check-site-seo.py` refuses duplicate titles, descriptions and h1s.

**Rankings are Google's decision, not a deliverable.** What is built here is
every technical and structural thing that is in our control. What follows the
technical work is time, links and reputation, and those cannot be shipped.

## What is built

- **Fifteen pages instead of one.** A single scrolling page can rank for one
  intent. See `site/README.md` for the build.
- **Per-page title, description, canonical and Open Graph tags,** all unique,
  all inside the lengths Google actually displays.
- **A 1200x630 share card** (`site/og.png`), so a link pasted into WhatsApp
  shows the product rather than a line of grey text. This matters more in
  Pakistan than almost anywhere: WhatsApp is how a link travels between two
  school owners.
- **Structured data**: `Organization`, `SoftwareApplication` with the real
  prices as offers, `BreadcrumbList` on every page below the home page, and
  `FAQPage` on `/faq` generated from the page's own visible text so the markup
  can never claim something the page does not say.
- **A generated sitemap** that cannot list a page which does not exist or miss
  one that does, and a `robots.txt` that names it at the live domain.
- **A real 404 page** with links on it.
- **A favicon Google can actually fetch**, which is a longer story than it
  sounds. See the section below.
- **Response headers** (`site/_headers`): a Content Security Policy, HSTS,
  nosniff, a referrer policy, and no framing. Not a ranking factor, but the
  site now renders reviews written by other people, and that is the one place
  a stored script could ever have reached another school owner's browser.
- **Clean extensionless URLs**, canonical to the exact URL Cloudflare serves
  with a 200 and no redirect.
- **Internal linking**: every page links to its siblings and to pricing, and no
  page is orphaned. The guard fails the build if one becomes unreachable.
- **Speed and mobile**, which are ranking factors and were already fine: static
  HTML, one small stylesheet, no blocking JavaScript, no web fonts on the
  product pages, verified with no horizontal overflow from 320px up.

### Why the search result showed a grey globe, and what fixed it

This is worth reading once, because the page looked completely correct.

Every page carried this in its head:

    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,...">

The tab icon worked in the browser, so nothing looked wrong. But **Google
fetches the favicon in a separate request from the page**, which means it needs
an address to ask for, and a `data:` URI is not an address. There was nothing
to fetch. Google's other route is `/favicon.ico` at the root of the domain, and
that file did not exist either. Both paths dead-ended, and the grey globe is
what Google shows when they do.

What is there now, generated from one file (`site-src/icon.svg`) by
`node scripts/build-icons.mjs`:

| File | What it is for |
| --- | --- |
| `/favicon.ico` | The address Google tries when a page declares nothing. Contains 16, 32 and 48 pixel versions. |
| `/icon.svg` | Modern browser tabs, and the logo in the site's own header and footer. |
| `/icon-48.png`, `/icon-96.png`, `/icon-192.png` | For Google. It asks for a square whose side is a multiple of 48. |
| `/icon-512.png` | Android home screen, and the `logo` in the structured data. |
| `/icon-maskable-512.png` | Android again. It crops an icon to a circle 80% of the width, so this one has the mark shrunk to fit inside that. |
| `/apple-touch-icon.png` | iPhone and iPad home screens. Square and opaque, because iOS puts a transparent corner on black. |

**Do not rename any of these.** Google caches a favicon against its URL, so a
new filename means waiting for a recrawl before the icon changes.

Three things to know about the timing and the traps:

1. **It is not instant.** Google recrawls the favicon separately from the page,
   and it usually takes days, sometimes a few weeks. There is no "submit
   favicon" button. Requesting indexing of the home page in Search Console is
   the closest thing, and it does help.
2. **Cloudflare Bot Fight Mode can break it.** Google fetches the favicon with
   its own crawler, and Bot Fight Mode has been known to challenge it, which
   looks to Google like the file is unavailable. If the icon has not appeared
   after a few weeks, open Cloudflare, go to **Security**, and check whether
   Bot Fight Mode is on. If it is, turn it off, or add an exception, and give
   it another fortnight.
3. **`robots.txt` must not block it.** Ours allows everything, and
   `scripts/check-site-seo.py` fails the build if a `Disallow` ever covers the
   icon files, because that is a silent way back to the grey globe.

The mark itself changed slightly. It is now the graduation cap that the app
already used, in the brand indigo rather than the blue it was drawn in, and the
gap between the cap and the base below it was widened. That gap used to be 7
units out of 512, which is a fifth of a pixel at the 16 pixel size Google
renders, so it closed and the whole mark became a white blob. The website's
header, the app, the Android and iPhone icons and the search result are now all
the same picture from the same file.

### Telling Google that your other listings are you

`site-src/data/profiles.json` holds a `sameAs` list. This is how you tell Google
that the Google Business Profile, the G2 listing, the Capterra listing and this
website are **one company** rather than four similarly named things. It is one
of the stronger signals behind a Knowledge Panel.

It ships empty on purpose. A `sameAs` pointing at a listing that does not exist
is a claim Google can check and find false, so a guess is worse than nothing.

To fill it in: open each listing in a browser, copy the address bar exactly,
and paste it into the list. Then run `python3 scripts/build-site.py` and
re-upload `site/`. Leave out anything still "in review" and add it once you can
open it yourself. The build refuses any entry that is not an `https://` URL, so
a typo stops the build instead of shipping.

The same file holds the public contact address, which goes into the structured
data. It is separate from `config.js` because `config.js` is read by the
browser at runtime, and structured data has to already be in the HTML that
Google fetches.

### A note on FAQ rich results

`/faq` carries valid `FAQPage` markup, and it is worth knowing that since 2023
Google has restricted FAQ rich results to well-known authoritative government
and health sites. The markup is correct and harmless and helps Google
understand the page, but do not expect the expandable questions to appear in a
search result. Anybody who tells you otherwise is working from a 2019
playbook.

## What only you can do, in order

### 1. Google Search Console, this week

Without it you are guessing. It is free and it is the only place that tells you
which queries you actually appear for.

1. Go to `search.google.com/search-console` and add a property.
2. Choose **Domain** and enter `theschoolmanager.site`.
3. It gives you a TXT record. In Cloudflare, go to your domain, then **DNS**,
   then **Add record**: type `TXT`, name `@`, content the string Google gave
   you. Save, then press Verify. It usually works within a minute because the
   domain is already on Cloudflare.
4. Once verified, open **Sitemaps** and submit `sitemap.xml`.
5. Open **URL Inspection**, paste `https://theschoolmanager.site/`, and press
   **Request indexing**. Do the same for `/fee-management` and `/pricing`.

Then leave it alone for two weeks. Indexing a new site takes days, not hours,
and re-requesting does not make it faster.

### 2. Google Business Profile, the same week

This is the single highest-value thing you can do, and it does something the
website cannot: **it is where star ratings in Google actually come from.**

1. `business.google.com`, create a profile for the business.
2. Category: **Software company**. Service area: the cities you sell in.
3. Add the phone number, the WhatsApp number, the website, and real photographs
   of the actual work, not stock images.
4. Verification is usually by phone or postcard and can take a week.

Once it exists, a search for your business name shows a panel with your phone,
your website and your reviews, and it is the only reliable route to stars beside
your name. See the note on stars below.

### 3. Bing Webmaster Tools, ten minutes

`bing.com/webmasters`. It can import everything from Search Console in one
click. Bing is a small share of Pakistani search, but it is ten minutes and it
also feeds some AI assistants.

### 4. Links, slowly and honestly

Ranking beyond the first month is mostly about who links to you. In order of
value for your business:

- **Your customers.** Ask each school, once they are happy, whether they will
  put "Managed by The School Manager" with a link in their own website footer.
  A link from a real Pakistani school is worth more than fifty directory
  listings.
- **Local business directories** that are real: your city's chamber of
  commerce, Pakistani software directories, PASHA if you join.
- **Software listing sites**: Capterra, GetApp, G2, SourceForge. Free listings.
  These are also a route to reviews that are not on your own site, which
  matters for the star question below.
- **Writing.** The three guides are the beginning of this, not the end. One
  genuinely useful article a month, about the work rather than about the
  software, is the cheapest durable traffic there is.

**Never buy links.** Paid link schemes are the one thing Google acts on
manually, and a manual action is much harder to recover from than a bad ranking.

### 5. What to measure, monthly

In Search Console, look at **Performance** and write down four numbers:

1. Total impressions. Is the site being shown at all?
2. Total clicks.
3. The queries you appear for. Are they the ones in the table above?
4. Average position for `school management software pakistan`.

Judge it on the trend over six months. One month tells you nothing.

## About stars in search results

You asked for reviews with stars, visible to other people on the internet. Here
is the honest position, because this is an area full of bad advice.

**On your own site**, `Review` and `AggregateRating` markup about yourself is
what Google calls a *self-serving review*. Google explicitly does not show
review snippets for self-serving reviews on `Organization` or `LocalBusiness`.
`SoftwareApplication` is on Google's supported list, so stars from a genuine
aggregate rating *may* appear, but it is at Google's discretion and it is
routinely ignored for first-party reviews.

**The reliable routes to stars** are third parties Google trusts: your Google
Business Profile, and software directories like Capterra and G2. Those show
stars because the platform, not you, controls the data.

So the review system being built does two things, and it is worth being clear
about which is which:

1. It puts real, verified reviews on your own site where a visitor deciding
   whether to call you will read them. That is worth building regardless of
   Google.
2. It emits correct `SoftwareApplication` + `aggregateRating` markup from that
   real data, so stars can appear if Google chooses to show them.

It does not promise stars. Anything that promised stars from first-party
markup would be promising you something outside its control, and if the
aggregate were ever inflated to chase them, the markup would be a lie about
your customers.

## How the review system works, and how to publish one

**A school writes it from inside the software.** Dashboard, or `/feedback`
directly. The rules are in the database (migration 0093), not in the form:

| Rule | Enforced by |
| --- | --- |
| Only the owner or principal of the school | `fn_review_upsert` checks the role |
| 21 days since the school was created | `fn_review_eligibility` |
| 20 real receipts issued, reversals excluded | `fn_review_eligibility` |
| One review per school | a partial unique index |
| Invisible for 24 hours, then public by itself | a condition on the read, not a scheduler |
| Editing re-arms the 24 hours | `fn_review_upsert` |
| Removable only for a listed abuse category | a CHECK constraint, and every removal is logged |

There is **no approve button** in the operator console, on purpose. If
publishing needed our approval, every review we did not like could sit in a
queue for ever and the average on the website would be a number we chose. The
console can take one down for spam or for naming a child, and that is all, and
both the reason and the rating go into `operator_actions`.

**The page shows the whole distribution**, not just the average. An average of
4.9 over three reviews reads as three reviews, and a curated average is obvious
from a distribution with a hole in it.

### Getting a new review onto the website

The page reads reviews live, so a new one appears for visitors on its own. But
the STRUCTURED DATA is baked into the HTML, because a rating that depends on a
runtime fetch is a rating that silently disappears the day the fetch fails. So
after a school posts one, to update what Google reads:

```
export PGHOST=... PGPORT=... PGUSER=... PGDATABASE=... PGPASSWORD=...
python3 scripts/fetch-reviews.py     # reads the live database
python3 scripts/build-site.py        # bakes it into /reviews
python3 scripts/check-site-seo.py    # refuses a page that disagrees with the data
```

then upload `site/` again. `fetch-reviews.py` reads only the public views, so
it cannot copy an author's name or a moderation note into a file that goes on a
web server. `check-site-seo.py` refuses a build where the page, the JSON and the
marked-up rating do not all agree, and refuses an `aggregateRating` with no
reviews behind it.
