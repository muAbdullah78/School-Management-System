# Two-year simulation: findings

Written as they were found, against the real schema (117 migrations, 68 tables,
330 functions) on a local Postgres 16 with a signed-in owner's session and Row
Level Security enforced. Nothing here is theoretical: each entry names how it
was reproduced.

Numbers refer to the simulated school **Chaudhary Puclix High School Ghauriii**,
February 2024 to today, built by `supabase/sim/run.sh`.

---

## F1. A payment has no business date, so yesterday's cash cannot be entered today

**Severity: high. This one will bite a real school in its first month.**

`payments` has exactly one date column, `created_at`, and `fn_record_payment`
takes no date argument:

```
payments: id, ..., created_at          -- no paid_on, no received_on
fn_record_payment(p_student_id, p_amount, p_method, p_note, p_pending)
```

Every collection figure in the product is computed from it. From
`fn_dashboard_summary`:

```sql
and p.created_at >= v_month_start
and p.created_at <  (v_month_start + interval '1 month')
```

So a payment is stamped with the wall-clock moment somebody typed it, and there
is no way to say when the money actually arrived.

What that costs a school:

1. **A clerk who enters Saturday's cash on Monday** has it counted in Monday's
   collection and Monday's till. Saturday's drawer can never be balanced,
   because `fn_close_till` sums payments by the same column.
2. **The month boundary is unforgiving.** Fees taken on the 31st and entered on
   the 1st land in the wrong month, so `fn_fee_reconciliation` (expected versus
   collected) is wrong for both months, in opposite directions, permanently.
3. **A school migrating from paper cannot enter this year's receipts at all.**
   `fn_import_opening_balances` carries balances forward, which is the right
   tool for last year; it is not a way to enter the receipts already issued
   this month.

**The asymmetry is the giveaway that this is an oversight and not a decision.**
Money going *out* can be dated. Money coming *in* cannot:

```
fn_record_expense     (p_amount, p_category_id, p_spent_on date DEFAULT current_date, ...)
fn_record_other_income(p_amount, p_source,      p_received_on date DEFAULT current_date, ...)
fn_record_payment     (p_student_id, p_amount, p_method, ...)   -- nothing
```

`fn_profit_snapshot` therefore reads expenses on their real dates and fee income
on its keystroke dates, and cannot be internally consistent for any month in
which a single receipt was entered a day late.

**Proposed fix.** Add `paid_on date not null default current_date` to `payments`;
backfill it from `created_at::date`; give `fn_record_payment`,
`fn_record_family_payment` and `fn_record_bulk_payments` an optional
`p_paid_on`, refused if it is in the future and bounded to a small window in the
past (7 days is enough for a weekend plus a holiday, and small enough that it
cannot be used to move money between financial years); key the 17 functions that
currently date a payment by `created_at` off `paid_on`; keep `created_at` as the
immutable "when it was typed", which is what the audit trail needs.

Blast radius, measured: 17 functions reference both `payments` and `created_at`
(`fn__invoice_document`, `fn__student_ledger`, `fn_apply_family_credit`,
`fn_class_dues`, `fn_counter_summary`, `fn_dashboard_summary`,
`fn_finance_summary`, `fn_global_search`, `fn_my_billing`,
`fn_platform_purge_school`, `fn_platform_school_detail`, `fn_portal_child_fees`,
`fn_recent_payments`, `fn_report_balance_sheet`, `fn_report_ledger`,
`fn_review_eligibility`, `fn_unsent_receipts`). Not all of them are dating uses;
each needs reading.

**Forced this simulation to reach around the schema.** Two years of payments had
to have `created_at` rewritten as the table owner afterwards, which is the one
thing in the whole seed that a school could not do itself, and correctly so.

---

## F2. The write boundary is very well drawn, and it caught me

**Not a defect. Recording it because it is the best thing in the schema.**

Every table where money or a permanent record lives refuses a direct insert from
`authenticated`, so the only way in is through an audited function:

```
RPC-only: adjustments, attendance_daily, certificates, certificate_cancellations,
          deposit_refunds, discounts, families, fee_heads, fee_structures,
          invoices, invoice_lines, login_secrets, mark_entries,
          payment_allocations, payment_method_tokens, payments, result_cards,
          student_fee_items, reviews, billing_runs, billing_attempts
```

Reference data and settings are directly writable behind RLS, which is the right
line to draw. The first draft of `02_money_and_staff.sql` inserted straight into
`fee_structures` and was refused with `permission denied for table
fee_structures`; it now goes through `fn_set_fee_amount`, which is what the
Settings screen does.

---

## F3. Two attacks an owner might try, both blocked

Attempted as a real signed-in owner with RLS on.

**Forging an audit entry.** `authenticated` holds an `INSERT` grant on
`audit_log`, which looks alarming. RLS carries a `SELECT` policy and no
`INSERT` policy, and RLS with no policy for a command denies it:

```
insert into public.audit_log (...) values (...);
ERROR:  new row violates row-level security policy for table "audit_log"
```

**Rewinding the receipt sequence** to reissue a number over a cancelled one:

```
update public.counters set value = 1;
UPDATE 0
```

Zero rows, because the row is invisible to the policy. The grant is wider than
it needs to be in both cases and is not exploitable; RLS is doing the work.
Worth tightening the grants anyway, on the principle that the next person to
read the grant table should not have to reason this out.

---

## F4. A gate log cannot be fabricated

`staff_checkin_attempts` refuses an insert from `authenticated`
(`new row violates row-level security policy`), so only `fn_staff_check_in`
writes it. That is correct and it is worth saying out loud: the table exists to
answer "somebody says the code did not work", and a school that could write to
it could also erase the evidence that a member of staff never arrived.

---

## F5. Seeding module-by-module produces an empty school, and the reason is structural

**Not a product defect. A finding about the data model that anybody writing a
migration, an import or a demo needs to know.**

An enrollment exists in exactly one session, and the only thing that creates
next year's enrollment is `fn_rollover`. The first version of this simulation
seeded all students, then all attendance, then all billing, and produced **3.4
children per section-day across two years**: every session except the one each
child was admitted into was empty.

The simulation now walks the calendar instead: set the session, raise the fees,
take the enquiries, bill each month, collect, then roll the school forward. That
is the only order in which the chronology can be true, and it is the order a
real school works in.

The practical consequence for the product: **`fn_import_students` cannot give a
school its history.** Importing 200 children puts them all in the current
session with no prior enrollments, so last year's attendance, last year's
challans and last year's result cards have nowhere to attach. A school arriving
with two years of records on paper can carry its balances (via
`fn_import_opening_balances`) but not its years. That may well be the right
scope, but it is worth being explicit about in the sales conversation, because
"import your records" and "import your history" are different promises.

---

## F6. `fn_rollover` is sound

Dry run over the opening roll of 120, before any commit:

```
total 120, promoted 110, graduated 10, retained 0, skipped 0, unmapped 0
```

Class 10 graduates rather than being promoted into nothing, and nothing was
unmapped, which means `level_order` is being walked correctly and the
`fn_rollover_undo` path has a clean state to return to. Three real rollovers run
in the simulation (2023-24 to 2024-25, 2024-25 to 2025-26, 2025-26 to 2026-27).

---

## F7. `student_balance` read the whole ledger on every call. **Fixed in migration 0118.**

**Severity: high, and invisible for the first year, which is what makes it worth
a migration rather than a note.**

`student_balance()` is the hottest function in the money engine: the fee
screens, the defaulters list (once per child), the family sheet (once per
sibling), `fn_rollover` (it reports a balance for every child it promotes) and
the parent portal all call it. It is four correlated subqueries over
`invoice_lines`, `invoices`, `adjustments` and `payment_allocations`.

**Two of those four tables had no index on the column it is joined by.**
Postgres indexes the *target* of a foreign key automatically and never the
*source*, so `invoice_lines.invoice_id` and `payment_allocations.invoice_id`,
both foreign keys, both joined on every balance calculation, had nothing to use.

### Measured

A five-year school of 400 children: 20,630 invoices, 95,600 invoice lines,
13,600 payments and allocations. Two hundred consecutive calls, same data, same
box, `ANALYZE`d both ways.

| | before | after | |
| --- | --- | --- | --- |
| `student_balance()` x 200 | 2,026 ms | 353 ms | **5.7x** |
| per call | 10.13 ms | 1.76 ms | |
| the `invoice_lines` join alone | 14.5 ms | 0.32 ms | **45x** |

```
before:  Hash Join   ->  Seq Scan on invoice_lines  (rows=95,600)  to find 97
after:   Nested Loop ->  Bitmap Index Scan on idx_invoices_student
```

### It is invisible at first, and that is the point

The identical measurement on a school with 11,600 invoice lines showed **no
difference at all**: 190 ms against 193 ms. At that size the planner is right
that scanning is cheaper. The cost then arrives in linear proportion to how long
the school has been a customer, so **the school that suffers most is the one
that has been paying longest**, and nobody would ever connect the two.

### How it was found

The two-year simulation tried to take about 5,000 family payments across 31
months and ran for **eleven minutes without committing a single row**. Every
payment recomputes a balance and every balance re-read a table that was growing
underneath it. With the indexes in place the same run completes in **147
seconds** and gets through three sessions and two year-end rollovers.

