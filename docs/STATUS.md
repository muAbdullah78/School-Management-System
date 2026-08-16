# Build status — where the application stands

The honest picture of what is built, what is left, and which steps are **yours**
(manual, outside the code) versus **mine** (in the code).

Authoritative product decisions live in [`09-DECISIONS-LOCKED.md`](09-DECISIONS-LOCKED.md).
The money engine's design and reasoning are in [`10-MONEY-ENGINE-V2.md`](10-MONEY-ENGINE-V2.md).

---

## ✅ Built and tested

**Database — `supabase/migrations/` (34 migrations, applied clean from empty on Postgres 16)**

| Area | What it does |
|---|---|
| Core | 30+ tables, append-only money/marks/attendance, soft delete, audit triggers, gapless counters |
| Multi-tenancy | One Supabase project serves every school. Every tenant row carries `school_id`; every policy is (tenant) AND (role) |
| Subscriptions | Trial → active → grace → locked → reactivated. Over the student limit **flags** a school, never blocks an admission |
| Platform | Operator console identity. The platform role **cannot read tenant data** — managing schools never requires reading a child's records |
| **Family billing** | Payments belong to a family and allocate oldest-month-first across siblings. Unallocated money becomes explicit family credit, consumed by the next challan |
| Fees | Heads, per-class structures with **effective dating**, challans, arrears, partial payments, fines, approved discounts, reversal, deferral, pending-vs-verified |
| **Annual raise** | `fn_fee_increment` — preview → commit, writes a new dated amount, never edits the old one |
| **Vouchers** | Every challan carries a unique scannable code that resolves to the family |
| **Accounts** | Append-only expenses and non-fee income with gapless vouchers; profit today/month/year. Fee income is derived from receipts and **cannot be hand-entered** |
| **Cash drawer** | Per-collector till, auto-opened on first cash payment, closed against counted cash with a frozen variance and owner sign-off |
| **Portal** | Parent and teacher. A parent account has **zero direct table access**; everything comes through scoped functions |
| **Results release** | `published_at` + publish/withdraw, so parents see only what the school has released, newest version only |
| **Messages** | Outbox recording every intended message; free WhatsApp click-to-chat; payments-vs-receipts-sent report |
| Attendance | Daily register, finalise and lock, summaries, staff check-in codes |
| Exams | Terms, papers, marks, grading, positions, result cards, tabulation, date sheets, admit cards |
| Imports | Students, opening fee balances, staff |
| Rollover | Promote/retain/graduate with preview → commit → **undo** |

**Application — `web/`** — Dashboard, Admissions, Students, Attendance, Tests, Exams,
Fees (family collection), **Accounts**, **Cash drawer**, **WhatsApp**, Staff,
Certificates, Reports, Settings, **Parent portal**, operator console. Installable
PWA with offline attendance. Design system with semantic colour.

**Marketing site — `site/`** — static, 35KB, no build step, SEO metadata and
schema.org. See [`site/README.md`](../site/README.md) for what to replace before launch.

**Quality gates — all green**
- **98 web unit tests**, typecheck + build
- **7 SQL suites**: `tenant_isolation`, `subscription_rules`, `family_money`,
  `finance`, `portal`, `outbox`, `fee_ops`
- CI applies all 34 migrations to a real Postgres 16 and runs every suite plus an
  end-to-end sanity pass (import → rollover → fee ops → reconciliation)

---

## 🧑‍💻 Your manual steps

Everything below needs a human. Nothing in the code is waiting on them.

1. **Supabase project** — reset the existing one (its data is disposable) and load
   `0001` → `0034`. Full walkthrough in [`SETUP.md`](SETUP.md).
2. **Deploy the two Edge Functions** — `SETUP.md` step 4.
3. **Make yourself the operator** — one SQL snippet, `SETUP.md` step 5.
4. **Marketing site** — register the domain, then replace the placeholders listed
   in [`site/README.md`](../site/README.md): domain, contact details, trial links.
5. **Windows installer** — the Tauri shell in `desktop/` builds a `.msi` on a
   Windows runner. A *signed* build needs your code-signing certificate.

---

## ⬜ Deliberately not built

Excluded by decision, not oversight: SMS alerts, native mobile apps (the portal is
the answer), parent complaints, online classes, holiday calendar, salary & loan
management, stock & inventory, student behaviour tracking, daily diary, LMS, email
alerts, noticeboard, transport, biometric devices.

**Known gaps, stated plainly:**
- **Urdu interface.** The UI is English. Data you type in accepts and prints Urdu.
- **Online fee payment** (JazzCash/EasyPaisa gateways) — cash, bank and wallet
  payments are recorded, but the parent cannot pay *through* the app.
- **Fee installments** — a schedule that drives due dates was designed
  (`10-MONEY-ENGINE-V2.md`) but is not built.
- **Per-period attendance** — the register is once-daily. Fine for primary, a
  ceiling for classes 9–12.
- **The desktop app is a native window on cloud data**, not an offline system.
  Attendance works offline; fee collection does not. Say this to schools.

---

## What only you can test

Nobody has run this against a live Supabase yet. The build is clean and the SQL is
proven against real Postgres, but no human has clicked these screens. Worth doing
first, in this order:

1. Family fee collection with **two children on one father's CNIC**
2. A month's challans, then the reconciliation report
3. Close a cash drawer with a deliberate Rs 50 shortfall and check it demands a reason
4. Sign in as a parent and confirm you can see **only** that family
5. Record an expense and check the profit figure moves
