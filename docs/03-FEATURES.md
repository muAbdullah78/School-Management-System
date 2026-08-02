# 03 — Feature Map (and everything the brief missed)

> **Note:** [`09-DECISIONS-LOCKED.md`](09-DECISIONS-LOCKED.md) supersedes parts of this doc — the **Communication Engine** module is dropped (WhatsApp is now a manual click-to-chat link, not an automated system) and there is **no Urdu** (English-only UI and output). Everything else stands. Scope is **full v1.0**, not a lean MVP.

**⚠️ MISSED** marks a feature the owner's brief did **not** ask for but that is essential. These are the "loopholes" we were hired to catch — a system without them breaks within a term or gets an owner defrauded.

A skeptical review flagged that the first-draft "MVP" was secretly a full v1.0. We have **split it**: a genuinely lean **Pilot MVP** that a school can run on quickly, and a **Fast-follow (v1.0)** that completes the exam/certificate story. See [`05-ROADMAP.md`](05-ROADMAP.md) for effort and sequencing.

---

## Tier 1 — Pilot MVP (a pilot school runs its core operation on this)

The cut is deliberate: the two highest-pain areas (**fees** and **attendance**) plus the safety rails (**backup, roles, audit**). Exams and certificates come in the fast-follow.

### Admissions & Enrollment
Enquiry/lead capture ⚠️ · admission form (bio-data, DOB, **B-Form not CNIC** for young children ⚠️, photo, multiple guardians & phones) · auto-generated **Registration No vs lifelong GR Number** ⚠️ · class + section assignment with seat check · admission-time fee & discount setup · **mid-year transfer-in admission** ⚠️ · **sibling detection & linking at intake** ⚠️ · document checklist ⚠️ · print admission slip.

### Student Information System (the lifelong profile)
The owner's flagship. Consolidated bio-data + guardians · **full academic history across all years** · attendance rollups (daily→monthly→yearly) · fee ledger · sibling/family view · **explicit lifecycle states — active / struck-off / withdrawn / graduated / re-admitted** ⚠️ · timeline/audit view · fast **offline** search by name / GR / roll / phone.

### Academic Structure
**Configurable ordered class ladder** (never a hardcoded enum) · sections (A/B, colours, gender, shift) · **subjects per class** ⚠️ · **streams/groups for 9–12** ⚠️ · **morning/evening shift as a first-class partition** ⚠️ · class-teacher & subject-teacher assignment.

### Fee Management & Discounts — *the #1 reason to buy*
Configurable fee heads (admission, monthly tuition, **security deposit as a refundable liability** ⚠️, exam, annual charges, lab/computer, transport, **generator surcharge**, misc) · class/student fee slabs · **monthly challan generation** in bank-payable **3-part format** ⚠️ · **arrears carry-forward** with explicit brought-forward ⚠️ · **partial payments** ⚠️ · **fines/late fees, waivable with reason** ⚠️ · **defaulter list as a first-class workflow** ⚠️ · discounts (sibling/merit/staff-child/hardship/scholarship) as **approvable, reasoned, audited records** with a **discount register** ⚠️ · **refunds & adjustments** ⚠️ (security deposit on withdrawal, overpayment) · **duplicate receipt reprint, same number** ⚠️ · **gapless auditable receipt numbering** ⚠️ · **daily cash-book reconciliation** ⚠️ · **pending-vs-verified** status for bank-challan / JazzCash / Easypaisa reconciliation ⚠️ · **expected-vs-collected + ghost-student check** ⚠️ (catches cash that was never recorded — see the fraud note below).

### Student Attendance (teacher web app) — *flagship*
Daily marking (present / absent / leave / late / half-day) · **auto-save + offline-first** ⚠️ · bulk "all present + flag exceptions" for speed · monthly/yearly rollups · **holiday-calendar-aware %** ⚠️ · **finalize/lock with correction audit** ⚠️ · auto-generated attendance sheet · **same-day absentee alerts, distinct from the daily summary** ⚠️ · chronic-absentee report.

### Communication Engine ⚠️ (brief asked only for attendance auto-send)
Absentee alerts · fee reminders · defaulter notices · announcements · holiday/emergency notices · **Urdu + Roman-Urdu low-literacy templates** with variable substitution ⚠️ · multiple parent numbers + primary contact + **language preference** ⚠️ · **delivery-failure log & retry** ⚠️ · **per-message cost + credit-balance visibility** ⚠️. **MVP automated channel is SMS**; WhatsApp automation is a fast-follow (see [`01-ARCHITECTURE.md`](01-ARCHITECTURE.md)).

### Users, Roles & Permissions ⚠️
Owner / headmaster / admin-clerk / accountant / class-teacher / subject-teacher / read-only, **least-privilege with separation of duties**: a clerk collects but cannot discount / void / change marks; a teacher is scoped to **their own sections/subjects only**; **revoke login when staff leave** ⚠️. Closes the "everyone is admin" loophole.

### Audit Log & Data Integrity ⚠️
Append-only, **tamper-evident** (hash-chained + cloud-anchored) journal of every money / marks / attendance / discount / permission change — actor, before→after, reason, timestamp, device. Owner-only audit report. **Void/cancel instead of hard-delete** for financial records. This is what protects the *owner* from staff fraud — a headline selling point.

