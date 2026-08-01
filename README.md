# School Management System — for Pakistani Private Schools

> **Working name:** *Nizam* (نظام — "system / order"). This is a placeholder; final branding is the owner's decision (see [`docs/08-OPEN-DECISIONS.md`](docs/08-OPEN-DECISIONS.md)).

A management system built for how **privately-owned Pakistani schools actually run** — power load-shedding, cash fees and bank challans, WhatsApp/SMS parents, Urdu, arrears and discounts, and BISE boards — sold affordably to one school at a time.

The product is **one system with two faces**:

1. **A desktop application** for the owner / headmaster and 2–3 admin staff — the school's single source of truth: admissions, the full fee engine (challans, discounts, arrears, receipts), student profiles that span every year, exams, result cards, certificates, and a "where did every rupee go" owner dashboard.
2. **A live web app** used daily by teachers on their own phones — mark attendance and enter test/exam marks in seconds, offline-first, syncing instantly into the same student profile the owner sees.

When a teacher finalizes attendance, the day's sheet is produced for the headmaster and absentee alerts go to parents automatically — in **Urdu**, over the channels parents actually use.

---

## This repository is currently a PLAN, not code

Per the project owner's instruction, the first deliverable is a **complete strategy and plan** — research, architecture, data model, feature map, risk analysis, roadmap, commercial model, and a step-by-step list of what the owner must provide. **No application code has been written yet.** Building begins only after the plan is reviewed and the open decisions are settled.

## Read the plan in this order

| # | Document | What it covers |
|---|----------|----------------|
| 00 | [Overview & Vision](docs/00-OVERVIEW.md) | The product in plain language, why it wins, how the pieces fit |
| 01 | [Architecture & Tech Stack](docs/01-ARCHITECTURE.md) | The one architecture, the diagram, the stack, and the hard technical decisions |
| 02 | [Data Model](docs/02-DATA-MODEL.md) | Entities and the four rules that make a child's history un-destroyable |
| 03 | [Feature Map](docs/03-FEATURES.md) | Every module, MVP vs later, and **everything the owner's brief missed** |
| 04 | [Risks & Safeguards](docs/04-RISKS-AND-SAFEGUARDS.md) | The red-team findings and how the design defeats each — fraud, data loss, piracy, privacy |
| 05 | [Roadmap](docs/05-ROADMAP.md) | Phases, effort estimates, timeline, and break-even math |
| 06 | [Commercial Model](docs/06-COMMERCIAL.md) | Pricing in PKR, honest all-in cost, anti-piracy, go-to-market |
| 07 | [What We Need From You](docs/07-CLIENT-CHECKLIST.md) | The step-by-step checklist of manual tasks for the owner |
| 08 | [Open Decisions](docs/08-OPEN-DECISIONS.md) | The handful of choices only the owner can make before we build |

## The one-sentence bet

> There is **exactly one authoritative database per school**, living on the headmaster's PC on the school's own network; the desktop app and the teacher web app are both just clients of it. This single decision removes the biggest source of bugs and cost in projects like this (bidirectional sync between two databases), and makes the system keep working when the internet and the power are gone — which, in Pakistan, is most of the day.

## How this plan was produced

The plan is the output of a structured research effort: seven parallel specialist analyses (domain/operations, competitor market, feature completeness, architecture, data model, an adversarial red-team, and commercial strategy), synthesized and then **torn apart by a skeptical reviewer** whose findings are folded into these documents. Where the first draft over-promised, the documents say so plainly.