The benchmark setup was caught by the same bug: a `not exists (select 1 from
invoice_lines where invoice_id = i.id)` guard over 20,630 invoices, which
without the index is one full table scan per invoice.

### What migration 0118 does and does not do

31 indexes, chosen from a sweep of all **84 foreign keys in the schema that have
no index on the referencing column**. The other 53 are almost all audit stamps
(`created_by`, `marked_by`, `issued_by`, `approved_by`) pointing at `profiles`,
which holds a handful of rows per school and is only ever read one row at a time
to print a name. Indexing those would cost write throughput on every insert and
buy nothing.

`CREATE INDEX CONCURRENTLY` is not used, and cannot be: it may not run inside a
transaction, and a school applies these by pasting a file into the Supabase SQL
editor, which runs the paste as one transaction.

The migration's own guard asserts the **property** rather than the spelling: it
checks the four measured indexes exist *and are on the right column*. Verified
by building `idx_invoice_lines_invoice` over `school_id` instead and confirming
the migration refuses:

```
ERROR:  0118: 1 of the four measured indexes is missing or is on the wrong column
```

---

## F8. Two admission paths, and the guard between them is excellent

Not a defect. `fn_set_enquiry_status(..., 'admitted')` refuses outright:

```
Use fn_enquiry_admit to admit — it creates the student record too
```

An enquiry marked admitted with no student behind it is a lie the Enquiries
screen would then report as a conversion, so the status cannot be set by hand;
`fn_enquiry_admit` builds the payload from the enquiry, admits the child, and
writes `admitted_student_id` back in one call.

The first draft of the simulation called `fn_admit_student` and then tried to set
the status. It admitted 150 children correctly and reported every one of them as
a failure, because the exception handler wrapped both halves. **The error message
named the exact function to use, which is why this took one reading to diagnose
rather than an afternoon.** That is worth more than it sounds: most schemas would
have raised a foreign key violation.

---

## F9. The refundable-charge invariant holds under a raw insert

While building the benchmark, a bulk insert of invoice lines that happened to
include the Security Deposit head was refused by the trigger from 0117:

```
ERROR:  A refundable charge must be billed on its own challan, not mixed with
        ordinary fees. Issue the deposit separately.
```

This was a direct table insert as the table owner, bypassing every function, and
the invariant still held. That is the correct place for a rule of that kind.

---

## F10. Press Year Rollover and last year's result cards can never be printed. **Fixed in migration 0119.**

**Severity: high. It destroys nothing, and it permanently blocks a document
parents ask for. It fails silently and the screen says everything is fine.**

The sequence, and it is the natural one rather than a mistake:

1. Final exams in March. Every paper marked, every mark entered.
2. The new session starts on 1 April. The office presses **Year Rollover**,
   because that is what produces the new class lists and the teachers are
   waiting for their rosters. Nothing warns them to do anything first.
3. In May a parent asks for last year's result card.
4. Exams → Final Term → Generate result cards. **It reports nothing and
   produces nothing.** `fn_result_readiness` returns zero rows, so the screen
   says the class is ready.

`fn_rollover` marks the finished session's enrollments `promoted` (or
`graduated` for the leaving class), which is correct: they are not the current
roll any more. But both `fn_generate_result_cards` and `fn_result_readiness`
selected the pupils for a card with

```sql
and e.status = 'active'
```

so after the rollover a past term has no pupils, a class with no pupils
generates no cards, and a class with no pupils has no problems to report. Every
mark is still in the table. Only the ability to turn them into the document is
gone, and nothing anywhere says why.

### Measured, on the simulated school with three real rollovers behind it

One class, three terms:

```
before   {"generated": 0,  "provisional": false, "missing_marks": 0}
         {"generated": 0,  ...}
         {"generated": 0,  ...}        and fn_result_readiness returned zero rows

after    {"generated": 11, "provisional": false, "missing_marks": 0}
         {"generated": 17, "provisional": true,  "missing_marks": 8}
         {"generated": 17, "provisional": false, "missing_marks": 0}
```

The provisional card in the middle is the machinery working: those eight pupils
were admitted after the mid-term, so they sat no papers, so the card says so.
That is exactly the distinction the `active` predicate was flattening to zero.

### The fix

The right predicate is not "on the roll now" but "was in this class that year":

```sql
and e.status in ('active', 'promoted', 'retained', 'graduated')
```

`left` and `struck_off` stay excluded on purpose: a child who left in November
did not finish the year and does not get a final card. `graduated` is included
because the leaving class sat the same final exam as everybody else, and theirs
is the card that matters most.

Applied as a **patch** to the stored bodies rather than a restatement, because
`fn_generate_result_cards` is getting on for 300 lines and has already been
patched by 0089 (the GPA scale), 0100 (the attendance formula), 0105 (the leave
counts) and 0110 (the write gate). Retyping it to change one predicate is how a
stack of earlier fixes gets silently reverted. Three sites in total: one in the
generator, two in readiness. Verified zero remaining.

### The guard asserts behaviour, not text

A grep for the new predicate would pass on a function carrying it in a comment.
The migration builds a finished session with a **promoted** pupil, a paper and a
mark, asks for a card and requires one, then rolls the whole probe back.
Verified against the unfixed code:

```
ERROR:  0119: a promoted pupil still gets NO result card. Every school that has
        pressed Year Rollover is unable to print the cards for the year it
        rolled out of.
```

Two things the guard learned the hard way, both of them the schema being right:
`profiles.id` references `auth.users`, so a probe needs a login before it can
have an owner; and `mark_entries.max_marks` is `not null`, because a mark
carries its paper's maximum with it so that a later edit to `exam_subjects`
cannot silently restate what a printed card said.

---

## F11. The practical flag belongs to the subject, and the schema knows it

Not a defect. `fn_upsert_exam_subject` refuses a paper with practical marks
unless the subject itself is flagged:

```
Mark this subject as having a practical before giving it practical marks
```

A subject that carries 25 practical marks in one term and none in the next is a
data-entry mistake rather than a curriculum decision, so the flag lives one
level up on `subjects` and only `fn_set_subject_details` sets it. The
simulation's first draft set it on the paper and was correctly refused.

---

## F12. The audit log is seven times the size of the data it audits. **Fixed in migration 0126, see F26.**

**Severity: medium, and it is a cost-of-goods problem rather than a bug.**

On the simulated school, 2.5 years, 221 children on the roll:

| table | size |
| --- | --- |
| `audit_log` | **266 MB** |
| `attendance_daily` | 37 MB |
| everything else | under 6 MB each |

`audit_log` is **68% of the whole database**. `trg_audit_attend` is
`FOR EACH ROW` on INSERT, UPDATE and DELETE of `attendance_daily`, and
`audit_trigger()` stores a full `before`/`after` jsonb of the row. So marking a
class of thirty writes thirty audit rows, and finalising the day writes thirty
more.

**Of the 269,233 attendance audit rows, not one carries a `reason`.** Every
single one is routine marking or finalisation. Meanwhile the correction trail
that actually matters lives on the row itself, in
`attendance_daily.corrected_from` and `.correction_reason`, and
`fn_attendance_corrections` reads those columns and not the audit log.

Extrapolated: 220 children × 220 school days is ~48,000 attendance rows a year,
so ~96,000 audit rows and roughly **90 MB of audit log per school per year**,
for a table nothing reads. Twenty schools is 1.8 GB a year of paid storage
carrying no information.

**Proposed fix, not applied here:** make the attendance audit conditional, so it
records a change that carries a `correction_reason` and ignores a first-time
mark and a finalisation. That is a change to `audit_trigger()` or to the trigger
's `WHEN` clause, it needs its own test suite, and it should be its own pass
rather than a corner of this one.

**That is what migration 0126 did, and the shape of it changed once the rows
were counted rather than reasoned about. See F26: the proposal above says
"ignores a first-time mark and a finalisation", and a finalisation turned out
to be the single biggest item in the table, bigger than the marks themselves.
Skipping it without replacing it would have left a school unable to say who
closed a register at all.**

---

## F13. Result cards, tests and exams all work, and the two mark paths coexist

`mark_entries` is shared by tests (`assessment_id`) and exams
(`exam_subject_id`) under two partial unique indexes, and both were exercised:
**5,898 test marks across 663 tests**, and **4,917 exam marks across 380 papers
in 5 terms**. The publish gate holds: one term is deliberately left unpublished
so the portal has something to correctly refuse.

---

## F14. Twenty-seven sentences the software says out loud carry an em dash. **Fixed in migration 0120.**

**Severity: medium, and it is a house-rule violation in user-facing text that
had been passing its own guard all along.**

A clerk voiding a paid challan was shown this:

```
Rs 759 has been paid against this challan. Reverse the payment first —
Fees → the receipt → Reverse — so the money movement stays on the record,
then cancel the charge.
```

That is, incidentally, one of the best error messages in the product: it names
the amount, the exact path through the UI, and the reason. It also breaks the
one absolute rule this house has about writing.

### Why the guard missed it, and its reasoning was careful rather than lazy