### Backup, Restore & Data Migration ⚠️
Automatic local backup on every close + continuous encrypted cloud backup with **key escrow** ⚠️ (so a dead PC is still recoverable) · **verified backups** (checksum + trial-open) · a red **"last backup X days ago"** banner · **tested one-click restore during onboarding**, including the full *"PC destroyed → restore onto a fresh machine"* path ⚠️ · **Excel/CSV bulk import** for onboarding paper registers with validation & de-duplication · **full data export that always works, even on an expired license** ⚠️.

### Owner Dashboard ⚠️
The **daily landing screen**, built around *trust and verification*, not pretty charts: today's attendance %, fees collected vs due, defaulters, cash position, **expected-vs-collected exceptions**, and **last-backup age**.

### Basic Staff Records ⚠️
Staff profiles (teaching + non-teaching), designation, join/leave, and the **link between a staff record and the teacher's web-app login**. Full HR/payroll is Phase 2.

### Settings / School Profile / Session ⚠️
Config-driven so one codebase fits hundreds of schools: profile & logo, session/term definitions, fee heads, grade bands, discount types, numbering formats (GR / receipt / challan serials), holiday calendar, and **per-school feature toggles**. Hardcoding any of this creates per-sale rework.

### Licensing, Install & Deployment (product ops) ⚠️
Per-school license/activation with heartbeat + **long offline grace** · standardized signed installer · auto-update · trial/demo mode · per-school data isolation · **multi-install = extra admin *clients* pointing at the one server, never multiple DBs** · remote diagnostics · onboarding checklist.

---

## Tier 2 — Fast-follow (completes v1.0)

### Assessment — Daily/Weekly/Monthly Tests (teacher web app) ⚠️
Fast keyboard-friendly **offline** mark grid · absent-in-test handling ⚠️ · **weightage/aggregation into the term result** ⚠️ · **lock + audit of mark edits** ⚠️ · best-of / drop-lowest options.

### Examinations & Result Cards
Exam/term setup (1st / mid / 2nd / final / pre-board) · **date sheet** ⚠️ · **admit cards / roll-number slips** ⚠️ · per-subject max/pass/practical marks · marks entry · **class & section RANK** ⚠️ (boards abolished positions but parents still demand them — make it a **toggle**) · **tabulation/consolidation sheet** ⚠️ · result card / **DMC** with logo & signatures · pass/fail/promotion · **"result withheld for fee defaulters"** ⚠️ (a key local lever) · bilingual cards · bulk print · result SMS.

### Gradebook & Grading Scheme ⚠️
**Admin-configurable grade bands**, shipping both presets: traditional **A1/A/B…F (33% pass)** *and* the new **BISE/IBCC 10-point + GPA (40% pass)** rolling out 2025–26 · grace-marks with logging ⚠️ · weighting model.

### Certificates & Documents ⚠️ (badly under-specified in the brief)
**School Leaving / Transfer Certificate** (with **serial tracking to prevent duplication/fraud** ⚠️) · Character Certificate · Bonafide · fee receipts & duplicates · result cards/DMC · admit cards · date sheets · **student & staff ID cards with QR** ⚠️ · customizable bilingual templates · batch printing. Automating these frequent manual documents is a **top-3 selling point**.

### Promotion & Academic-Year Rollover ⚠️
Unavoidable — breaks the product within 12 months if missing. Create/close session · **preview-then-commit, reversible** bulk promote/detain · new sections & roll numbers · **arrears carried across the year boundary** · archive prior year (still queryable) · mark Class 10/12 as alumni · **DB snapshot before rollover for undo** · owner-only permission.

---

## Phase 2 — Deepen operations & reach
Timetable & period scheduling with substitution ⚠️ · staff attendance & leave ⚠️ · **accounting, expenses, salary & payroll with payslips** ⚠️ · read-only **parent portal** (low-bandwidth) ⚠️ · **WhatsApp Business API** full automation · bank/wallet **statement-import reconciliation** + optional JazzCash/Easypaisa merchant callbacks · masked/branded SMS once PTA approval lands · full **RTL Urdu admin UI** (MVP ships an English admin UI with **Urdu on printed outputs and messages**, which matters more to parents) ⚠️ · **central fleet telemetry** (version + backup health across all schools).

## Phase 3 — Growth & optional modules
Front-desk lead management ⚠️ · discipline/behaviour + homework-diary ⚠️ · transport (routes/vehicles/fees; a fee hook exists from MVP) ⚠️ · multi-campus **consolidated owner reporting**.

## Later — long-tail add-ons (built only on paying demand)
Library · inventory/assets + uniform/book-shop · full health module · hostel/boarding.

---

## The headline "you missed this" list (for the owner)
Offline-first attendance capture · academic-year rollover · backup/restore + paper-register import · the certificates suite · fee **refunds/fines/defaulter** management · class **rank + tabulation + grading-scheme config + result-withheld** · **roles/permissions** granularity · **audit log** · staff attendance/payroll · **licensing + multi-install + data isolation** · a communication **engine** (not just absentee texts) · **sibling linking + student lifecycle states** · the **owner dashboard + data export** · **bilingual printed output** · and the anti-fraud control that matters most: **expected-vs-collected reconciliation + ghost-student detection**, which catches cash a clerk *never recorded at all* (gapless receipts and parent SMS only catch under-recording of payments that *were* entered).
