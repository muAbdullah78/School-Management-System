# 05 — Roadmap, Effort & Break-Even

> **⚠️ Historical planning doc.** This roadmap predates the locked deployment
> decision and still describes the original **Tauri + encrypted-SQLite + LAN**
> architecture and the seller-hosted fleet (licensing, SMS engine, Urdu). Those
> were **superseded** by [`09-DECISIONS-LOCKED.md`](09-DECISIONS-LOCKED.md) —
> the product is now a **per-school Supabase** app, English-only, no messaging
> engine, no licensing fleet. Read this for the *sequencing and effort logic*,
> not the tech stack. For the **current build status and the concrete list of
> what's left**, see [`STATUS.md`](STATUS.md).

Sequenced so **value ships early and risk is retired early**. Every phase has a concrete **Definition of Done (DoD)** — a testable statement, not a vibe.

> **On the estimates.** These are planning figures with wide error bars, expressed in **focused full-stack dev-weeks**. "Solo" means one strong full-stack developer (or the owner building with heavy AI assistance). Two developers roughly halve calendar time minus coordination overhead. Treat them as ranges, and re-baseline after Phase 0, when the real velocity is known.

---

## Phase 0 — Foundation (prove the risk spine before any feature)
**Why first:** the four things that kill this class of project are all infrastructure, not features. We prove them working before writing a single business screen.

**Build:** the Tauri shell + Node/TS backend + encrypted SQLite (WAL) local-server architecture, with the desktop app and teacher PWA as clients of **one** DB · the **HTTPS-on-LAN** solution (locally-trusted cert + stable hostname) so the PWA is a real secure context · the core schema (School→Campus→Shift→Session→Class→Section→Enrollment→Student, append-only ledgers, hash-chained AuditLog, soft-delete) with **tested transactional migrations** · RBAC + per-user login · licensing/activation + heartbeat + **long offline grace** · **backup + verified restore incl. key escrow and dead-PC recovery** · the signed **update channel** · **Urdu font bundling + PDF pipeline** proof · the **config/settings engine** (fee heads, grade bands, class ladder, numbering, holiday calendar, feature toggles).

**DoD:**
- A technician installs the signed package on a cheap 4 GB Windows PC **offline**.
- A **teacher phone installs the PWA and marks a full class offline over the HTTPS-LAN**, then flushes on reconnect.
- A record **survives a hard power-cut** (auto-save).
- A backup is taken and **restored onto a *fresh* machine** with integrity confirmed (the key-escrow path works).
- A license goes **read-only after grace expiry**; data **export still works** when unlicensed.
- A bilingual PDF renders correctly on a cheap printer.
- A schema migration runs **forward and rolls back**.

**Effort:** ~**6–8 dev-weeks** solo. *No business feature yet — this is the foundation everything hangs off.*

---

## Phase 1 — Pilot MVP (a pilot school runs its core operation)
**Scope is deliberately lean** (the two highest-pain areas + safety rails). Exams/certificates are the fast-follow.

**Build:** Admissions + lifelong Student profile · Academic structure (configurable classes/sections/subjects/streams/shifts) · **Fee engine** (heads, slabs, monthly challan run, arrears carry-forward, partial payments, fines, discounts with approval + register, refunds, defaulter list, receipt printing, daily cash reconciliation, pending-vs-verified, **expected-vs-collected + ghost-student check**) · **Attendance web app** (offline-first, finalize/lock, auto sheet + **exceptions-only SMS alerts**) · **Communication engine** (Urdu/Roman-Urdu templates, automated **SMS**, delivery log, cost/credit visibility) · **Owner dashboard** + PDF/Excel export · **RBAC + tamper-evident audit** · paper-register Excel import (**assisted, phased**) · basic staff records + teacher logins.

**DoD:** the pilot school **stops using its paper registers for admissions, fees, and attendance** for one full term; a monthly challan run with arrears + discounts produces bills **validated against the school's own fee sheet**; a teacher marks a class **faster than paper, offline**, and it syncs; finalized attendance **auto-sends absentee SMS**; the owner **reconciles the cash drawer** from the daily report and sees expected-vs-collected exceptions.

**Effort:** ~**10–14 dev-weeks** solo.

---

## Phase 1.5 — Fast-follow (completes v1.0: the exam & certificate story)
**Build:** Tests web app (offline mark grid) · Exams & result cards (terms, date sheet, admit cards, marks entry, configurable grading A1/GPA, rank toggle, tabulation, **DMC**, result-withheld-for-defaulters, bulk bilingual print, result SMS) · Certificates suite (SLC with serial, character, bonafide, ID cards with QR) · **Academic-year rollover** (preview/commit/undo).