`scripts/check-no-emdash.py` counts about 2,900 em dashes under `supabase/` and
argues, in its own docstring, that almost all of them are in code comments no
school ever reads, so sweeping the directory would be *"a mechanical edit of
three thousand comment lines with no review, which is how a real defect gets
hidden inside a diff nobody can read."*

That is correct. **The hole is the word "almost".** `supabase/` also holds every
`raise exception` message in the product, and those are not comments. They are
the sentences the software says when it refuses.

Measured against the functions **as stored**, not against the migration text (a
message rewritten by a later migration does not matter): **28 string fragments
in 27 exception messages across 22 functions.**

### Each one read and punctuated by hand

The dash was doing three different jobs:

| job | example |
| --- | --- |
| a colon, where the second half explains the first | `A cancellation needs a reason: it stays on the register permanently` |
| a full stop, where the second half is a fresh instruction | `That invoice is voided. Allocate the payment elsewhere or leave it unallocated` |
| a comma, where the clause simply continues | `...the school's records, and archiving is reversible.` |

A global character swap would have produced `That invoice is voided: allocate
the payment elsewhere`, which nobody would write. So migration 0120 is a table
of 27 pairs, not a regexp.

### The durable half of the fix is the verify row, not the migration

A static script cannot tell which migration holds a function's latest
definition. So the rule is now asserted in `supabase/verify.sql` against the
live database, where *"does any stored function say this to a user"* has a real
answer, and `check-no-emdash.py`'s docstring now records where that half of the
rule lives. Migration 0120 could not edit the migrations that wrote the
messages, because those sit inside frozen bundles.

---

## F15. Nothing ever drains the message outbox

Every enquiry, admission and receipt queues a WhatsApp automatically. After two
and a half years the outbox held **6,176 rows, every one of them `queued`**,
because nothing in the product drains the queue by itself and nothing ages a row
out.

A school that never presses Send therefore accumulates them for ever, and
`fn_unsent_receipts` keeps returning the whole history. `message_outbox` was
already the third-largest table in the simulated database before the drawer and
corrections passes ran.

Not a defect exactly: a human is meant to press Send, and the queue is the
worklist. But there is no cap, no age-out and no "these are older than a term,
they are never going out now" state, so the worklist becomes unusable rather
than merely long. Worth a decision rather than a fix.

---

## F16. `fn__ensure_till` opens a drawer nobody ever closes

A cash payment with no open till calls `fn__ensure_till()`, which opens one.
Nothing closes it. So two and a half years of collection produced **exactly one
till session, still open, holding 2,236 cash payments** and Rs 9.8 lakh.

That is a true picture of a school that never uses the close-drawer feature, and
the consequence is that `fn_close_till`'s variance arithmetic had never run once
in the life of the tenant. When the simulation finally closed it:

```
expected 9,813,150.75   counted 9,793,524   variance -19,626.75
```

The arithmetic is correct. The point is that a drawer nobody closes is a drawer
nobody reconciles, and the product does not ask. A daily close is now simulated
across the last 50 school days, with both a short and an over day, and four days
left unapproved so `fn_approve_till` has something to clear.

---

## F17. The good parts, said plainly

Worth recording, because a report that only lists faults is not an audit.

- **The write boundary** (F2) is the best thing in the schema.
- **The refusal messages are unusually good.** `fn_void_invoice` names the
  amount, the UI path and the reason. `fn_set_enquiry_status` names the exact
  function to use instead. `fn_add_enquiry` refuses a blank phone number with
  "an enquiry nobody can ring is not an enquiry". These are the sentences that
  made three separate diagnoses in this run take one reading instead of an
  afternoon.
- **The invariants hold under a raw insert as the table owner** (F9).
- **`fn_rollover` is sound** (F6): three real rollovers, 113, 144 and 180
  promoted, 10 graduated each, nothing unmapped, nothing skipped.
- **`mark_entries.max_marks` is `not null`**, so a mark carries its paper's
  maximum with it and a later edit to `exam_subjects` cannot silently restate
  what a printed card said. That is a considered decision, not an accident.
- **The practical flag lives on the subject** (F11), not on the paper.
- **The provisional result card works**: children admitted after a mid-term
  produce a card that says so, rather than a card with holes in it.

---

## F18. The read sweep: five screens were over a second, and one took 7.7 seconds

**This is the headline number of the audit, and it is what migration 0118
actually bought.**

Every read path in the product, timed on the finished simulation (368,386 rows,
223 children, 2.5 years), as a real signed-in owner with RLS enforced. Three
calls each, the last one reported, so these are **warm-cache figures on a local
SSD**. The same sweep was then run on a byte-identical copy with 0118's 32
indexes dropped.

| Screen | without 0118 | with 0118 | |
| --- | --- | --- | --- |
| Reports: fee reconciliation, expected vs collected | **7,743.7 ms** | 116.3 ms | **67x** |
| Cash drawer: `fn_counter_summary` | **3,888.0 ms** | 59.2 ms | **66x** |
| Fees: head-wise dues, whole school | **3,398.2 ms** | 89.0 ms | **38x** |
| Fees: `fn_recent_payments(25)` | **1,862.7 ms** | 52.4 ms | **36x** |
| Reports: unpaid invoices | **1,472.3 ms** | 12.7 ms | **116x** |
| Reports: ledger, a full year | 712.2 ms | 18.3 ms | 39x |
| Fees: class dues, one section | 595.1 ms | 24.5 ms | 24x |
| Dashboard | 565.2 ms | 66.9 ms | 8.4x |
| Fees: defaulters, whole school | 479.0 ms | 64.8 ms | 7.4x |

**`fn_recent_payments(25)` is on the dashboard.** It is one of the first things
the software does every morning, and it was taking 1.86 seconds on a warm cache
for a school with 4,800 payments. On Supabase, cold, across a network from
Islamabad, that is a screen a school would describe as broken.

**These are the numbers the live database is running at today**, because bundle
24 has not been pasted yet.

### And with the indexes, everything is fast

| | |
| --- | --- |
| slowest screen in the product | 116 ms (fee reconciliation) |
| dashboard | 67 ms |
| **global search bar** | **6.5 to 11.3 ms** |
| a child's whole 2.5-year ledger | 3.3 ms |
| a section's register for today | 0.7 ms |
| a child's attendance summary over a year | 0.2 ms |

The **global search** was the specific worry, and it is not one: 11.3 ms for a
first-name search across children, parents, staff, challans and receipts, 6.5 ms
for a receipt number. `students(school_id, full_name)` and the voucher and
receipt indexes were already right before this audit started.

The three that remain worth watching, all in the 60 to 120 ms band, all
whole-school aggregates rather than per-child reads: fee reconciliation,
head-wise dues and the dashboard. None is a problem at this size. All three
scale with the number of invoice lines, so they are the ones to re-measure at
1,000 children.

---

## F19. ANALYZE at the wrong moment made a three-minute paste take twenty

**Not a defect in the product. An operational finding about how a long paste
behaves, and it applies to your migration bundles too.**

The simulation runs in about six minutes when `supabase/sim/run.sh` drives it,
one file per psql invocation. Turned into files for the Supabase SQL editor, the
same work took over twenty minutes and was still in year two of three when it
was killed. Three measurements to find out why:

| where the `ANALYZE` was | file 2 took |
| --- | --- |
| at the start of each section | **20+ minutes**, killed |
| at the end of each section, so only the next file sees it | 7m 15s |
| nowhere at all | **3m 44s** |

**Statistics that say "small" freeze bad plans into the rest of a long
transaction.** Running `ANALYZE` when `students` holds 120 rows records "this
table is nearly empty", and the planner then chooses nested loops for three
minutes of work while the table grows underneath it. With no `ANALYZE`,
Postgres falls back to its own default estimates, which are far more
conservative and produce better plans for a table being filled. That is why
`run.sh` was fast all along: its database has never been analyzed.

Moving it to the end of each section only pushed the problem one file along:
file 1 finished by recording 120 students, and file 2 opened with that as truth.

The paste set now runs one `ANALYZE`, in the last file, after the writing is
over, where the only thing it can affect is how fast the school's first screen
is afterwards.

**Why this matters beyond the simulation.** Anything that writes a lot inside
one transaction has this shape, which includes a bundle that backfills a table
and then reads it. It is a reason to prefer "write, commit, then read" over one
long transaction, and a reason never to sprinkle `ANALYZE` into the middle of a
migration for luck.

### The paste set, measured

Seven files, in order, each its own transaction, against a database in exactly
the state a real project is in (migrations applied, school signed up, no data):

| file | time |
| --- | --- |
| 1 set the school up | 0s |
| 2 two and a half years | 224s |
| 3 the register | 69s |
| 4 tests and exams | 7s |
| 5 the drawer | 8s |
| 6 set the clock | 25s |
| 7 check it worked | 2s |
| **total** | **about 6 minutes** |

Ending: `BELIEVABLE. 368,242 rows, 222 children on the roll, 89,634 attendance
rows over 589 days, 716 result cards, audit log spans 784 days.`

---

## F20. The ceiling is around 1,000 children, and it is the whole-school aggregates

**Where the product actually stops being fast, measured rather than guessed.**

The finished school was pushed to a five-year, 1,000-child shape (52,947
invoices, 198,639 invoice lines) and the same read sweep re-run, **with all of
migration 0118's indexes in place**.

