# School Management System — for Pakistani Private Schools

> **Working name:** *"{School Name} Manager"* — the product is branded per school (e.g. *City Public School Manager*).

A management system built for how privately-owned Pakistani schools actually run — cash fees and bank challans, arrears and discounts, term exams and BISE, and paper registers being replaced by something modern. Sold to one school at a time, each running its **own** copy.

## Two faces, one database
1. **Admin "desktop" app** (Windows 10/11) — owner/clerk/accountant: admissions, the fee engine, exams, student profiles, reports.
2. **Teacher "live web" app** (a URL on their phone) — attendance (offline-tolerant) and test/exam marks.

Both are the **same React app**, role-based, talking to the school's **own Supabase database** — so there is one source of truth and **no two-database sync engine to build**.

## Deployment model (important)
The seller does **not** host a fleet. When a school buys, the seller sets up — on the **school's own Google account** — a Supabase project (their database + logins + storage), web hosting, and the desktop install. From then on the school **owns and runs its own backend and data.** Details: [`docs/SETUP-PER-SCHOOL.md`](docs/SETUP-PER-SCHOOL.md).

---

## Repo structure
```
web/                     # The application (React + Vite + TS + Tailwind) — admin + teacher, role-based
supabase/
  migrations/            # Postgres schema (30 tables, Row Level Security, audit triggers)
  seed.sql               # Starting config for a fresh school
  config.toml            # Supabase CLI config
docs/                    # The plan & strategy (read 09 first — it supersedes earlier assumptions)
```

## Documentation — read in this order
| # | Doc | Notes |
|---|-----|-------|
| **09** | [Locked Decisions](docs/09-DECISIONS-LOCKED.md) | **Authoritative.** Final deployment model & decisions; supersedes 01–08 where they differ |
| 00 | [Overview & Vision](docs/00-OVERVIEW.md) | The product and the market gap |
| 01 | [Architecture](docs/01-ARCHITECTURE.md) | Rewritten for the Supabase-per-school model |
| 02 | [Data Model](docs/02-DATA-MODEL.md) | The four historical-integrity rules (implemented in `supabase/migrations`) |
| 03 | [Feature Map](docs/03-FEATURES.md) | Every module (minus the messaging engine & Urdu — see 09) |
| 04 | [Risks & Safeguards](docs/04-RISKS-AND-SAFEGUARDS.md) | Fraud/data-loss/privacy defenses (licensing/messaging items superseded by 09) |
| 05 | [Roadmap](docs/05-ROADMAP.md) | Phases and sequencing |
| 06 | [Commercial](docs/06-COMMERCIAL.md) | Pricing (per-school self-host model — see 09) |
| 07 | [Client Checklist](docs/07-CLIENT-CHECKLIST.md) | What the owner provides per school |
| — | [Per-School Setup](docs/SETUP-PER-SCHOOL.md) | The step-by-step setup you run per sale |

---

## Developer quickstart

```bash
# Web app
cd web
cp .env.example .env         # fill VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY (per school)
npm install
npm run dev                  # http://localhost:5173  (also on your LAN for phone testing)
npm run build                # typecheck + production build

# Database (against a school's Supabase project)
supabase link --project-ref <ref>
supabase db push             # applies supabase/migrations
# then run supabase/seed.sql in the SQL editor
```

## Build status — Phase 0 foundation ✅
- Database schema: **30 tables**, role-based **Row Level Security (61 policies)**, append-only payments, audit-log triggers, gapless counters — **validated on Postgres 16**.
- App shell: Supabase auth, role-based navigation, school-branded layout, module placeholders — **builds clean**.
- Next: Auth phase → Fees → Attendance (see [`docs/05-ROADMAP.md`](docs/05-ROADMAP.md)).
