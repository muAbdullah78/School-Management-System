# Build Status — where the application stands

This is the **living, honest picture** of what is built, what is left, and which
steps are **yours** (manual, outside the code) vs **mine** (Claude, in the code).
It supersedes the tech-stack details in [`05-ROADMAP.md`](05-ROADMAP.md); the
authoritative product decisions are in [`09-DECISIONS-LOCKED.md`](09-DECISIONS-LOCKED.md).

_Last updated after: Windows desktop wrapper (Tauri)._

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

**Every substantive workstream from the spec is now built.** What remains is one manual step that's yours, plus optional nice-to-haves.

| Item | Status |
|------|--------|
| **Windows desktop `.msi`** | Scaffolded (`desktop/`, Tauri v2) + a **dispatch/tag-triggered** GitHub workflow that builds the installer on a Windows runner. The `.msi` build runs on GitHub's Windows runner (or your Windows PC) — **not** verifiable in this Linux environment — and shipping a **signed** installer needs your **code-signing certificate** (the one part only you can do). |
| *Nice-to-haves* | ~~more report types~~ ✅ (per-student fee ledger + monthly attendance register added). Still optional: **staff bulk import**; **offline roster cold-start** (cache the last roster so a teacher can open the app with no connection and still see the class — today the marks-queue covers a connection that drops while the page is open); **staff ID cards** (student ID cards with QR are done; staff cards would reuse the same layout). |

**So: the full written spec is built.** Next is the **joint inch-by-inch testing pass** on a real Supabase project (see below), plus the desktop signing when you're ready.

### ✅ Recently completed
- **Bulk student import** (CSV) — Settings → Import → Students.
- **Opening fee-balance / arrears import** — Settings → Import → Opening fee balances. A mid-year school loads real outstanding balances, so Fees/defaulters start from reality.
- **Academic-year rollover** — Settings → Year Rollover. Promote/retain/graduate the whole roster into a new session with new roll numbers; arrears carry automatically; **preview → commit → undo** (undo is blocked once the new session has activity). Closes the "breaks within 12 months" gap.
- **Installable PWA + offline attendance** — the teacher app installs to a phone and works offline; marks queue locally and sync on reconnect. Verified in headless Chromium. *(Needs a real-device browser test on your side — see manual steps.)*
- **Exam printables** — the tabulation/consolidation sheet (Exams → Result Cards), plus **date sheet** and **admit cards / roll-number slips** (Exams → Setup, once a term's papers and their dates/times are set). Completes the exam module's paper output.
- **Student ID cards with QR** — Certificates → issue an *ID Card*: a printable card with the student's details and an on-device QR of the GR number (generated client-side, so it works offline). Uses the same gapless serial register as the other certificates.
- **Windows desktop wrapper** — `desktop/` is a Tauri v2 shell that opens the school's hosted web app in a native window (asks for the URL once). A dispatch/tag-triggered workflow builds the `.msi` on a Windows runner. Same app, same database — just a real window for the admin PC. *(The installer builds on GitHub's Windows runner; a signed build needs your code-signing certificate — see `desktop/README.md`.)*
- **More reports** — Reports now also has a **monthly attendance register** (class/section × days grid, print/CSV) and a **per-student fee ledger** (debit/credit running balance, print/CSV).

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