| Screen | 222 children | 1,003 children |
| --- | --- | --- |
| Reports: fee reconciliation | 116 ms | **3,013 ms** |
| Fees: head-wise dues | 89 ms | **2,044 ms** |
| Fees: defaulters | 65 ms | **1,514 ms** |
| **Dashboard** | 67 ms | **1,445 ms** |
| Reports: unpaid invoices | 13 ms | **1,250 ms** |
| Students, page 5 | 58 ms | 502 ms |
| Cash drawer summary | 59 ms | 471 ms |
| Reports: balance sheet | 25 ms | 226 ms |
| Students, page 1 | 18 ms | **135 ms** |
| Fees: recent payments | 52 ms | 55 ms |
| Fees: class dues, one section | 25 ms | 41 ms |
| **Global search** | 11 ms | **22 ms** |

### What this means commercially, plainly

- **Up to about 400 children the product is comfortably fast.** Every screen
  stays well inside a couple of hundred milliseconds.
- **At around 1,000 children the dashboard crosses a second** and the fee
  reports reach three. That is the point at which a school starts describing
  the software as slow.
- **The per-child and per-section reads do not degrade at all.** A child's
  ledger, a section's register, class dues, recent payments and the search bar
  are all flat or nearly flat. So the ceiling is specifically the **whole-school
  aggregates**, which read every invoice line in the school on every call.
- For the ten to twenty Pakistani private schools of 200 to 400 children this
  business is aimed at, there is nothing to do here. It matters when a
  1,000-pupil school signs up, and it is worth knowing before that conversation
  rather than during it.

The fix, when it is needed, is not more indexes: it is a nightly or on-write
rollup of per-month per-class totals, so the reports read a summary table
instead of the ledger. That is a design change and it should wait until a real
school needs it.

### One number in the first sweep was my benchmark's fault, not the product's

`fn_family_sheet()` came out at **2,954 ms**, an 800x degradation for what should
be a single-family read. It is an artefact: the synthetic children were all
given the same `family_id`, so that one family held 782 children. Re-timed on a
family with a realistic two children: **5.8 ms**. Recorded because a sweep that
reports a number like that without checking it is how a fake finding gets
believed.

### And one that is real but is a decision, not a defect

`fn_student_list()` page 1 costs 135 ms at 1,000 children, up from 18 ms. The
function already avoids calling `student_balance()` per row (somebody optimised
that, and the comment says so). What remains is
`counted as (select count(*) as n from base)`: the total for the pagination
footer, recomputed over the whole filtered set on every page. That is a
reasonable thing to want and an O(school) cost to pay for it. Counting only on
the first page, or dropping the exact total, is a product decision rather than a
bug fix.

## F21. Finalize a register with a wrong mark on it and nobody, at any privilege level, could ever put it right. **Fixed in migration 0121.**

**Severity: high. The most serious thing this simulation found, and it was found
by asking why one column was empty.**

Every past day in this school's register is finalised, which is what a real
school does. So after the first build I looked at the corrections report and it
had nothing in it: `corrected_from` was null on all 89,634 attendance rows.
Chasing that produced this.

`fn_finalize_attendance` sets `attendance_daily.is_locked = true`.
`fn_mark_attendance`'s upsert carries `where not ad.is_locked`. And a search of
every function body in the schema for `is_locked = false` returns **nothing**.
There was no unlock, no override and no owner exception anywhere in 330
functions.

Reproduced as the school's own OWNER, with a reason, on a day thirty days old:

```
day 2026-09-05 : the register says "present", locked = t
the OWNER, with a reason, gets: {"total": 1, "marked": 0, "skipped": 1}
the register now says "present"   <-- unchanged. There is no way to fix it.
```

### Why it is worse than one wrong mark

- **The register is a legal document** in a Pakistani school, and it was wrong
  for ever.
- **It reaches the result card.** `fn_generate_result_cards` computes the
  attendance percentage from `attendance_daily`, so the wrong figure is printed
  and sent home to that family every term, for the rest of the child's time at
  the school.
- **It inverts the privilege ordering.** A class teacher can finalise their own
  class. So the least privileged user in the product could create a state the
  owner could not undo, which is true nowhere else in this schema.

To the application's credit it is not silent about it: the Attendance screen
already said "1 locked, skipped", and then "This day is finalized and locked. It
is read-only." So the school was told exactly what had happened and given no way
to act on it.

### The fix, and what it deliberately does not do

`fn_unlock_attendance(session, class, section, date, reason)`:

- **Owner and principal only.** Deliberately not the class teacher who locked
  it. If the person who finalised could reopen it, finalising would mean
  nothing, and the thing it protects (a teacher cannot quietly rewrite last
  Tuesday) is worth keeping.
- **A reason, at least eight characters**, on the audit log with the before and
  after and who did it. That accountability is what replaces a date window.
- **Not date-bounded.** A school that finds a mistake at the end of term must be
  able to fix it, and a limit would only move the trap to a different distance.
- **It does not change the mark.** It clears the lock; the correction then goes
  through `fn_mark_attendance` exactly as a same-day fix does, which is what
  writes `corrected_from` and `correction_reason` so the corrections report can
  show it.
- **Its section predicate is `is not distinct from`, matching
  `fn_finalize_attendance` exactly.** The first version read
  `p_section_id is null or ...`, which means "the whole class" where finalize
  means "the pupils in this class who are in no section". Reopening more than
  the button that closed it is how an owner fixing one child's mark quietly
  reopens four other sections.

Proved three ways, because a function that exists and returns 0 would satisfy a
grep: 14 assertions in `supabase/tests/corrections.sql` (a class teacher is
refused, the owner reopens, the correction takes, it appears in the report with
its reason, the day closes again, a principal may also reopen, and an
already-open day is refused); three UI tests that the door is on the screen for
an owner and not for a teacher; and a `verify.sql` row that checks the body
clears the flag and that `authenticated` may execute it. A no-op stub fails all
three.

The simulation now walks the path: twenty days across the two years are
reopened, corrected and closed again, so the corrections report has rows in it
for the first time.

## F22. 0120 fixed what the software says when it REFUSES. Fifty-seven strings it says while WORKING still carried an em dash, six of them in text messages to parents. **Fixed in migration 0122.**

**Severity: medium, and the interesting part is how a careful guard came to be
asserting the narrower half of its own rule.**

F14 found the em dash in `raise exception` messages, 0120 repunctuated all 27,
and the `verify.sql` row has been asserting that ever since. Then, while writing
the verify row for 0121, I read `fn_attendance_corrections` and saw this at the
end of it:

```sql
ad.correction_reason, coalesce(p.full_name, '—')
```

A `raise exception` is what the software says when it refuses, which most users
never see. What everybody sees is what it says when it works. Counted properly,
against the functions as stored and with their comments stripped out: **57
string literals in 29 functions**, not one of them a refusal message.

| | |
|---|---|
| **6 message templates** | Seeded at signup and sent to parents by SMS and WhatsApp: `Fee received. Thank you — {school}.` |
| **24 placeholders** | `coalesce(x, '—')` in 13 report and search functions: the fee ledger, recent payments, the enquiry list, both corrections reports, global search, voided challans, the discount report |
| **27 sentences** | The staff check-in explaining why a saved link will not work, the licence notice, the renewal message, the importer saying which column to add, the operator console throughout |

The templates are the worst of it: the em dash was not merely in this project's
writing, it was going out in text messages under a school's name. On the
two-year simulation there were **864 queued messages** carrying it.

### Three things this one taught

- **Patching the function is not patching the school.**
  `fn__default_message_templates` runs once, at signup. A school that already
  exists keeps its own `message_templates` rows, and its already-composed
  messages sit in `message_outbox` waiting to go. Both are repaired, by the
  exact fragment only, so a template a school has edited for itself keeps its
  own wording, and only `queued` and `failed` messages are touched: one that has
  already been sent is a record of what happened.
- **The first version of the data patch repaired 104 rows of 864 and looked
  successful.** It matched on `{school}`, and `message_outbox.rendered_text`
  holds the finished text with the school's *name* already substituted. Caught
  by counting what was left rather than what had changed.
- **A check must not break its own rule.** The `verify.sql` row is written with
  `\u2014` escapes rather than the characters, because
  `scripts/check-no-emdash.py` now scans the string literals in that file, and
  the first version of the check failed itself.

### And the same rule was broken by the checking apparatus, in its own output

`supabase/verify.sql` said `FAIL — re-run bundle 7` and ninety-six variations of
it, read by exactly the person who has just been told something is wrong with
their database. `supabase/reset.sql` said it once. Both fixed here, and
`scripts/check-no-emdash.py` now scans the string *literals* of those operator
scripts, with comments exempt: not "does this file contain the character" but
"does the software say it". Proved to catch a dash inside a `$$` function body
and to allow one in a comment.

What is still not swept, said plainly: about 2,900 em dashes in code comments
under `supabase/`, which nobody outside this repository will ever read; and the
text inside `supabase/migrations/` and `supabase/bundles/`, which cannot be
swept because a bundle a school has already pasted must never change. The two
verify rows are what hold that line, against the live database rather than the
file.

