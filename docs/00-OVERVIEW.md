# 00 — Overview & Product Vision

## The problem, in the owner's own words

Today the target school — a privately-owned Pakistani school running anywhere from Play Group up to Matric (Class 10) or Intermediate (Class 12), with a few hundred to a thousand students — runs its entire life on **paper registers**. Admissions, monthly fees, arrears, daily attendance, weekly tests, term exams, result cards: all of it lives in notebooks that get lost, copied wrong, or quietly manipulated.

The owner has **two deepest anxieties**, and the whole product is built around them:

1. **Money.** *"Who owes me fees, and did my clerk actually collect and record every rupee?"*
2. **Trust.** *"I can't be everywhere — what are my staff actually doing?"*

Everything else — nicer report cards, tidy student profiles — is secondary to those two. A design that forgets this builds a pretty database nobody pays for.

## The solution: one system, two faces

### 1. The desktop application (owner / admin)
The school's **single source of truth**, operated by the owner/headmaster and 2–3 trusted admin staff:
- Admissions and lifelong student profiles
- The **fee engine**: fee heads, monthly challan generation, arrears carry-forward, partial payments, fines, discounts, refunds, defaulter lists, receipts, daily cash reconciliation
- Teacher/staff records
- Exams, grading, result cards, certificates
- The **owner dashboard**: today's collection vs dues, defaulters, cash position, and the backup-health light

### 2. The live teacher web app (daily use)
A lightweight app teachers open on **their own phones**:
- Mark daily attendance in seconds (offline-first — a dead WiFi moment never loses a class's data)
- Enter daily/weekly/monthly test marks and term-exam marks
- Everything flows instantly into the same student profile the owner sees

The single most important adoption rule: **the teacher app must be faster than the paper register.** If it is even slightly slower, teachers abandon it and the whole promise collapses.

### 3. Automatic parent communication
When attendance is finalized, the system produces the day's sheet for the headmaster and sends **absentee alerts to parents automatically, in Urdu**, over the channels this market actually uses (SMS as the automated backbone, WhatsApp as it comes online). Parents in this market largely do **not** use email — so email is only ever a fallback for the *owner's* reports.

## Why this wins — the market gap

We surveyed the competitive field. The defining insight:

> **No competitor delivers all five things the target school needs at the same time.**

| Competitor type | What they have | Why they fail this school |
|---|---|---|
| Cheap offline desktop tools (the local incumbent, ~tens of thousands of installs) | Low price, works offline | No live teacher app, no safe/automatic backup, no cloud reach, dated |
| Cloud SaaS (eSkooly, CapoBrain, Fedena, and similar) | Modern web, nice UI | **Die the moment power/internet drops** (most of a Pakistani school day); per-student monthly fees; weak on real Pakistani fee/arrears/BISE workflows |
| Open-source (OpenSIS, Gibbon, RosarioSIS) | Free, capable | Need an IT department nobody in these schools has; no Urdu, no local SMS, no local support |

**Our opening is the union nobody occupies:**

> Offline-first desktop source-of-truth **+** a live teacher web app **+** SMS/WhatsApp-first **Urdu** parent comms **+** genuinely Pakistani fee/exam/arrears/BISE workflows **+** automatic, verified backup — sold once a year at a price any private school can afford.

**Positioning line for the owner:**
> *"The school system built for how Pakistani schools actually run — power cuts, cash fees, WhatsApp parents, Urdu, and BISE — at a price any private school can afford."*

## The single architectural bet (why it matters even here)

The hardest stated requirement is: keep the desktop admin app and the live teacher web app *consistent*. The naive design uses **two databases that sync** — and that is exactly where projects like this die: duplicate students, marks written to deleted records, a teacher's whole day silently overwritten by "last write wins." **Money and grades are the two things you must never auto-merge.**

We **dissolve** the problem instead of solving it: **one authoritative database per school** on the school's own LAN; the desktop app and the teacher web app are both live clients of it. No second database, no bidirectional sync engine, no conflict-resolution nightmare. The internet is used only for things that *tolerate delay* — sending messages, off-site backup, licensing, updates — served by one small shared cloud "control plane" amortized across all schools.

Full detail in [`01-ARCHITECTURE.md`](01-ARCHITECTURE.md).

## What "professional and modern" means here (and what it doesn't)

The owner asked for modern, professional work — not cheap or old-school. In *this* market, "modern" does **not** mean a flashy cloud-only SPA that needs perfect internet. It means:
- **Resilient**: works through load-shedding and dead internet, because that is the environment.
- **Trustworthy**: append-only money/marks ledgers, a tamper-evident audit trail, verified backups — the features that protect the *owner*.
- **Respectful of reality**: Urdu output, cash and challan workflows, arrears and discounts, cheap printers, 4 GB office PCs.
- **Honest**: this plan flags where the first draft over-promised (see [`04-RISKS-AND-SAFEGUARDS.md`](04-RISKS-AND-SAFEGUARDS.md)). A plan that hides its own weak points wastes the owner's time later — exactly what we were asked to prevent.

## Where to go next
- The engineering picture → [`01-ARCHITECTURE.md`](01-ARCHITECTURE.md)
- What actually gets built, and what the brief missed → [`03-FEATURES.md`](03-FEATURES.md)
- When, in what order, and what it costs to build → [`05-ROADMAP.md`](05-ROADMAP.md)
- What the owner must do → [`07-CLIENT-CHECKLIST.md`](07-CLIENT-CHECKLIST.md)
