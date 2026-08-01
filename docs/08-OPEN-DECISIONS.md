# 08 — Open Decisions (only the owner can make these)

The plan is opinionated and has a default/recommendation for everything. But a handful of choices are genuinely **yours** — they change what we build or how we sell. Here they are, each with our recommendation so you can just confirm or override.

| # | Decision | Options | Our recommendation |
|---|----------|---------|--------------------|
| 1 | **Product name / branding** | *Nizam* (placeholder) or your own brand | Pick a short, Urdu-friendly name early; it goes on every report, challan, and SMS sender ID |
| 2 | **Who builds it** | (a) Claude builds it here incrementally while you do the manual/business tasks · (b) you hire a dev/team and we spec for them · (c) you build with our help | **(a)** — matches how you framed this project and keeps cash build-cost near zero |
| 3 | **MVP scope** | (a) **Lean Pilot MVP** (fees + attendance + safety rails) first, exams/certificates as a fast-follow · (b) full v1.0 in one push | **(a)** — ships value in ~half the time and de-risks with a real pilot before the big build |
| 4 | **First thing after plan approval** | (a) detailed technical design (SQL schema, screen specs) · (b) a **clickable visual prototype** of the money screens (fee challan + attendance) to show pilot schools · (c) start building Phase 0 foundation | **(b) then (c)** — a prototype validates the look and wins the pilot before heavy build |
| 5 | **Desktop OS target** | Windows-only vs Windows + others | **Windows-only** for MVP — it's what these schools run; Tauri can add others later |
| 6 | **Admin UI language for MVP** | English admin UI (with Urdu on printed output + parent messages) vs full Urdu admin UI now | **English admin UI + Urdu output** for MVP; full RTL Urdu admin UI in Phase 2. Parents see Urdu; the 2–3 admin staff are fine with English |
| 7 | **Messaging: who pays** | School absorbs SMS/WhatsApp cost vs passed to parents (added to fee) | **Passed to parents** is normal here; confirm per school. Default alerts to **exceptions-only** |
| 8 | **Automated channel for MVP** | SMS now, WhatsApp later vs wait for WhatsApp | **SMS now** (only truly automatable channel on day one); WhatsApp Business API is a fast-follow |
| 9 | **Backup data residency** | Offshore encrypted (B2/R2, cheapest) vs in-country storage option | Start **offshore-encrypted** (we can't read it); offer an **in-country option** for privacy-sensitive schools |
| 10 | **Pilot school** | You have one ready vs need help finding one | Line up **one** friendly school before Phase 1 — the pilot is what turns the plan into a product |
| 11 | **Budget** | Confirm tolerance for ~PKR 100k–160k/yr fixed infra (whole fleet) + any hired-build cost | If self-building, infra is the only real spend and ~4–6 paying schools cover it |

## What we're explicitly deferring (not decisions for now)
- JazzCash/Easypaisa merchant integration → Phase 2, only if a pilot school asks.
- Parent mobile app → not planned; the read-only web portal + SMS/WhatsApp covers it far cheaper.
- Multi-campus consolidated reporting → schema supports it from day one; UI is Phase 3.
- Transport/library/inventory/hostel → built only on paying demand.

## How to respond
You don't have to answer all of these now. The four that gate our **next step** are **#2 (who builds), #3 (MVP scope), #4 (first thing to build), and #10 (pilot school)** — confirm those and we can move from plan to action. The rest can be settled during Phase 0.