## F23. A school had two names, and could only ever edit one of them. **Fixed in migration 0123.**

**Severity: high, and it is the first finding here reported by a real school
rather than found by the simulation. What found it was the simulation refusing
to run.**

They pasted all seven demo files and every one refused:

```
ERROR: No owner session. Is the school name exactly right?
```

The name they had put in the files was the name on their own Settings screen.
Their project held this:

| | `schools.name` | its own screens say |
|---|---|---|
| | Al Qalam School | Al Qalam School |
| theirs | **Choudhary Public School** | **Chaudhary Puclix High School Ghauriii** |

### Why

There are two name columns.

| column | written by | read by |
|---|---|---|
| `schools.name` | `fn_signup_school` at signup, and the operator console | the console, `platform_invoices.school_name` on the bill sent to the school, and anything that finds a school by name |
| `school_settings.name` | seeded from `schools.name` by a trigger, and thereafter the **only** one a school can edit: the first-run wizard and Settings both write it | the sidebar, receipts, challans, certificates, result cards |

And `public.schools` carries **only SELECT policies**. No INSERT, UPDATE or
DELETE policy exists on it at all, so with row level security on, a signed-in
user cannot change `schools.name` by any route. The application had not
forgotten to write it; it structurally could not. From the moment a school
edited its own name the two diverged permanently, and nothing in the product
could bring them back together.

So the school was **billed under a name it never chose**, support opened a
console naming it something the school would not recognise, and every
name-based lookup missed it.

### The fix, and why it is a trigger

`fn__mirror_school_name()`, `after insert or update of name on school_settings`.
A new RPC would have fixed the two screens that exist and left the next one free
to diverge again, and the app cannot write `schools` in any case. As a trigger
the two columns become one fact for every write path, including the first-run
wizard that already existed.

`school_settings.name` wins, because it is the one the school chose and the one
printed on everything the school hands to a parent. **Except the placeholder:**
that column is `NOT NULL DEFAULT 'Your School'`, and `fn_set_current_session`
inserts the row with no name if it is somehow missing, so a blind copy could
rename a real school to "Your School" on its own invoices. The placeholder is
never mirrored, in the trigger or in the backfill.

The backfill was tested against the reported state and turns it into one name.
The verify row asserts the property, not the trigger: **no school in this
database may carry two names**, with a second clause for "they agree today but
nothing keeps them in step".

The seed now also searches both columns, so a school reading its own name off
its own screen is found either way, and says which bundle puts it right.

## F24. A signup that stopped halfway left a school nobody could open or delete, and the rollback that was supposed to prevent it could never have worked. **Fixed in migration 0124.**

**Severity: medium, reported by the same school in the same breath.**

They tried signing up twice with one email address. The second attempt was
correctly refused, and it left this behind:

```
[Chaudhary School]   0 active owners, 0 students
```

`supabase/functions/signup-school` does the only thing it can in the order it
must: the school has to exist before the login, because the login's profile
needs a school to attach to. So on failure it rolled the school back:

```ts
await admin.from('schools').delete().eq('id', schoolId)
```

That statement **cannot succeed, and never once had**. A trigger on `schools`
creates the `school_settings` row the instant the school is inserted, and
`school_settings.school_id` is `ON DELETE NO ACTION`. Reproduced:

```
ERROR: update or delete on table "schools" violates foreign key constraint
       "school_settings_school_id_fkey" on table "school_settings"
```

The result of that call was never read, so the function returned its correct,
friendly "that email address already has an account" and the school stayed. A
signup writes rows in **six** tables (`audit_log` 8, `expense_categories` 8,
`message_templates` 7, `operator_actions` 1, `school_settings` 1,
`subscriptions` 1), so no single delete was ever going to do it.

What it cost: an ownerless school sitting in the console looking like an
ordinary new customer, and removing one takes a platform admin **archiving it,
exporting it and then purging it**, three deliberate safeguards written for a
real school and exactly the wrong ceremony for a signup that never happened.

### The fix

`fn_signup_rollback(school_id)`, service role only, which:

- refuses anything with a login, a pupil, a payment, an invoice or a platform
  payment against it. **The safety property is "no owner and no pupil", not a
  time window:** a real school always has an owner profile, a school with a
  pupil is real whatever else is true, and a school ownerless for a month is
  still a signup that never completed;
- never touches `platform_invoices` or `platform_payments`, which are the
  vendor's accounting record and outlive the school on purpose;
- walks every table with a foreign key to `schools`, **derived from
  `pg_constraint` rather than a list**. The first version used
  `fn__school_data_tables()` and failed its own probe on
  `operator_actions_school_id_fkey`: that helper lists the 51 tables holding a
  *school's* data, 59 carry a foreign key to `schools`, and a signup writes to
  two of the eight it leaves out;
- records what it did before deleting anything, with `school_id` null so the
  record survives the school it describes. Same trick as
  `fn_platform_purge_school`, and for the same reason.

The Edge Function now calls it **and reads the result**, and says so with a
reference if the school could not be removed, rather than leaving somebody to
find it in the console later with no idea where it came from. It has to be
redeployed for new signups to use it.

## F25. An internal helper was reachable from a browser, four guards existed for exactly that, and every one of them read clean. **Fixed in migration 0125.**

**Severity: the defect itself is minor. The blindness that hid it is the
finding, and it is the worst one in this document.**

A school pasted the two bundles from F23 and F24, ran `verify.sql`, and got one
FAIL out of seventy-four:

```
one school cannot reach another's families or fees (0070)
  FAIL: re-run bundle 7 (cross-tenant leak is OPEN)
```

Nothing to do with bundle 7. That row's third clause asserts a blanket
property: **no function named `fn__` may be executable by `authenticated`.** The
prefix is this schema's word for "internal, called only by something that has
already scoped the ids", and `check-definer-idor.py` exempts `fn__` functions
from its per-parameter scoping analysis on precisely that basis. A grant turns
the exemption into a hole, which is not hypothetical: `fn__apply_discount_lines`
once carried the prefix *and* a grant, and one school could write a discount
line onto another school's invoice.

Two functions were open:

| | |
|---|---|
| `fn__mirror_school_name` | added by **0123, four hours earlier**, whose migration says `revoke execute ... from public, anon` and stops |
| `fn_record_migration` | open since 0069. Writes `schema_migrations`, the table `verify.sql` and `detect.sql` read to answer "what is installed here", so a signed-in user could make both of them lie |

### Why revoking from `public` was not enough

A new function carries EXECUTE for PUBLIC by default, so `revoke from public`
looks total. On a real Supabase project it is not, because the project's
bootstrap runs

```sql
alter default privileges in schema public
  grant all on functions to postgres, anon, authenticated, service_role;
```

so every new function *also* gets an explicit grant to `authenticated`, which a
revoke of PUBLIC does not touch. The spelling that works is
`revoke ... from public, anon, authenticated`, and it is the one
`check-definer-idor.py` prints when it fails.

### And why nothing here caught it

`scripts/preflight.sh` and `.github/workflows/ci.yml` build their databases with

```sql
alter default privileges in schema public grant all on tables to ...
```

and **no equivalent line for functions**. So in every database this project has
ever tested against, a function created by a migration comes out with no grant
to `authenticated` at all, and there is nothing for those guards to find. Four
of them, all correct, all reading a database in which the defect they exist for
cannot be represented:

| guard | on my harness | on a Supabase-shaped database |
|---|---|---|
| `verify.sql` row 0070 | PASS | **FAIL** |
| `detect.sql` 0070 | present | **MISSING** |
| `check-definer-idor.py` | ok | **names `fn__mirror_school_name`, prints the remedy** |
| `check-reachable.sh` | ok | **FAIL, and separately finds `fn_record_migration`** |

Reproduced by building one database the way Supabase does and applying the same
125 migrations. That is the whole diagnosis.

### The fix, in three parts

1. **0125** revokes both, and sweeps every `fn__` function rather than the one
   that was known, so the next one added without a revoke is closed by
   re-pasting this instead of by a sixth migration.
2. **Both harnesses** now grant functions and sequences too, at all eight sites.
   With the harness fixed and 0125 absent, all four guards fail.
3. **A guard on the guards.** `preflight.sh` now refuses to report on the
   database it was pointed at unless that database has a default privilege
   granting functions to `authenticated`, and says how to rebuild it. A checker
   that cannot express the defect it checks for should say so rather than pass.

The lesson generalises past this bug: **a test harness that differs from
production in how it grants privileges cannot test authorisation.** Four
independent guards agreeing means nothing if they are all reading the same wrong
database.

---

## F26. 84% of a school's database was its audit log, and 96% of the audit log was the register copied into it. **Fixed in migration 0126.**

**Severity: high, and it is the reason a school on the free tier ran out of
space.** F12 measured this at 68% and proposed a fix in one sentence. This is
that fix, and the sentence turned out to be half right in a way that would have
destroyed information if it had been implemented as written.

### What is actually in there

The finished two-year school, 266 children, 589 school days:

| | rows | on disk |
| --- | --- | --- |
| `audit_log` | 214,787 | **479 MB** |
| the whole rest of the database | | 92 MB |

And the audit log itself, by what the rows are about:

