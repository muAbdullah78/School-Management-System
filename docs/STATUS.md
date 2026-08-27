# Status — and why this file no longer holds the numbers

This file used to be a snapshot: how many migrations, how many tests, what was
built. It went stale the way every such file does, and it went stale in the
damaging direction. At the point it was rewritten it still said:

| It claimed | The truth then |
|---|---|
| 35 migrations | 85 |
| 98 web unit tests | 136 |
| 7 SQL suites | 41 files, 82 invocations, 2,532 assertions |
| "load `0001` → `0035`" | seven bundles |
| "the platform role **cannot read tenant data**" | **reversed by an explicit decision** — support can read across all schools, through a logged read-only session |
| "Nobody has run this against a live Supabase yet" | it was deployed and running |

The last two are the reason this file was replaced rather than corrected. A stale
count is embarrassing. A stale sentence about **who can read a child's records**
is a document that misinforms whoever reads it about the security posture of the
product, and the person most likely to read it is the person deciding whether to
trust it.

## Where the live answers are

Every one of those questions has a source that cannot go stale, because it asks
the software instead of remembering:

| Question | Ask this |
|---|---|
| What has this database actually got? | `psql -f supabase/verify.sql` — one row per guarantee, each PASS or a named failure |
| Which migrations is it missing? | `psql -f supabase/repair/detect.sql` |
| How many migrations are there? | `ls supabase/migrations/*.sql \| wc -l` |
| Do the tests pass? | `.github/workflows/ci.yml` runs every suite and all 13 guards on every push |
| Which of the competitor's features exist? | [`PARITY.md`](PARITY.md), which states exactly which of its rows have been re-verified and which have not |
| How does a school actually use it? | [`GUIDE.html`](GUIDE.html) — the handbook, with real screenshots |

`verify.sql` is the one to run. It also reports the two things that need a human
and cannot be done in code: the vendor's own billing details, and publishing a
Windows installer.

## What is deliberately NOT built

Excluded by decision, not oversight. Recorded here because an exclusion is the
one kind of status that does not rot:

SMS alerts · native mobile apps (the parent portal is the answer) · parent
complaints · online classes · holiday calendar · salary and loan management ·
stock and inventory · student behaviour tracking · daily diary · study-material
LMS · email alerts · school noticeboard · transport · biometric devices.

Two items came back off that list on a later decision and **are** built:
certificates and ID cards, and QR check-in for staff (still no biometric).

## Known gaps, stated plainly

These are real, current, and none of them is a bug:

- **Urdu interface.** The screens are English. Data you type in accepts and prints
  Urdu.
- **Online fee payment.** Cash, bank and wallet payments are recorded, but a
  parent cannot pay *through* the app. The subscription side is gateway-ready
  behind a switch; the school-fee side is not.
- **Fee installments.** A schedule that drives due dates was designed in
  [`10-MONEY-ENGINE-V2.md`](10-MONEY-ENGINE-V2.md) and never built.
- **Per-period attendance.** The register is once-daily. Fine for primary, a
  ceiling for classes 9 to 12.
- **Multi-campus.** Not built, and the two empty tables that hinted at it were
  dropped in migration 0083. See PARITY.md for why it needs designing rather than
  restoring.
- **The desktop app is a native window on cloud data**, not an offline system.
  Attendance works offline; fee collection does not. Say that to schools plainly.
- **No exhaustive audit of every join in every definer function.** The tenant
  scoping is enforced by three CI guards and a cross-tenant suite, and those
  found real defects. That is not the same as having read all ~250 of them.

Product decisions live in [`09-DECISIONS-LOCKED.md`](09-DECISIONS-LOCKED.md).
The money engine's reasoning is in [`10-MONEY-ENGINE-V2.md`](10-MONEY-ENGINE-V2.md).
