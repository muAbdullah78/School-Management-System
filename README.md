# School Management System — for Pakistani private schools

Management software for how privately-owned Pakistani schools actually run: cash
fees and bank challans, arrears and discounts, siblings billed as one family,
term exams and BISE-style result cards, and paper registers being replaced by
something a clerk can work at speed.

Sold as a subscription. One codebase, one database, many schools.

---

## What actually exists

Three surfaces over **one** multi-tenant Postgres database:

| Surface | Who uses it | Where |
|---|---|---|
| **The school app** | owner, principal, clerk, accountant, teachers | `web/` — React + Vite, installable as a PWA, also wrapped as a Windows app in `desktop/` |
| **The parent portal** | parents | the same app; a parent signing in sees only their own children |
| **The operator console** | you, the vendor | the same app at `/platform` — every school, their subscriptions, invoices, renewals, metrics, and read-only support visits |
| **The public website** | prospective schools | `site/` — static, no build step: prices, free trial, installer download |

> ### The deployment model, because this changed once and the old answer is still
> ### written down in several places
>
> **All schools share ONE Supabase project.** A school is identified by who logs
> in, not by which copy of the app they run. You set it up once; schools then sign
> themselves up and are billed by subscription.
>
> The **earlier** model — a separate Supabase project per school, owned and run by
> the school, with the vendor hosting nothing — was abandoned. Anything describing
> it is history: [`docs/SETUP-PER-SCHOOL.md`](docs/SETUP-PER-SCHOOL.md) is kept
> only as a tombstone and says so at the top. Do not follow it.

Isolation between schools is enforced by the database, not by careful coding:
every tenant row carries `school_id`, every policy is *(this school)* AND *(this
role)*, and `supabase/tests/tenant_isolation.sql` tries to break out of it as a
signed-in user of another school.

---

## Start here

| If you want to… | Read |
|---|---|
| **install or upgrade a database** | [`docs/SETUP.md`](docs/SETUP.md) — the bundles, in order |
| **know what a database has right now** | run `psql -f supabase/verify.sql`; one row per guarantee |
| **hand a school a manual** | [`site/guide.html`](site/guide.html), 16 chapters with real screenshots, published at `/guide.html` and linked from the site footer, the FAQ, the app shell and the parent portal. Regenerate with `python3 scripts/build-guide.py` |
| **know what is built and what is not** | [`docs/STATUS.md`](docs/STATUS.md) for the exclusions and the honest gaps; [`docs/PARITY.md`](docs/PARITY.md) for the competitor-feature inventory |
| **understand a product decision** | [`docs/09-DECISIONS-LOCKED.md`](docs/09-DECISIONS-LOCKED.md) |
| **understand the money engine** | [`docs/10-MONEY-ENGINE-V2.md`](docs/10-MONEY-ENGINE-V2.md) |
| **understand the operator side** | [`docs/SUPER-ADMIN-DESIGN.md`](docs/SUPER-ADMIN-DESIGN.md) |

**Do not trust a number written in a document.** Counts of migrations, tables and
tests go stale within days and this repository has been bitten by it. Ask the
software:

```bash
ls supabase/migrations/*.sql | wc -l        # how many migrations
psql -f supabase/verify.sql                # what this database actually has
psql -f supabase/repair/detect.sql          # which migrations it is missing
psql -f supabase/repair/why.sql             # and WHY it says so, object by object
```

`why.sql` exists because `detect.sql` answers present-or-missing and each answer
is an AND of up to four conditions, so a MISSING row never says which one failed
— and its advice ("run that migration again") is wrong whenever the checker is
what is broken. That has happened: 0059 reported MISSING on a database where it
was correctly applied, because two exemption lists had drifted apart.

---

## Repo layout

