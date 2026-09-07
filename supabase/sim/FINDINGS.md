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
