# 04 — Risks, Loopholes & Safeguards

The owner asked us to *criticise everything* and catch the loopholes before they cost time. This document is the adversarial red-team's findings, each turned into a concrete design **guarantee**. It also lists, honestly, the places where the first draft **over-promised** — because a plan that hides its weak points is the most expensive kind.

Severity: 🔴 critical · 🟠 high · 🟡 medium

---

## 🔴 Total data loss — headmaster's PC dies / stolen / ransomware / theft
**Scenario:** the one PC holding the school's whole life dies. Paper is gone; so is the digital copy.
**Guarantee:** the local DB is **never the sole truth**. Default-on **continuous encrypted cloud backup (Litestream)** + scheduled **USB backup** + a **"last backup: X days ago"** banner that turns red after 48h. Backups are **verified** (checksum + trial-open); multiple generations kept. We monitor backup health centrally so *we* know who is unprotected before disaster strikes.
**The fix the review forced — key escrow.** An encrypted backup is worthless if the only decryption key died with the PC (or is a password the owner forgot). So each school's backup key is **escrowed in the control plane** (or split via a recovery code we hold), enabling an **assisted restore**. Onboarding tests the **full "PC destroyed → restore onto a fresh machine"** path, not just a restore into a scratch DB on the same PC.

## 🔴 Piracy — one license copied across a whole chain
**Scenario:** a school buys once and copies the desktop app to three campuses. Business-model killer.
**Guarantee:** **the service, not the file, is the product.** SMS/WhatsApp delivery, cloud backup, the teacher web app, and updates all require a valid **per-school license** that heartbeats periodically (long offline grace, then read-only). Node-locked to hardware + school identity; **enrollment-banded** so a bigger hidden campus is detectable by student count + sync fingerprint; reports are **watermarked** with school name/license ID. We **never ship a fully-offline, no-server perpetual build** — the only truly copyable configuration, which is also the unsustainable pricing model. Avoiding it fixes piracy and economics at once.

## 🔴 Desktop/web divergence & multi-master corruption
**Scenario:** two databases drift; a teacher's marks land on a deleted student; "last write wins" eats a day of data.
**Guarantee:** **dissolved, not mitigated.** One authoritative SQLite DB per school on the LAN; desktop and web are live clients. No bidirectional sync, no last-writer-wins on money/marks. Multiple desktop installs = extra *clients* of the one server (enforced + documented), never a second DB. **Honest mechanism** (not "impossible by construction"): the teacher offline buffer is naturally partitioned by `{class, section, date}`, **and** the server enforces **row-versioning with stale-write rejection + finalize-and-lock**; after lock, the only mutation is a logged, reasoned correction.

## 🔴 Fee skimming / clerk theft
**Scenario:** the owner's deepest fear — *"did my clerk record every rupee?"*
**Guarantee (two layers, because they catch different frauds):**
- *Under-recording of entered payments:* append-only fee ledger; **gapless sequential receipt numbers** (a gap is a visible red flag); every entry stamps user + time + device; reversals/discounts require a reason and an **owner-PIN** above a threshold; role separation (clerks collect, cannot void); **daily "cash expected vs collected"** reconciliation; and an **SMS receipt to the parent that turns the parent into the fraud auditor.**
- *Cash that was never recorded at all* (the review's catch — the controls above can't see money that never became an entry): **expected-vs-collected reconciliation** compares the **billed roster to collections** each challan run, and an **enrollment-vs-fee-roll cross-check** surfaces students who are enrolled but never billed (ghost/off-book students). This is foregrounded on the owner dashboard.

## 🔴 Audit log & anti-fraud integrity — the over-sold claim, fixed
**Scenario:** the append-only ledger lives in a SQLite file on a PC the *very clerk being policed* controls. A tech-savvy staffer opens it in a free SQLite editor, rewrites payments/marks and the "append-only" log, and lets the tampered state stream to backup.
**Guarantee — tamper-*evident*, not "impossible":** **hash-chain** the audit and financial records and **periodically anchor the chain hash to the cloud control plane**, so any out-of-band edit becomes **detectable**; encrypt the DB at rest with **SQLCipher** (key released by the licensed app, not sitting beside the file); **reconcile local state against the immutable cloud backup**. Marketing language is downgraded from "impossible to tamper" to **"tamper-evident."**

## 🟠 Marks / attendance tampering & backdating
**Guarantee:** lock-after-finalize with a short grace window; post-lock changes are **logged corrections** with reason + approver; edit history visible on the profile ("45 → 78 by Teacher X on date"); owner exception report of post-lock changes; timestamp/device tagging surfaces "marked at 6am from an unknown device."

## 🟠 Privacy — minors' data over SMS, wrong numbers, no consent
**Guarantee:** **one-time opt-in verification** of each parent number before alerts; **content minimization** ("Your child was marked absent today — contact school", *not* name + class + details); per-channel opt-out; every message logged; bilingual consent collected at admission; PII **encrypted at rest and in transit**; a **data-processing agreement** (school = controller, we = processor); retention + "delete this school's data" procedures; a breach-response plan. This is also a **sales asset**: *"we protect your students' data."*

## 🟠 Update distribution to hundreds of offline installs
**Guarantee:** resumable **delta** auto-updates; **staged 5% → wider rollout with auto-rollback** on failed launch; **transactional, reversible** schema migrations snapshotted before running; the Tauri shell and backend sidecar are **version-pinned to update atomically**; a "current version" beacon shows stale installs.

