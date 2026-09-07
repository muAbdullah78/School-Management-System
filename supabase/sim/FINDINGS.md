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

## F12. The audit log is seven times the size of the data it audits

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