| entity | action | rows | jsonb |
| --- | --- | --- | --- |
| `attendance_daily` | UPDATE | 89,432 | 87 MB |
| `attendance_daily` | INSERT | 89,634 | 50 MB |
| `staff_attendance` | INSERT | 11,654 | 7.5 MB |
| `mark_entries` | INSERT | 10,794 | 7.3 MB |
| `mark_entries` | UPDATE | 5,295 | 6.4 MB |
| `payments` | INSERT | 4,845 | 2.9 MB |
| everything else | | ~3,100 | 4.5 MB |

**206,809 of the 214,787 rows are the register and the mark sheet.** The next
line down is money, at 4,845 rows.

### The two questions that decided the change

Not "is attendance important" but "what does the audit row hold that the row it
describes does not". Both answers were read off the rows.

**1. An INSERT audit row on those three tables IS the row again.** `audit_log`
holds `actor`, `actor_role`, `created_at` and `after`; `attendance_daily`,
`mark_entries` and `staff_attendance` each carry `marked_by` and `created_at`
of their own; the trigger runs in the same transaction, so the timestamps are
the same value; and `after` is `to_jsonb(new)`, which is the row. Checked on
every one of them:

```
entity              insert_rows   actor = after->>'marked_by'
attendance_daily         89,634                       89,634
mark_entries             10,794                       10,794
staff_attendance         11,654                       11,654
```

No exceptions in 112,082 rows. The only field the audit row holds that the row
does not is `actor_role`, and "what title did the teacher hold on the third of
March" is not a question anybody asks about an attendance mark. 0126 gives that
up and says so.

**2. Every UPDATE audit row on those tables was one boolean.** Asked which keys
actually differ between `before` and `after`:

```
entity              changed keys     rows
attendance_daily    {is_locked}    89,432
mark_entries        {is_locked}     5,295
```

Nothing else, anywhere. That is `fn_finalize_attendance` and
`fn_lock_assessment`, which set `is_locked` on every pupil of a section-day or
every mark of a test in one statement: 210 rows of a kilobyte each to record
one act by one person.

### Where F12's proposal was wrong

F12 said "ignores a first-time mark and a finalisation". The first half is safe.
**The second half would have deleted the only record of who closed a register.**
`fn_finalize_attendance` and `fn_lock_assessment` wrote no audit row of their
own, and `assessments` carries no audit trigger at all, so those 94,727 rows
were the entire trail. Skipping them and stopping there is a bigger loss than
the 87 MB is a gain.

So 0126 does the replacement first. Both functions now write one row, in the
same shape `fn_unlock_attendance` already used since 0121:

```
ATTENDANCE_FINALIZE   one row per section-day, entity_id = the date,
                      after = {locked, rows, session_id, class_id, section_id}
ASSESSMENT_LOCK       one row per test, entity_id = the assessment
```

210 rows become 1, and the 1 is a sentence: *Miss Ayesha finalised 5-A for 3
March, 34 pupils*. Thirty-four rows each saying a boolean changed is not.

### The skip is deliberately one-directional

`false -> true` is dropped; `true -> false` is not. Reopening a register is
already audited by `fn_unlock_attendance` with its reason, so the per-pupil
rows for an unlock are redundant too and skipping them would save a few
thousand more. It is still wrong. Today `fn_unlock_attendance` is the only
route that clears the lock; the day a second route is added and its author
forgets the audit row, a one-directional skip still records it and a symmetric
one loses it silently. A few thousand rows is a cheap price for not having to
be right about the future.

### The rows already written

A rule that only applies going forward leaves every existing school paying for
the old one, which is the actual complaint that started this. So 0126 removes
them, and nothing is lost doing it:

* the lock rows are **folded first** into the `ATTENDANCE_FINALIZE` and
  `ASSESSMENT_LOCK` rows they should always have been, carrying the original
  actor, role, timestamp and count, and only the exact ids that were folded are
  then deleted;
* an insert row is deleted only if **its own** `actor` equals the `marked_by`
  on **its own** `after` image, so the losslessness is checked per row rather
  than trusted from the survey above;
* anything that fails either test is kept, and the migration says how many and
  why.

Checked afterwards against the register itself: all 9,505 rebuilt
`ATTENDANCE_FINALIZE` rows carry a pupil count equal to the number of locked
rows in that section-day. Zero disagreements. All 570 `ASSESSMENT_LOCK` rows
agree with their assessment's mark count. Every rebuilt row kept its actor and
its role.

### Measured after

```
audit_log      214,787 rows  479 MB   ->   18,053 rows  11 MB
the database                 571 MB   ->                103 MB
```

**468 MB back on one school, in 16 seconds.** On Supabase's 500 MB free tier
that is the difference between one school over quota and four schools inside
it. Extrapolating F12's arithmetic, the ~90 MB of audit log per school per year
becomes about 5 MB.

Deleting does not return the space on its own: Postgres marks a row dead and
reuses the page later, and the file does not shrink. Demonstrated separately, a
table of 40,000 rows at 79 MB, minus 39,800 rows, is still 79 MB, and
`vacuum full` rewrites it to 408 kB. So the bundle ends by telling the reader to
run `vacuum full public.audit_log;` on its own, because VACUUM cannot run inside
a transaction and a pasted file is one.

### Two things found on the way

**`fn_finalize_attendance` was not idempotent, and its return value was wrong.**
Its UPDATE had no `and not ad.is_locked`, so it rewrote every row of the
section-day whether open or closed. The number it returned was therefore
"pupils in this section-day", which the screen prints as *Finalized & locked 34
rows*, and finalising an already finalised day said 34 again. It also made
0126's own audit row wrong: a second press recorded a second closing of a day
that was already closed. Caught by assertion 9 of the new suite. Now it locks
what is open, says how many, and a second press is a no-op. A partly marked day
gets the right answer too: mark 30 of 34, finalise (30), mark the last 4,
finalise again (4, not 34).

**Settings -> Audit log was unreadable, in two different ways, and 0126 forced
both.** The screen printed the database's own words:

```
INSERT   attendance_daily
UPDATE   mark_entries
```

which is a table name and a SQL verb. Worse, it reads the most recent 300 rows
with no filter, so a school that marked its registers this morning saw 300 rows
of `INSERT attendance_daily` and nothing else: the discount somebody gave and
the payment somebody reversed were behind 90,000 attendance marks. The log
recorded everything and showed nothing. And shipping `ATTENDANCE_FINALIZE` to
that screen raw would have been worse than what was there before. Every pair the
database can produce is now named in English, an unmapped pair still renders as
a sentence rather than vanishing, the timestamp shows the time as well as the
date, and there is a search box over who, what and why.

### Still open

The audit log screen shows the most recent 300 rows and has no date range. With
the volume down by 96% those 300 rows now cover months rather than this morning,
which is most of the value, but a school asking about a specific week last year
still cannot get there. That is a paged, date-filtered read and it is its own
piece of work.

---

## F27. The clock pass set 133,000 timestamps and a trigger threw half of them away. **Fixed in the same pass, and the file went from 15.9 seconds to 2.1.**

**Severity: medium, and it is the third file in this simulation to report success
and do less than it said.** `08_the_clock.sql` is the one file that reaches
around the schema as the table owner, because `payments` has no business date
(F1). It sets `created_at` AND `updated_at` on fifteen tables. Measured after it
had run:

| | rows | `created_at` on the right day | `updated_at` on the right day |
| --- | --- | --- | --- |
| `attendance_daily` | 89,634 | 89,634 | **202** |

Every one of the 89,634 `updated_at = attendance_date + time '08:20'`
assignments was discarded, and all 89,634 values carried the minute the seed
ran. `trg_attendance_updated` is a BEFORE UPDATE trigger whose entire body is
`new.updated_at := now()`, so it overwrote each one on the way past. The same
trigger sits on `students`, `enrollments`, `families`, `invoices` and
`mark_entries`: six of the fifteen tables, and roughly half the timestamps the
file claims to move.

Nothing failed. The file printed `attendance 89634` and it had indeed written
89,634 rows, half correctly.

### Turning the row triggers off fixes that and three other things

`alter table ... disable trigger user` on the fifteen tables, for the duration,
inside the same transaction as the re-enable so there is no committed state in
which they are off.

* **The `updated_at` assignments land.** 89,634 of 89,634, and students,
  invoices and mark_entries all check out too.
* **120,000 audit rows are no longer written and then deleted.** Every re-dating
  is an UPDATE and the audit triggers fire on updates, so the file used to write
  a full before/after row per timestamp it moved and delete them all again by
  watermark: about 120 MB of churn producing nothing, and a delete does not
  shrink the file, so the school was left needing a `vacuum full` afterwards.
  Migration 0126 does not help here, and it is worth saying why: 0126 skips the
  audit row when the ONLY difference is `is_locked`, and this file changes
  `created_at`.
* **1,634 count refreshes do not fire.** `fn__refresh_counts_touched` is an
  AFTER trigger on `students` and `enrollments`, and the file updates every row
  of both.
* **15.9 seconds becomes 2.1.**

