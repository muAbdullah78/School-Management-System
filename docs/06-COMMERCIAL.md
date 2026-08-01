# 06 — Commercial Model

All figures are 2026 PKR and illustrative — validate against your own costs and 3–4 real schools before locking a price sheet.

## Pricing: annual license + prepaid messaging wallet + optional onboarding

We **reject** two tempting models:
- **Pure one-time perpetual license** — cannot fund ongoing server/SMS/support cost, and is indefensible against copying.
- **Default monthly billing** — 12 collection events a year against cash-paying customers is a churn magnet.

We use an **enrollment-tiered annual license per campus**, billed on the academic calendar (when schools are flush with fee cash):

| Tier | Students | Annual license |
|---|---|---|
| Small | up to 300 | **PKR 25,000/yr** |
| Medium | 301–600 | **PKR 40,000/yr** |
| Large | 601–1,000 | **PKR 60,000/yr** |
| Enterprise | 1,000+ / multi-campus | Custom |

That is roughly **PKR 60–100 per student per year**. For a 500-student school collecting even PKR 1.5M/month in fees, the software costs **under one day's fee revenue for the whole year.** The pitch: *"One classroom's monthly fee, once a year, and your whole school stops running on registers."*

**Add-ons and levers:**
- **Onboarding/setup fee:** one-time **PKR 8,000–15,000** (remote install, admin training, initial data-import help). Waivable for pilots/first movers; otherwise it screens out tyre-kickers and funds the expensive first week.
- **Messaging wallet:** buy masked SMS at ~PKR 0.5–0.8, sell in bundles at ~PKR 1.0–1.3 (e.g. 10,000 SMS for PKR 12,000). Price WhatsApp lower to steer volume there. **The single biggest variable cost becomes a self-funding revenue line.**
- **Up-front discount:** ~15–20% off for full annual pre-payment vs a two-instalment plan (session-start + mid-session) to ease cash payers.
- **Free tier:** a genuinely capped wedge (attendance + student list, one class) for skeptics — a **market-entry tool, not a revenue line**.

## The honest all-in cost (the number the first draft hid)

The "one classroom's fee" pitch omits messaging. Here is the **realistic total** a school actually pays, with **exceptions-only** (absent/late) alerts as the default:

| School size | License | Est. messages/yr* | Messaging @ ~PKR 1.2 | **All-in / yr** |
|---|---|---|---|---|
| 300 students | 25,000 | ~7,500 | ~9,000 | **~34,000** |
| 500 students | 40,000 | ~13,000 | ~15,600 | **~55,600** |
| 1,000 students | 60,000 | ~26,000 | ~31,000 | **~91,000** |

\* *Assumes exceptions-only daily absentee alerts (~10% of roster × ~22 days × ~9 months) + defaulter/fee reminders + ~3 result blasts. Real volume depends on absence rate and how many blasts the school sends.*

**Two consequences we act on:**
1. **Messaging must default to exceptions-only** (never "all present" texts) and steer to WhatsApp once WABA is live, or the cost approaches the license fee.
2. **Who pays for messaging is an explicit decision** the owner makes at onboarding — many schools **add it to the fee** (pass-through to parents), which is normal here. This is item 10 on the client checklist.

## Cost discipline that makes "low cost" survivable
- **One shared multi-tenant control plane**, never a VPS per school.
- Daily alerts default to **exceptions-only, WhatsApp-first** once available.
- **~1 Urdu-speaking support rep per 60–100 active schools** is the true scaling limit → self-serve Urdu video + WhatsApp deflection is built in, and *making the software forgiving of load-shedding is itself the cheapest support strategy* (the environment stops generating calls).

## Deployment per school (near-zero travel)
Sign-up + tier + onboarding fee → instant cloud tenant + license key → **remote install of the standardized signed installer via AnyDesk** on 2–3 PCs → teacher app needs no install (PWA URL + QR) → **assisted, phased data import** from pre-formatted templates (identity/class first to go live on attendance, fees/arrears next) → one 60–90 min recorded **Urdu** remote training + an in-app setup wizard with sane Pakistani defaults. Standardize ruthlessly: same installer, same templates, same script every time. **Honest time-to-go-live: a few weeks including data prep**, not "under a week."

## Support
Built for low-literacy, Urdu-preferring, non-technical users, and designed to deflect from live humans: (1) in-app + WhatsApp **Urdu video library** for the 20 tasks that cause 80% of questions; (2) a per-school **WhatsApp support line** as the primary human channel; (3) phone callback + **AnyDesk** for hands-on fixes; (4) an internal ticket log feeding fixes and video updates. Proactive outreach at renewal and session start.

## Anti-piracy (summary — full detail in [`04-RISKS-AND-SAFEGUARDS.md`](04-RISKS-AND-SAFEGUARDS.md))
**The service is the product.** Messaging, backup, the teacher app, and updates require a valid per-school license that heartbeats (long offline grace, then read-only). Node-locked to hardware + identity; **enrollment-banded** so a hidden extra campus is detectable; reports watermarked; **no fully-offline perpetual build ever ships.** Crucially, **data export always works even on a lapsed license** — we defend revenue without holding anyone's data hostage.

## Go-to-market — go deep in one city first
- **Phase 1 (Pilot, ~1 term):** 1–3 friendly, respected schools in your home city, free/steeply-discounted for a term in exchange for weekly feedback + a case study + an **owner video testimonial**. Harden offline attendance, fee/arrears logic against real chaos. Lead with the highest-pain modules — **attendance + fees** — then expand the same school into exams and reporting.
- **Phase 2 (Referral engine):** owners trust peers over salespeople — referral incentives (free months / free SMS credits both ways). Sell hardest in the **pre-session window (Feb–April)** when owners budget and re-enrol.
- **Phase 3 (City domination):** saturate ONE city (feet-on-street demos, WhatsApp walkthroughs, private-school-owner-association seminars) before the next. Expand only once support staffing and the standardized onboarding playbook can absorb the load.

**Health metrics to watch:** pilot-to-paid conversion · renewal rate · referrals per school · SMS-wallet top-up frequency · support tickets per school per month (the number that decides whether you can scale).