**DoD:** a term runs **end-to-end to printed bilingual result cards**; a full year **rolls over in preview-then-commit without corrupting the roster**; a leaving certificate prints with a tracked serial.

**Effort:** ~**8–10 dev-weeks** solo.

> **Milestone: v1.0 = Phase 0 + 1 + 1.5.** A single school can run its **entire** operation on it.

---

## Phase 2 — Deepen operations & reach
**Build:** Timetable + substitution · staff attendance & leave · salary & payroll with payslips · read-only parent portal (low-bandwidth) + **WhatsApp Business API automation** · bank/wallet statement-import reconciliation + optional JazzCash/Easypaisa callbacks · masked/branded SMS once PTA approval lands · full RTL Urdu admin UI · central **fleet telemetry** dashboard + incident runbooks.
**DoD:** a school pays staff from the system with correct absence deductions; parents self-serve results/fees, cutting push volume; the owner reconciles bank-challan payments against a statement import; we see version + backup health across the whole fleet from one screen.
**Effort:** ~**10–14 dev-weeks** solo.

## Phase 3 — Growth & optional modules
Front-desk leads · discipline/behaviour + homework-diary · transport · multi-campus consolidated owner reporting. **Effort:** ~**8–12 dev-weeks**, built to demand.

## Later — long-tail add-ons (only on paying demand)
Library · inventory/assets + uniform/book-shop · full health module · hostel/boarding.

---

## Calendar summary

| Milestone | Solo (1 dev) | Two devs (approx) |
|---|---|---|
| Phase 0 (foundation) | ~1.5–2 months | ~1–1.5 months |
| **Pilot MVP ready** (P0 + P1) | **~4–5.5 months** | **~2.5–3.5 months** |
| **v1.0 complete** (+ P1.5) | ~6.5–8 months | ~4–5 months |
| Phase 2 | +~3 months | +~1.5–2 months |

---

## Cost to build & run (the supply side the first draft ignored)

**One-time build cost** (if *hiring*, not building yourself):
- A mid-level Pakistani full-stack dev ≈ **PKR 150k–250k/month**.
- **Pilot MVP** (~5 dev-months) ≈ **PKR 0.75M–1.25M**. **Full v1.0** (~7 dev-months) ≈ **PKR 1.1M–1.75M**.
- If the **owner builds it with AI assistance**, cash build cost is close to zero — the cost is their time. This is the likely path here.

**Fixed running cost** (whole fleet, not per school):
- Control-plane VPS + warm standby: ~**PKR 60k–90k/yr**.
- Domain, code-signing certificate, error/monitoring tooling: ~**PKR 40k–70k/yr**.
- Encrypted backup storage: **pennies per school** (Litestream → B2/R2).
- **SMS/WhatsApp are pass-through**, funded by the messaging-wallet markup (not a cost centre — a revenue line; see [`06-COMMERCIAL.md`](06-COMMERCIAL.md)).
- **Support labour** is the real scaling constraint: ~**1 Urdu-speaking rep per 60–100 active schools**. At pilot scale the owner does support.

**≈ Total fixed infra ≈ PKR 100k–160k/yr** — covered by roughly **4–6 small schools**.

## Break-even (illustrative — validate the assumptions)

Assume an average **net** license revenue of ~**PKR 35k/school/year** (after the messaging pass-through and modest support cost).

| Scenario | To cover | Schools needed |
|---|---|---|
| Owner self-builds | ~PKR 130k/yr fixed infra | **~4–6 schools**, then profitable |
| Hired build (~PKR 1.5M one-time) + infra | build + first-year infra | **~45 school-years** → e.g. ~45 schools in year 1, or ~25/yr over two years |

The market is enormous (hundreds of private schools **per city**), so the constraint is **not** demand — it is **onboarding + support throughput**, which is exactly why the plan standardizes install/training ruthlessly and defaults pilots to assisted data entry. Go deep in one city before spreading (see [`06-COMMERCIAL.md`](06-COMMERCIAL.md)).

## Risk-retirement order (why this sequence)
1. **Phase 0** kills the four project-enders (offline PWA, backup/restore, licensing, migrations) *before* feature investment.
2. **Fees + attendance first** (Phase 1) hit the owner's two deepest pains, so the pilot converts.
3. **Exams/certificates** (1.5) complete the paper-replacement story once the core is trusted.
4. **Scale features** (Phase 2) come only after one school proves the whole loop.