The cost, stated: an ACCESS EXCLUSIVE lock on each of the fifteen tables while
it runs, and table ownership, which the SQL editor has and a school never does.
If it cannot get ownership the file now stops with that as the reason instead of
half-working. And `09_check.sql` asserts from outside that every row trigger in
`public` is enabled, because a school pasting files by hand can stop between two
of them and a school running with its audit triggers off records nothing and
cannot tell.

### It was going to be split, and did not need to be

This file lost its request on a real project with
`Failed to fetch (api.supabase.com)`, and the plan was to break it into its
table groups the way the four years and the four registers are already broken
up. At 2.1 seconds that would be one more file to paste for no reason. One more
file is a real cost to the person pasting them.

### Two more things the same pass found

**Migration 0126 made this file incomplete, in a way only counting would show.**
`fn_finalize_attendance` and `fn_lock_assessment` now write one audit row each,
keyed on the DATE and on the ASSESSMENT rather than on a row id, so none of the
five id joins can reach them. On the finished school that is 9,598 finalise rows
out of 18,527 in the whole log: leaving them out means the MAJORITY of the audit
log still claims two years of registers were closed this afternoon. Each now has
its own statement, dated to when the thing actually happens (a register closes at
half past one, a reopening happens at twenty to ten the next morning when the
father turns up with the letter, a test is locked at five).

**Six statements had no skip guard, so the count they printed was "rows
rewritten" while the line above said "timestamps moved onto their real dates".**
Same species of untruth as the rest of this finding. One of the six was worse
than untidy: `admission_enquiries.updated_at` was computed from `admitted_at`,
which the same statement overwrites, so a second run read what the first had
written and produced a different answer. Every statement now skips the rows that
are already right, and a second run reports zero and means it. Verified: run,
run again, all zeros.

### The whole set, end to end, from a database built out of the bundles

All thirteen generated paste files, each its own transaction, in order:

```
1_set_the_school_up      0s     8_register_2025_2026    17s
2_year_2023_2024         3s     9_register_2026_2027    10s
3_year_2024_2025        85s    10_tests_and_exams        6s
4_year_2025_2026        40s    11_the_drawer             9s
5_year_2026_2027        26s    12_set_the_clock          2s
6_register_2023_2024     3s    13_check_it_worked        1s
7_register_2024_2025    15s
                                            total     217s
```

`13_check_it_worked` reports: *BELIEVABLE. 173,173 rows, 224 children on the
roll, 90,474 attendance rows over 590 days, 722 result cards, audit log spans
790 days, audit log is 18.4% of the database.* The database is 114 MB. Before
0126 the same school was 439,000 rows and 571 MB.

**The longest file is now file 3 at 85 seconds**, not file 12. If anything in
this set loses its request on a slow instance again, that is where to look
first.

### The seed now refuses to run without bundle 32

Every file's prerequisite block gained a question. Without migration 0126 this
seed produces 571 MB for one school, which is more than a free Supabase project
has in total, and the failure arrives days later as a full database rather than
as an error. So file 1 says so instead:

```
ERROR:  Paste supabase/bundles/32_the_register_was_written_twice.sql first.
        Without it every attendance mark this seed makes is copied into the
        audit log as a kilobyte of before/after JSON, and so is every pupil of
        every finalised day: 571 MB for this one school instead of 110 MB,
        which is more than a free Supabase project has. Nothing else about this
        set changes.
```

### The two assertions that would have failed on a school that trimmed its own log

Both were written the same afternoon and both were wrong in the same way: they
asserted how much HISTORY the audit log holds, on a database whose owner had
just deleted most of it by hand to free space, which is exactly the situation
this whole pass exists to fix.

* *at least 300 registers recorded as finalised* is now REPORTED and not
  asserted. On a school seeded after bundle 32 there is one row per section-day,
  about 9,600. On a school whose registers were closed before bundle 32, or
  whose log was trimmed, there are none and there is no way to make any: the
  per-pupil rows they would be rebuilt from are what was removed. Failing there
  would stop the file reporting anything else about a school that is otherwise
  fine, over something its owner cannot put right. The invariant is asserted
  where it can be acted on: `verify.sql`, `detect.sql` and
  `supabase/tests/audit_volume.sql`.
* *the audit log spans at least 300 distinct days* is now a CONCENTRATION test.
  What distinguishes a clock pass that ran from one that did not is not how long
  the history is, it is whether every row is piled on the same day. So: if more
  than half the rows share one date, the pass did not run. Proved both ways on
  real databases: the trimmed school passes, and the same school with
  `update audit_log set created_at = now()` fails with *2000 of the audit log's
  2000 rows are on one single day, so the clock pass did not run.*

---

## F28. Nobody was ever asked which plan they were on, and three places disagreed about what the answer was. **Fixed in migration 0127.**

**Severity: high. Two of the three faults are wrong numbers about money, and one
of them is a wrong number sent to the customer.**

Reported by the vendor, looking at Settings on a school he had just created:
*"a starter plan is by default, annual payment showing in the settings. When
they create a school the system should give them a choice to pick a plan and
pick how they will want to continue: monthly, quarterly or yearly."*

### Fault 1: the choice is not offered, and the default is silent

`fn_signup_school`, in full, on the subscription it creates:

```sql
insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
values (v_id, 'starter', 'trialing', current_date + 14);
```

Plan hardcoded. `cycle` left to the column default of `yearly`. `term_months`
left to the column default of 12. So every school in the console is on Starter
paying annually whatever was agreed on the phone. It is not a display bug:
`fn_my_next_payment` prices the next charge from `term_months`, so a school that
agreed Rs 2,000 a month is shown **Rs 20,000** and told that is what is due when
the trial ends.

### Fault 2: quarterly is priced and cannot be recorded

`plans.price_quarterly` is populated for all three sold plans, is charged by
`fn__plan_price`, and is one of the three terms `fn_my_next_payment` offers the
school. And:

```
select enumlabel from pg_enum ... where typname = 'billing_cycle'
  monthly
  yearly
```

There is no `quarterly`. `fn_activate_subscription` writes
`case when p_months >= 12 then 'yearly' else 'monthly' end`, so a school paying
every three months gets an invoice, a console entry and a credit note that all
say monthly.

### Fault 3: the renewal quote is worked out from the wrong column

Two places decide how many months the next invoice covers by guessing from the
cycle:

```
fn_platform_due_soon         case when b.cycle = 'yearly' then 12 else 1 end
fn_platform_renewal_message  case when v.cycle = 'yearly' then 12 else 1 end
```

The invoice is not built that way. `fn__renewals_due`, which actually creates
it, prices `fn__plan_price(sub.plan_code, sub.term_months)`. And
`fn_activate_subscription` never wrote `term_months` at all, so the two diverge
the moment a school uses the term chooser in Settings:

| cycle | term_months | quoted | invoiced | the school is told |
| --- | --- | --- | --- | --- |
| yearly | 12 | 12 months | 12 months | correctly |
| monthly | 3 | 1 month | 3 months | a **third** of the truth |
| monthly | 12 | 1 month | 12 months | a **twelfth** of the truth |
| yearly | 1 | 12 months | 1 month | **twelve times** the truth |

Staged on the pre-0127 schema rather than reasoned about:

```
BEFORE 0127: cycle=yearly term_months=1
  invoice will be Rs 2,000
  console worklist quotes Rs 20,000
  WhatsApp message to the school says Rs 20,000
```

`fn_platform_due_soon`'s own comment says *"priced on the plan they SHOULD be on
and the cycle they are on now, so the number in the reminder is the number on
the invoice"*. That is the right intention and the code does not do it.

### And a loophole found by building the form, not by reading the code

The `custom` plan is active, is named "Custom (601+ students - contact us)", has
`price_monthly`, `price_quarterly` and `price_yearly` all zero, and has
`student_limit` **NULL**. Null means no limit at all:
`plan_margin_limit(null)` is null and `fn_my_licence` reports `limit_state` `ok`
for any roll. So a school choosing it on the signup form would have got
unlimited pupils, for nothing, for ever, with every renewal invoice for Rs 0.

Signup now accepts only a plan with `price_monthly > 0`, expressed as "has a
price" rather than as "is not called custom", so a second by-arrangement plan
added later is barred by the same clause instead of walking straight through it.

### What does not change, and it was checked rather than assumed

* `fn_choose_term` still does not touch `cycle`, which is correct. `cycle`
  labels the period that was invoiced; `term_months` is the intent for the next
  one. A school switching to monthly halfway through a year it has paid for must
  not have that year relabelled.
* The 14-day trial applies to every plan and every term. A trial is fourteen
  days of the software, not fourteen days of a price, and making it depend on
  the plan would give a school a reason to pick the wrong one.
* No existing school's plan, term or cycle is rewritten. The migration cannot
  know what a school that was never asked would have said, and guessing would
  put a school on a plan it did not pick. What it does instead is make the
  choice reachable and visible.

### On the form

Monthly is the preselected term, not yearly, and that is a deliberate reversal
of what the code did by accident. Preselecting the largest charge on a buying
screen is a dark pattern, and it is the exact complaint that started this. The
yearly saving is shown in rupees beside the yearly button so a school can choose
it for its own reasons. It converts better too: the first invoice after the
trial is Rs 2,000 rather than Rs 20,000.

