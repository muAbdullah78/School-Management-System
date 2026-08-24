# Refundable fees — the design, and the argument against each decision

A security deposit is the one kind of money a school takes that **is not its
own**. It is held, and it is repayable. Getting that wrong does not produce a
slightly-off report; it produces a profit figure a proprietor takes decisions on.

Demonstrated on a real database before anything was changed.

---

## 1. What was actually wrong

One pupil, one invoice: Rs 2,000 tuition + Rs 5,000 **refundable** security
deposit. The family pays all 7,000.

| Figure | System said | Truth |
|---|---|---|
| `fee_income` | **7,000** | 2,000 |
| **`profit`** | **7,000** | 2,000 |
| balance sheet `cash_position` | 7,000 | 7,000 (cash is cash) |
| balance sheet liability for the deposit | **0** | 5,000 held |
| ways to refund it | **none** | needed on every leaving |
| functions reading `fee_heads.is_refundable` | **none** | — |

So:

**1a. A deposit counted as profit.** `fn_finance_summary` computes `fee_income`
as the sum of every verified payment, and `profit = fee_income + other_income −
expenses`. A deposit is a payment, so it went straight into profit. A school of
200 pupils on a Rs 5,000 deposit shows **Rs 1,000,000 of profit that is a
liability** — and a proprietor pays a salary or a building instalment out of it.

**1b. Nothing recorded that the money was owed back.** The balance sheet has an
`advance_held` line for unallocated receipts, and a deposit is *allocated*, so it
appeared nowhere on the liability side.

**1c. There was no refund path at all.** Zero functions mentioned a refund. When
a child left, the school owed money back and the system had no way to say so.

**1d. `fee_heads.is_refundable` and the `security_deposit` value of
`fee_head_type` had both existed since the first migration and nothing read
either.** The concept was modelled and never wired — the same pattern as
`students.photo_url` and `enrollments.stream`.

---

## 2. Decisions

### D1 — A refundable charge gets its OWN invoice

This is the decision everything else rests on, and it is forced by an existing
fact: `payment_allocations` allocates to an **invoice**, not to a line.

So on a mixed invoice — 2,000 tuition + 5,000 deposit — a payment of 3,000
cannot be split. Nothing in the data says how much of it was deposit. Every rule
I could invent ("deposit paid last", "pro rata", "deposit first") is a rule a
parent can argue with at the counter and the school cannot defend, because it
exists only inside the software.

Therefore: **an invoice may not mix refundable and non-refundable lines.** A
deposit is billed on its own invoice, and "how much deposit has this family
paid" becomes exactly "allocations against their deposit invoices" — with no
allocation-order rule anywhere.

**The objection:** it means one more slip at admission time. A family gets a
tuition challan and a deposit challan rather than one combined.

**Why that is acceptable, and arguably better:** a deposit is a once-ever charge
at admission, not a monthly one, and a separate receipt for refundable money is
what the family will want when they come to claim it back four years later. The
cost is one extra printed slip, once.

**Enforced by a trigger on `invoice_lines`,** so it holds no matter which path
inserts the line. Honest about its limits: the trigger reads sibling rows, so two
truly concurrent inserts of different kinds could both pass. That is a
data-entry invariant, not a concurrency defence — a school enters invoice lines
from one screen at a time — and the derived figures stay correct regardless,
because a mixed invoice would be refused at the next line rather than silently
miscounted.

### D2 — Deposits held are removed from income and shown as a liability

`fn_finance_summary` gains `deposits_collected` and **subtracts it from
`fee_income`**, so `profit` stops including money the school must give back. The
balance sheet gains `deposits_held` on the liability side.

**The objection:** this changes a number the school has already been looking at.
Profit will drop.

**Why it still wins:** the old number was wrong in the direction that causes
harm — it told a proprietor they had more than they did. And a school with no
refundable head configured sees **no change at all**, because the sum is zero.
That is the same safe-by-default property as the assessment weighting in 0058:
nothing moves until somebody deliberately configures the feature.

The old figure is not silently replaced either. `fee_income` is now net, and
`fee_receipts_gross` and `deposits_collected` are both reported alongside it, so
a clerk reconciling against the till sees the cash figure they counted *and* the
income figure that excludes the deposit.

### D3 — Netting on leaving is an ADJUSTMENT, never a payment

A child leaves owing Rs 3,000 with Rs 5,000 held. What actually happens is that
the school's liability to the family discharges the family's debt to the school,
and Rs 2,000 goes back across the counter.

The tempting implementation is a `payments` row of 3,000 with a method like
`deposit`. **That would be a lie in the cash reports.** `fn_finance_summary`,
the day book and the till all read `payments`, so 3,000 that nobody handed over
would appear as money taken that day, and the till would not balance.

So the netting is an `adjustments` row of −3,000 with a reason naming the
deposit. `adjustments` exists for precisely this — change what is owed, with a
reason and an approver — and it touches no cash figure. `student_balance()`
already reads it, so the child's balance goes to zero without anything pretending
cash moved.

### D4 — A refund cannot exceed what is held, and cannot be issued twice

Checked against the derived held figure inside the function, in the same
transaction as the insert. Tested by trying.

### D5 — Only an owner or principal may refund

Money leaving the school is an approval, not a clerical act. A clerk can *see*
what is held and *print* the refund voucher; they cannot authorise it. Every
refund row records who did.

### D6 — Refunding before a pupil leaves is allowed, and flagged

A deposit is normally held until leaving, but a school will occasionally refund
early — it was charged in error, or a family is in difficulty. Refusing outright
would just push the school into recording it as an expense, where it would
disappear from the deposit ledger entirely.

So it is allowed, and the refund row records that the pupil was still enrolled,
so the report shows those separately. A rule that can be worked around badly is
worse than one that permits the thing and records it.

### D7 — Deposits held survive the pupil leaving

The report of what is held must include children who have **left but not been
refunded**, because that is exactly the money the school still owes. Excluding
off-roll pupils would make the liability shrink the moment a child left — the
same mistake `fn_report_balance_sheet` already documents avoiding for arrears.

---

## 3. What is deliberately NOT built

- **Interest on deposits.** Nobody asked, and it needs a rate policy, a
  compounding rule and a statement. If a school wants it, it is its own piece of
  work.
- **A forfeiture engine.** A school that keeps part of a deposit for damage
  refunds less and says why in the reason. Rules for *how much* may be forfeited
  for *what* are speculative and would be wrong for most schools.
- **Refund by bank transfer with reconciliation.** The refund records a method
  and a note; matching it against a bank statement is the reconciliation module's
  job, not this one's.

---

## 4. What this can and cannot prove

All of it is ordinary SQL. `supabase/tests/deposits.sql` rebuilds the exact
scenario from section 1 and asserts the corrected figures — that a deposit is out
of `profit` and on the liability side, that netting moves the balance and not the
cash, that an over-refund is refused, and that none of it crosses a school
boundary in either direction.

The one thing a test cannot decide is whether a given school's deposit is
*legally* refundable in full. That is between the school and the family; the
system's job is to record what was held, what went back, and who authorised it.
