# Build Status — where the application stands

This is the **living, honest picture** of what is built, what is left, and which
steps are **yours** (manual, outside the code) vs **mine** (Claude, in the code).
It supersedes the tech-stack details in [`05-ROADMAP.md`](05-ROADMAP.md); the
authoritative product decisions are in [`09-DECISIONS-LOCKED.md`](09-DECISIONS-LOCKED.md).

_Last updated after: exam printables (date sheet + admit cards)._

---

## ✅ Done (on `main` / in the open PR)

**Database — `supabase/migrations/` (15 migrations, all validated on Postgres 16)**
- Core 30-table schema, identity/state split, append-only money/marks/attendance, soft-delete, **61 RLS policies**, audit triggers, gapless counters (GR / receipt / certificate serials).
- Fees engine, attendance, admissions, exams, settings, certificates, dashboard rollup, assessments, staff, auth auto-provisioning, **bulk student import**, **opening fee-balance import**, **year-end rollover**.

**Application — `web/` (React + Vite + TS + Tailwind, one codebase, both surfaces)**
- Every navigation module is a real, working screen (no placeholders): **Dashboard, Admissions, Students, Attendance, Tests, Exams & Results, Fees, Staff, Certificates, Reports, Settings**.
- First signup becomes **owner**; user/role management in Settings.
- **Export all data** (JSON backup), a two-part **Import** (students + opening fee balances), and **Year Rollover** (promote/retain/graduate, preview → commit → undo) in Settings.
- **Installable PWA + offline attendance**: the app installs to a phone home screen and opens offline; attendance saved while offline is queued locally and **syncs automatically on reconnect** (with an app-wide connectivity/sync banner).

**Quality gates**
- **63 unit tests**; **CI** runs the web build/typecheck + tests, applies all migrations on a real Postgres 16, and exercises the import and rollover RPCs end-to-end. The offline shell was verified in headless Chromium (service worker controls the page; a full offline reload still boots the app).

---

## ⬜ Left to reach the full v1.0 spec

Ordered by how badly a real school feels the gap. Each is a self-contained workstream I can build.

| # | Workstream | Why it matters | Size |
|---|-----------|----------------|------|
| 1 | **Certificate depth** | Leaving/character/bonafide + serials exist; **student/staff ID cards with QR** from the spec are not done. | S–M |
| 2 | **Desktop wrapper (Windows)** | The setup guide references a CI-built `.msi` admin app. It doesn't exist yet — the web app runs in a browser meanwhile. Needs a Tauri (or similar) shell **plus your code-signing** (see manual steps). | M |
| — | *Nice-to-haves* | More report types (per-student fee ledger, monthly attendance register), staff bulk import; **offline roster cold-start** (cache the last roster so a teacher can open the app with no connection and still see the class — today the marks-queue covers a connection that drops while the page is open). | S each |

**So: ~2 substantive workstreams remain** before the app matches the full written spec, after which we do the joint inch-by-inch testing pass.

### ✅ Recently completed
- **Bulk student import** (CSV) — Settings → Import → Students.
- **Opening fee-balance / arrears import** — Settings → Import → Opening fee balances. A mid-year school loads real outstanding balances, so Fees/defaulters start from reality.
- **Academic-year rollover** — Settings → Year Rollover. Promote/retain/graduate the whole roster into a new session with new roll numbers; arrears carry automatically; **preview → commit → undo** (undo is blocked once the new session has activity). Closes the "breaks within 12 months" gap.
- **Installable PWA + offline attendance** — the teacher app installs to a phone and works offline; marks queue locally and sync on reconnect. Verified in headless Chromium. *(Needs a real-device browser test on your side — see manual steps.)*
- **Exam printables** — the tabulation/consolidation sheet (Exams → Result Cards), plus **date sheet** and **admit cards / roll-number slips** (Exams → Setup, once a term's papers and their dates/times are set). Completes the exam module's paper output.

---

## 🧑‍💻 Your manual steps (things only you can do)

### A. Stand up ONE Supabase project so we can actually run & test the app
The app is only a front-end to **the school's own Supabase**. I can't create your Google/Supabase account, so to see any of this running you need one project (the free tier is plenty for testing). Full detail is in [`SETUP-PER-SCHOOL.md`](SETUP-PER-SCHOOL.md); the short version:

1. **Create a Supabase project** at supabase.com (sign in with Google → New project). Region **Singapore**. Save the DB password.
2. From **Settings → API**, copy the **Project URL** and the **anon public key**.
3. **Load the schema:** either install the Supabase CLI and run `supabase link` + `supabase db push`, or open **SQL Editor** and paste each file in `supabase/migrations/` in order (0001 → 0012), then paste `supabase/seed.sql` and Run.
4. **Run the app** — two options:
   - *Local (fastest to test):* in `web/`, copy `.env.example` to `.env`, set `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SCHOOL_NAME`, then `npm install && npm run dev` and open the printed URL.
   - *Hosted:* connect the repo to Cloudflare Pages/Vercel with those three env vars (build `npm run build`, output `web/dist`).
5. **Create the owner login:** Supabase → Authentication → Users → Add user (email + password). The **first** user becomes `owner` automatically.
6. **Log in and configure:** Settings → School Profile, then **Classes & Sections**, then **Fee Structure**. Now try **Settings → Import Students** with the template — this is the newest piece and worth a real test.

> Tell me your Project URL only if you want me to sanity-check config — **never paste the DB password or service-role key** into chat.

### B. Decisions/assets that are yours
- **Pilot school** (Decision #10) — line up one real school; their fee sheet + a class register is the best test data.
- **Desktop `.msi`** — when we build workstream #6, packaging a signed Windows installer needs a **Windows machine and a code-signing certificate** (or we accept an unsigned build for the pilot). That signing step is yours; I'll build the wrapper and the CI that produces the installer.

### C. Nothing else is blocking me
None of the six code workstreams need anything from you first — I can keep building while you stand up the Supabase project in parallel. The only thing I *can't* substitute for is a live Supabase project to run against.

---

## How we'll test at the end (both sides)
1. **Me:** unit tests + CI (build, migrations, RPC behaviour) — already running on every push; I extend it as each workstream lands.
2. **You:** inch-by-inch on a real Supabase project with real data — admit/import students, run a monthly challan + collect fees, mark a full day's attendance, run a term to printed result cards, issue a certificate, do a year-end rollover, and take a backup/export. For the PWA: open the hosted URL on an Android phone, **Add to Home Screen**, then turn on airplane mode and confirm the app still opens and you can mark a class — turn connectivity back on and watch the banner sync it.

I'll keep this file updated as each workstream is completed.