The prices come from `fn_signup_plans`, granted to `anon`, and not from the
browser. `fn__plan_price` is a rule and not a lookup: it takes the cheaper of
the laddered price and the cheapest single standard term that covers the period,
and falls back to the monthly rate when a quarterly rate is zero. A browser copy
would agree with the invoice until any of the nine rates moved. Worked through
the cases: on a price list where `price_quarterly` is zero, a three-month term
costs `least(monthly * 3, yearly)`, which a naive copy would get wrong.

### Three things found in the writing

**`ALTER TYPE ... ADD VALUE` inside the one transaction a pasted bundle is.**
Allowed on Postgres 12 and later; what is not allowed is USING the new value in
that same transaction. Verified both ways on Postgres 16:

```
begin; alter type bc add value 'c'; select 'c'::bc;
ERROR:  unsafe use of new value "c" of enum type bc
HINT:   New enum values must be committed before they can be used.
```

So the existence check reads `pg_enum` by label text and never casts;
`fn__cycle_for_months` is plpgsql rather than sql, because a plpgsql body is
parsed on first execution and a sql body is parsed at CREATE, where the literal
would be checked and refused; and nothing else in the file evaluates the value.

**`RAISE` takes a bare `%`, not `%s`.** Written by habit as
`'The %s plan is priced by arrangement'`, which printed
`The Custom (601+ students - contact us)s plan`: the `%` consumes the argument
and the letter is left in the sentence. Silent until somebody hits the error,
which is the moment they most need it to read cleanly.
`scripts/check-raise-format.py` now refuses the shape across 2,476 RAISE format
strings, scanning only the format string so `format('%s', x)` passed as a RAISE
argument stays legal. It found one other, in 0056, which is frozen inside a
shipped bundle and is therefore recorded rather than fixed.

**A FOURTH guard for one rule, and I had updated three.** Granting
`fn_signup_plans` to `anon` trips "unauthenticated callers can run nothing",
asserted in `verify.sql`, `detect.sql`, `scripts/preflight.sh` and
`supabase/check-definer-idor.py`. A grep for `has_function_privilege('anon'`
found three; preflight found the fourth. This is F25's lesson repeating inside
the same week.

The exemption is not a bare name in any of them. It holds only while the
function cannot write (stable or immutable) and references nothing in `public`
except `plans` and `fn__plan_price`. Proved to fail both ways: by making the
function volatile, and by opening a second function to `anon`.

And fixing that exposed a broken diagnostic of my own. The `verify.sql` row
carried **two** copies of the predicate, one for the PASS test and one for the
FAIL message, and the FAIL message excluded the exempted name from the list it
names. So when the exemption itself failed, `string_agg` over an empty set was
null, `'FAIL: ' || null` was null, and the row rendered as:

```
unauthenticated callers can run nothing (0071)|
```

An empty verdict. A diagnostic that goes blank when it fails is worse than no
diagnostic. The list of offenders IS the test now: null means nothing is open.

**And `verify.sql` cannot CALL a function it is checking for.** A function
reference is resolved when the statement is parsed, not when the CASE arm is
reached, and casting a constant to `regprocedure` is folded at plan time. Both
spellings brought the whole file down on any database without bundle 33, which
is every database the file exists to diagnose:

```
ERROR:  function public.fn_signup_plans() does not exist
```

`pg_get_functiondef(to_regprocedure('...')::oid)` is the safe idiom:
`to_regprocedure` returns null for a missing function and
`pg_get_functiondef(null)` is null.

### And then CI failed on the push, three steps away from the cause

`re-pasting the bundles changed a function body`, naming eleven of them:
`fn_enter_marks`, `fn_generate_result_cards`, `fn_global_search`,
`fn_platform_ledger`, `may_view` and six more. None of which 0127 goes near.

The chain, established by reproducing it rather than by reading: built the
bundles database at bundle 32 and re-pasted, which changed nothing; built it at
33 and re-pasted, which did. Bundles 1 and 3 roll back on a second paste and
always have (`type "user_role" already exists`), and that is harmless. **Bundle
7 started rolling back too**, on this:

```
ERROR:  function public.fn_signup_school(text, text, text, text, text) does not exist
CONTEXT:  grant execute on function
          public.fn_signup_school(text, text, text, text, text) to service_role
```

0071 grants that signature, hardcoded, and 0071 is inside a bundle a school has
already pasted, so it cannot be edited. 0127 dropped the signature to add two
parameters. Bundle 7 is otherwise idempotent, so unlike bundles 1 and 3 it
normally re-applies cleanly and reaches that grant. Rolling back meant bundle
7's own definitions were absent from the replay, and the later bundles that
patch functions from their own text then patched a different starting text.
Pasting a bundle twice is exactly what a school does when it is not sure the
first one took.

**Two overloads of one name would not have worked either.** The existing five
parameters carry defaults on arguments two to five, and Postgres requires any
added parameter to carry one too, so a five-argument call matches both
candidates:

```
ERROR:  function f(unknown, unknown, unknown, unknown, unknown) is not unique
HINT:   Could not choose a best candidate function.
```

Both shapes tried on Postgres 16. So the answer is a second NAME:
`fn_signup_school_on_plan` holds the implementation, and `fn_signup_school`
keeps its exact signature as a delegate passing the two defaults it used to
hardcode. 0071's grant resolves for ever, an Edge Function deployment that
predates the migration keeps working, and there is one copy of the rules. The
Edge Function calls the new name and falls back to the old one on "does not
exist", so the two are deployable in either order.

Asserted three ways now: guard 2b inside the migration, a `verify.sql` clause,
and assertions 33 to 35 of the suite.

### Fixing that exposed one more, on one database out of four

`check-definer-idor.py` reported `fn_signup_school` callable without a login,
on `migcheck` and on none of the fresh installs. Because on a fresh install the
five-argument function already exists and `create or replace` inherits its ACL;
on `migcheck`, which had had the drop-and-recreate draft applied, the same
statement was a CREATE, and **on a real Supabase project a newly created
function is granted to `anon` by default privilege.** That is F25 exactly. An
ACL that depends on which draft of a migration a database happened to see first
is not an ACL, so both signatures now have their grants stated outright.

### The durable fix is about the tooling, not the code

`scripts/preflight.sh --quick` printed the same **"PREFLIGHT CLEAN. Safe to
push."** as a full run, while skipping the four passes that exist only because a
school pastes bundles by hand: the fresh installs, the CRLF spelling, the
re-paste comparison, and the upgrade. The re-paste comparison is the one that
catches this, and a clean quick run had said it was safe.

The script already carried this, in a comment above the CI-gaps block:

> A checker that does not say what it skipped is claiming more than it checked,
> which is the same fault as one that lies.

True of the CI steps it lists, and not true of its own mode. Quick mode now
names all four skipped passes and says to run the full one before pushing
anything that adds, drops or rewrites a function.

**A static checker was written for this and then deleted.** It extracted every
`grant execute on function` signature from every migration and asserted each
still existed. It found **fourteen** pre-existing cases, all harmless, because
their bundles roll back earlier on a second paste and never reach the grant.
Distinguishing harmful from harmless needs exactly the two-pass database
comparison that already exists, so the checker would have been fourteen
exemptions nobody maintains: a guard that cries wolf, which is worse than none.

### The second red CI, and it was the same root cause as the first

`operator_billing.sql` assertion 23:

```
FAIL  23. six months on starter is charged monthly - 6 x 950 - not a pro-rated year
```

That assertion is about the AMOUNT, and the amount had not moved: the suite pins
`price_quarterly` to zero, so six months falls back to six times the monthly
rate, 5,700, rather than being pro-rated off the yearly price. What it ALSO
asserted, incidentally, was `cycle = 'monthly'`, which was only ever true
because the enum had no other value to offer. 0127 gives it one. Six months is
quarterly now, which is the nearest standard term at or below its length and is
what the price ladder charges it as. The assertion says so, and says why.

**And the same root cause as the first red CI: I pushed on a quick preflight.**
Quick mode does not run the two fresh-database installs, the CRLF pass, the
re-paste comparison, the part-way diagnostics, or **any SQL suite at all**. My
first fix for that wrote the skipped list by hand, and it was wrong within the
hour: it named the four bundle passes and left out the sixty-seven SQL suites,
which is the section that then caught this. A hand-kept list of what a checker
skipped is a second thing to keep in step, and the whole message existed
because the first one had not been kept in step.

It is derived from the script now, by reading its own `if [ "$QUICK" = 0 ]`
block for section headers, so adding a section adds it to the list:

```
QUICK PREFLIGHT CLEAN, AND QUICK IS NOT THE WHOLE OF IT.

Skipped, every section that needs a database of its own:
  fresh databases, both install paths
  the same bundles, on a database whose bodies are CRLF
  the diagnostics, on a database part-way through the bundles
  every SQL suite, on the fresh migrations database

So: no SQL suite ran, no bundle was pasted, and nothing was checked
on a database built the way a school's is. Run it without --quick
before pushing anything at all that touches supabase/.
```

The full run, which is what should have happened twice already: 80 verify rows
none failing on four separate databases, 336 function bodies unchanged by a
re-paste, 334 bodies stored CRLF, the upgrade path, and 67 SQL suites forwards
and in reverse. `PREFLIGHT CLEAN. Safe to push.`
