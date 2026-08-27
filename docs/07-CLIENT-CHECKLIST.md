# 07 — What We Need From You (the Owner)

> ## ⚠️ Historical — a pre-build pilot checklist
>
> Written before anything existed, to line up one pilot school. Several items are
> now settled or gone: the product name, the SMS decisions, and the per-school
> hosting setup. The **data-gathering** items are still exactly right, and are the
> fastest way to onboard any school — the fee structure, the class ladder, and
> blank samples of the school's own challan and result card.
>
> For what a school does once it has the software, see
> [`GUIDE.html`](GUIDE.html). For what YOU still have to do, run
> `psql -f supabase/verify.sql`.

These are the concrete, manual things **only you** can provide or do so we can build and launch. Treat it as a checklist. **The pilot cannot start until items 1–10 are done.** Nothing here is technical — it's information about your school and a few business decisions.

> Good news on the hardest one: **you do *not* have to type in hundreds of students yourself.** For the pilot, assisted data entry is included (see item 8). And we import your data in **stages** — students + classes first (so attendance goes live fast), fees and arrears next.

---

### The pilot (do these first)

1. **Pick ONE pilot school.** A friendly, respected private school in your home city (ideally your own, or one whose owner trusts you), ~200–600 students, willing to give weekly feedback for one term in exchange for a big discount and a video testimonial. Send us the owner's name and WhatsApp number.

2. **Gather blank sample documents from that school.** Physically collect and photograph/scan: (a) a **blank admission form**, (b) a **blank fee challan/voucher** (all copies — school/bank/parent), (c) a **cash fee receipt**, (d) a **printed result card / DMC**, (e) a **school leaving certificate**, (f) an **ID card**. These define exactly what our printed outputs must look like.

3. **Provide the class ladder.** Write the school's exact class list bottom to top (e.g. Play Group, Nursery, Prep, Class 1 … Class 10), the **section names** used in each (A/B, colours, gender), and whether the school runs **separate morning/evening shifts**.

4. **Provide the full fee structure.** For each class, list every fee head and amount: monthly tuition, admission fee, security deposit, annual charges, exam fee, and any others (lab, computer, transport, generator fund). State the **due date** (e.g. 10th of the month) and the **late-fine** rule.

5. **Provide the discount/concession rules.** The school's actual policy: sibling discount (e.g. 2nd child 10%, 3rd 25%), merit/scholarship, staff-child concession, hardship/free students — exact percentages/amounts, and **who is allowed to approve each**.

6. **Provide the exam & grading structure.** The term structure (e.g. 1st term / mid / final), how they weight toward promotion, the **passing mark** (33% or 40%), and which **grade scale** the school uses (old A1/A/B or the new BISE 10-point/GPA). Confirm whether the school wants **class positions/rank** printed.

7. **Provide the class/section → teacher map and the staff list.** A simple sheet: each teacher's name, mobile number, which section they are class-teacher of, and which subjects they teach in which classes. Include non-teaching staff (clerk, accountant) who will use the desktop app.

8. **Provide the current student list (for the phased import).** We'll give you a **pre-formatted Excel template**. Fill it with all *current* students: name, father's name, B-Form number, DOB, gender, class, section, roll number, guardian mobile number(s), current fee slab + any discount + **current outstanding arrears (opening balance)**. **Do NOT enter years of back-history** — only current students + opening arrears, so we go live fast. **If typing this is a burden, hand us the school's registers/photos and our team will do the data entry for the pilot.**

9. **Collect and clean parent phone numbers.** For every student, at least one working mobile number; mark the **primary WhatsApp number** and the family's **language preference (Urdu / Roman Urdu / English)**. Wrong numbers are a privacy risk, so please have someone verify them.

10. **Decide budget and confirm the messaging plan.** Confirm the annual tier and whether you'll pre-pay in full (for the discount). Decide **who absorbs the SMS/WhatsApp cost — the school, or passed to parents** (many schools add it to the fee — this is normal). If you want a **masked/branded SMS sender ID** (your school's short name), start the PTA/gateway registration now, as it takes time — we'll launch on WhatsApp deep-link + unmasked SMS meanwhile.

---

### Accounts & hardware

11. **Register a business SMS gateway account.** Open a **business bulk-SMS** account with a Pakistani gateway (e.g. a registered bulk-SMS/branded-SMS provider) — a **consumer SMS bundle cannot be used** for automated sending. For WhatsApp automation later, we'll guide you through a WhatsApp Business API (WABA) provider and the Meta Business verification (it takes a few weeks — start early if you want it).

12. **Confirm the "server" PC and its power backup.** Tell us the make / RAM / Windows version of the PC that will be the school's main server PC, and confirm there is a **UPS or inverter on that PC and the WiFi router** — this is **mandatory**; without it, load-shedding takes the whole system down. If the PC is too old, budget ~PKR 25–40k for a cheap mini-PC we can recommend.

13. **Confirm classroom WiFi coverage.** Tell us whether the school WiFi reaches the classrooms. If it doesn't, teachers will mark attendance in the staffroom right after class (still works offline) — we just need to set expectations. Consider a cheap WiFi extender for weak spots.

---

### School identity & rules

14. **Provide school profile assets.** The school's logo (high-resolution), full legal name (English **and** Urdu), address, phone, principal's name, and a scan of the **principal's signature and the school stamp** for result cards and certificates.

15. **Provide the holiday calendar.** The weekly off-day(s) and the list of declared holidays (including Eid/Ramadan closures) so attendance percentages are calculated correctly.

16. **Nominate operators and approvers.** Which 2–3 staff will operate the desktop app, and confirm that **only you (or the principal) will hold authority** to grant discounts, waive fines, void receipts, and unlock marks/attendance — so we set permissions correctly from day one.

17. **Sign off on the go-live checklist.** Before launch we run a validation ("every class has a fee slab, every student has a section, every teacher has a login") and a **test backup-and-restore onto a fresh machine**. You confirm the pilot school will run the software **in parallel with paper for two weeks**, then commit to dropping paper for the core areas (attendance, fees) — keeping paper longer for fees is fine if you're nervous.

---

### A note on effort
Items 1–7, 14, 15 are a few hours of writing things down. Items 8 and 9 (student + phone data) are the biggest effort — and we've made them **assisted and phased** precisely so they don't stall your pilot. Everything else is a decision or an account signup. Do these, and we can move from plan to a working pilot.