```
web/                     the application — school app, parent portal, operator console
  src/lib/db.ts          every database call the app makes, in one file
  tools/                 rendering harnesses: printables, page gallery, guide screenshots
supabase/
  migrations/            the schema, one file per change, each re-runnable
  bundles/               the same migrations concatenated for pasting into the SQL Editor
  tests/                 SQL suites, run in CI against real Postgres 16
  check-*.py|sh          CI guards — tenant scoping, print wiring, readonly boundary, ...
  verify.sql             what does this database actually have?
  repair/detect.sql      what is it missing?
  repair/why.sql         and WHY does it say that? — names objects, not migrations
  repair/inspect-orphans.sql   what IS that row, before you delete it?
  repair/facts.sql       raw readings, no interpretation — for when a checker is the thing that is wrong
  repair/enforcement.sql are foreign keys still being enforced at all?
site/                    the public website (static)
desktop/                 Tauri shell that wraps the web app as a Windows .msi
docs/                    design records and the school handbook
scripts/                 builds site/guide.html from the template plus screenshots
  check-parity.py        does docs/PARITY.md still match the code?
```

Every guard in that list exists because the thing it guards went wrong once. The
newest is `scripts/check-parity.py`: PARITY.md's 87 statuses are claims about the
code, a claim in a Markdown file is checked by nothing, and eight of them were
wrong at the same time. Each row now carries evidence, and a `missing` row has to
name what would EXIST if it were built — which is the half a guard that only
verified the `have` rows would have let through.

---

## Developer quickstart

```bash
# The app
cd web
cp .env.example .env      # VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY
npm install
npm run dev               # also serves on your LAN, for testing on a phone
npm run build             # typecheck + production build
npm test                  # unit tests
npm run harness           # render printables and pages to scratch/ for a look

# The database, against a throwaway Postgres
psql -f supabase/bundles/1_core.sql        # ... through 10, in NUMERIC order
#   ls supabase/bundles/*.sql | sort -V   # a shell glob puts 10 before 2
psql -f supabase/verify.sql                # every row should say PASS
psql -f supabase/tests/tenant_isolation.sql

# The handbook, after changing a screen
cd web && npm run build && npm run harness
cd .. && node scripts/shot-guide.mjs && python3 scripts/build-guide.py
```

CI (`.github/workflows/ci.yml`) applies every migration to a real Postgres 16 —
each in ONE transaction, matching how a school pastes a bundle into the SQL
Editor — then runs every suite, every guard, and the web build and tests.

---

## Two things only a human can do

`verify.sql` reports both as **ACTION NEEDED** until they are done:

1. **Your own billing details** — registered business name, NTN, address, bank
   account — entered in the operator console under *Our billing details*. Until
   then every subscription invoice prints incomplete, and a school cannot claim
   the expense or file the tax it is obliged to withhold.
2. **Publish a Windows installer** — build it, host the file, then record it with
   its SHA-256 under *Downloads &amp; notices*. Until then the website tells
   visitors the installer is being prepared.

---

## The historical documents

The original plan, kept because the *reasoning* is still useful. Several of them
describe an architecture that no longer exists — per-school Supabase projects, an
SMS engine, a licensing fleet, a Tauri-plus-SQLite-plus-LAN design. Every one that
is superseded says so at the top, and `09` is authoritative where they differ.

| | | |
|---|---|---|
| [00 Overview](docs/00-OVERVIEW.md) | the market and the owner's two anxieties | still accurate |
| [01 Architecture](docs/01-ARCHITECTURE.md) | | superseded |
| [02 Data model](docs/02-DATA-MODEL.md) | the four historical-integrity rules | still the rules |
| [03 Features](docs/03-FEATURES.md) | | partly superseded |
| [04 Risks](docs/04-RISKS-AND-SAFEGUARDS.md) | fraud, data loss, privacy | partly superseded |
| [05 Roadmap](docs/05-ROADMAP.md) | sequencing and effort logic | superseded on the stack |
| [06 Commercial](docs/06-COMMERCIAL.md) | | superseded on pricing |
| [07 Client checklist](docs/07-CLIENT-CHECKLIST.md) | what to gather from a school | data items still right |
| [08 Open decisions](docs/08-OPEN-DECISIONS.md) | the questions, with recommendations | all resolved in 09 |
| [09 Locked decisions](docs/09-DECISIONS-LOCKED.md) | | **authoritative** |

Feature design records — written before each was built, and each amended
afterwards where the design turned out to be wrong: money engine, certificates,
deposits, exam computation, photos, readonly boundary, staff check-in, operator
billing, super admin.

Keeping them is deliberate. Deleting the reasoning behind a decision leaves the
next person free to make it again badly.