## 🟠 Academic-year rollover corrupts the roster
**Guarantee:** an explicit, reviewable, **reversible** workflow — preview before commit; explicit status handling (promote / retain / graduate / left / struck-off); arrears carried as opening balances; a **DB snapshot for undo**; owner-only permission.

## 🟠 Shared weak passwords
**Guarantee:** enforced **per-user accounts** + roles + least privilege; non-trivial passwords; auto-lock/timeout; deactivate-on-exit; every audited action stamps the individual.

## 🟠 Messaging total cost quietly undercuts "low cost"
**Scenario:** "one classroom's fee, once a year" omits messaging cost — which for a 500-student school can approach the license fee.
**Guarantee:** we publish an **honest all-in TCO** (license + realistic annual messaging) for 300/500/1000-student schools in [`06-COMMERCIAL.md`](06-COMMERCIAL.md); default hard to **exceptions-only** alerts; make **who bears the cost** (school vs parent) an explicit sales + onboarding decision; and **cap/alert on wallet burn**.

## 🟠 Onboarding data entry is the real pilot-killer
**Scenario:** asking a non-technical owner to hand-fill a 15-column sheet for 500 students, self-service, stalls the pilot for weeks.
**Guarantee:** **assisted data entry is the default for pilots, not an upsell**; a **phased import** (identity + class/section first → go live on attendance; fees/arrears next); "time to go live" is honestly baselined in **weeks including data prep**, not "under a week."

## 🟠 Parent-alert channel was internally inconsistent
**Scenario:** the draft named WhatsApp as the "automatic primary," but WhatsApp automation needs Meta Business verification (weeks) and per-conversation cost, and a click-to-chat *deep link* cannot be automated at all.
**Guarantee:** **SMS is the automated channel for MVP.** WhatsApp automation (WABA) is a scheduled fast-follow with its verification lead time and per-message cost budgeted in; until then WhatsApp is a manual deep-link only. The flagship feature never launches on an unresolved channel.

## 🟠 Control plane single point of failure
**Guarantee:** **decouple licensing from relay uptime** (long offline grace, so a relay outage never locks a paying school); managed/redundant queue + object storage for relay and backups; **warm standby + monitoring/alerting**. Enforcement lives in the signed local app, not an always-on server call.

## 🟡 Local PC theft exposes the whole DB
**Guarantee:** **encrypted local DB (SQLCipher) + encrypted backups** (per-school key not stored in plaintext beside the DB); login required to open the app; **remote-revoke** so a stolen install's license/keys are invalidated.

## 🟡 Offline durability window on teacher phones
**Guarantee:** flush **immediately/opportunistically** on any LAN reachability; explicit **"N unsynced entries"** warning that blocks risky actions; server-side draft autosave the instant any connectivity exists; the residual loss window is **documented, not hidden**.

## 🟡 Data ownership on non-renewal (data-hostage risk)
**Guarantee:** **full data export (Excel/CSV + PDF archives) always works, regardless of license state.** *"Your data is always yours, even if you stop paying"* is an explicit sales asset — vital in a referral-driven, trust-based market.

## 🟡 Fee logic complexity (arrears, stacked discounts, pro-rata, refunds)
**Guarantee:** fees as a configurable per-student ledger + a rules-based discount engine; arrears explicit and always visible; pending-vs-verified status for challan/wallet reconciliation (import bank-statement CSV, match by challan reference); no arrears alert fires against a recent pending payment. **Validated against 3–4 real schools' fee sheets before building.**

## 🟡 Urdu rendering / printing breaks reports
**Guarantee:** **bundle Noto Nastaliq** with the installer (never trust the OS); real RTL/complex-text shaping; **generate PDFs** for predictable layout; test on the cheap inkjet/thermal printers and old Windows versions schools actually use; native-Urdu proofing of every template.

## 🟡 Data residency vs the privacy pitch
**Scenario:** streaming minors' PII to offshore B2/R2 contradicts an "in-country storage" claim.
**Guarantee:** offer an **in-country storage option**, or be explicit with schools about **where** encrypted backups reside; lean on the **encryption-at-rest / we-can't-read-it** story; keep the data-processing agreement **honest about location** rather than implying local residency.

## 🟡 LAN reachability in classrooms
**Guarantee:** **static IP / mDNS hostname** so the teacher URL never changes; a **QR/bookmark** for one-tap access; honest expectation that weak-WiFi classrooms mark in the staffroom post-class (still offline-buffered); **WiFi coverage is a pre-install checklist item**.

## 🟡 Report scale on weak hardware
**Guarantee:** indexed by student+date and class+date; precomputed monthly/yearly rollups; streamed/paginated **background** PDF generation; **load-tested with 1,000 students × 5 years on deliberately weak hardware**.

## 🟡 Date / calendar edge cases poison multi-year queries
**Guarantee:** explicit PKT timestamps; a **per-school academic-year boundary** drives all rollups; a holiday calendar (weekends + Eid/Ramadan) excludes closed days from attendance denominators; the "query 3 years ago" path tested with seeded multi-year data.

## 🟡 No fleet-wide monitoring
**Guarantee:** a lightweight **central telemetry dashboard** — each install beacons version, last-backup status, and PII-free error reports; incident runbooks for the top failure modes; a rollback plan for every release.

---

### The one-line honesty summary
The single-authoritative-LAN-database bet genuinely removes the class of bug that kills projects like this. The two places to **not** over-promise are (1) audit/anti-fraud — it is **tamper-evident**, not tamper-proof, because the DB sits on a machine staff control — and (2) backup — it is only real once **key escrow** and the **full dead-PC restore** are tested. Both are now first-class Phase-0 requirements.
