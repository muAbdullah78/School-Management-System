# The operator's own books — the design, and the argument against each decision

This product answers, for a school: who owes money, how much, what did they pay,
what did we collect this month. The person **selling** the software is running
the same business one level up, against schools — and could answer none of it.

The operator console already existed: every school, its plan, its status, its
expiry, its student count against the plan limit, and a suggested plan. All of
that is sound and stays. What follows is what it did not do.

---

## 1. What was actually wrong

Three customer schools — one paying, one on trial, one expired. Al-Noor renews
for twelve months on `growth`:

```
select fn_activate_subscription(<al-noor>, 'growth', 12);
→ {"period_start": "2027-07-26", "period_end": "2028-07-25", ...}
```

| Question the operator has to answer | The answer today |
|---|---|
| What was Al-Noor **charged** for that? | no table records a charge to a school |
| How much has Al-Noor paid us, **ever**? | no function answers it |
| Which schools **owe us** money right now? | unanswerable — see 1c |
| What did we invoice and collect **this month**? | `plans` holds a price list, nothing else |
| **Who** granted that subscription, and when? | nothing records the actor; `audit_log` had 0 rows for it |

**1a. Granting time recorded no money.** `fn_activate_subscription` moves
`period_end` twelve months forward and writes nothing about Rs 20,000. The
software's central promise to a school — every rupee has a row — was not kept by
the operator's own half of it.

**1b. No revenue figure of any kind.** Not per school, not per month, not in
total. A price list is not a ledger: `plans` says what `growth` costs, and
nothing says who was charged it.

**1c. An expiry date is not a debt.** This is the subtle one. The console shows
`days_left`, so it looks like it answers "who do I chase?" — but a school that
renewed on trust and never paid is **indistinguishable** from one that paid in
full. Both show 335 days left. The operator's real receivable is invisible
precisely because the screen looks like it is showing it.

**1d. Nothing recorded who acted.** An operator with a partner or an assistant
cannot tell who gave a school a free year.

**1e. And a revenue leak, found in the same probe.** Al-Noor is on `growth`
(limit 300) with **420 students** — the console itself computes
`limit_state = 'over'` and `suggested_plan = 'institution'` — and
`fn_activate_subscription` renewed it onto `growth` for another twelve months at
the 300-student price. The screen knew, the renewal path did not ask. The one
number the console exists to protect is the one it quietly gave away.

---

## 2. Decisions

### D1 — A charge is a row, written by the same call that grants the time

`platform_invoices`, written inside `fn_activate_subscription`, in the same
transaction that moves `period_end`. Not a second step.

**The objection:** an operator often grants time with no money attached — a
pilot, a favour, an apology for an outage. Forcing an invoice makes those look
like unpaid debts.

**Why it still wins:** `amount = 0` **is** a charge, and recording it as one is
the point. A free year that leaves no trace is how a business loses track of what
it has given away — and 1e is the same mistake in a different place. The amount
defaults to the plan's list price for the cycle, and an override **away from list
price requires a note**, so a discount is always a discount somebody wrote a
reason for.

### D2 — Payments are their own rows, and outstanding is DERIVED

`platform_payments`, and `fn_platform_outstanding(school)` =
`sum(invoices.amount) − sum(payments.amount)`. Never stored.

This is the rule the school-facing side already follows for exactly the same
reason: a stored balance drifts from the rows that produced it, and then two
screens disagree about what a customer owes.

**A payment may be unallocated.** `invoice_id` is nullable. The school side needs
a real allocation engine because a parent's payment must be split oldest-month-
first across several children; the operator side has one customer paying a
handful of invoices a year, and netting per school is both correct and something
a human can check by eye. Building an allocation engine here would be machinery
with no defect to prevent.

### D3 — Renewing a school onto a plan it has outgrown is refused

`fn_activate_subscription` refuses when the school's student count exceeds the
target plan's limit beyond the 10% margin, naming the count, the limit and the
plan that fits. Overridable with an explicit flag, and the override goes in the
invoice note.

**The objection:** the operator may have a good reason — a school mid-migration,
a promise already made on the phone.

**Why the refusal is still right:** the alternative is what 1e found. The
information was on the screen and the renewal ignored it, so the wrong price was
charged silently. A refusal that names the right plan turns a silent loss into a
one-word decision.

### D4 — Every operator action lands in the school's audit log

`audit_log` is school-scoped and its `school_id` is `NOT NULL`, so an operator
action is recorded **against the school it concerns** — which also means the
school's own owner can see "your subscription was activated until 2028-07-25".
That is a feature, not a leak: it is their subscription.

`actor_role` stays null. The operator has no `profiles` row and therefore no
`user_role`, and inventing one would put a non-school identity into a
school-scoped enum.

Written explicitly rather than by `audit_trigger()`, because that trigger reads
`current_school_id()` and an operator belongs to no school — it would fail the
`NOT NULL`.

### D5 — These tables do not widen the operator's reach

`platform_invoices` and `platform_payments` are keyed on `school_id` and readable
only by `is_platform_admin()`. No policy on either mentions `current_school_id()`.
Adding the billing books did not give the operator one extra tenant row.

> **Superseded in part, and it matters.** This section originally read *"the
> operator still cannot read tenant data"*, and at the time that was true: the
> platform role could see schools, subscriptions, plans and counts, and never a
> child, a parent, a mark or a fee.
>
> That boundary was later **removed by an explicit decision** — support needs to
> see what a school is describing on the phone. Migrations 0073 and 0074 give the
> operator full permanent READ across every school, and the design is in
> [`SUPER-ADMIN-DESIGN.md`](SUPER-ADMIN-DESIGN.md): it goes through a session the
> operator must open with a reason, every read is inside it, the school sees a
> banner while it is open and a list of every visit afterwards, and the session is
> read-only — `check-readonly-writes.py` asserts in CI that no write path consults
> it.
>
> The claim about these two tables is still exactly true. The broader sentence is
> not, and a design document that keeps a superseded security claim is worse than
> one that never made it.

The student count these decisions turn on is already a denormalised integer on
`subscriptions`, maintained by `fn_refresh_student_count`. A count is not data
about a child.

---

## 3. What is deliberately NOT built

- **A school-facing view of its operator invoices.** Arguably a school should see
  its own bill. But the licence banner already tells them their status and expiry,
  and a billing surface inside the tenant app is a new product decision — pricing
  visibility, tax handling, who may see it — not a line of SQL. Platform-only for
  now.
- **Online payment collection.** Taking card or wallet payments from schools means
  a payment processor, webhooks, refunds and a compliance surface. The operator
  collects by bank transfer today; this records what was collected.
- **Automatic invoicing on renewal date.** Nothing here runs on a schedule. An
  invoice is written when the operator grants the time, which is when the operator
  is actually looking at the screen.
- **Tax, GST or withholding.** A single `amount` with a note. Getting Pakistani
  sales-tax treatment right for a software service is a real piece of work and
  guessing at it would put wrong numbers on a document somebody files.
- **Offboarding a school.** Still not possible, and 0064 does not change it: 34
  tables reference `public.schools` with `ON DELETE NO ACTION`, so `delete from
  schools` fails outright. That is right as a safety property — nobody should
  erase a school by accident — but it means there is no path for a school leaving
  the platform or for a data-deletion request. Recording what a departing school
  owed is now possible; removing them is not. That gap is unchanged and still
  open.

---

## 4. What this can and cannot prove

`supabase/tests/operator_billing.sql` rebuilds the scenario from section 1 and
asserts the corrected behaviour: the invoice written by the renewal, the list
price applied and the discount refused without a reason, the outstanding figure
moving on payment and not on renewal, the over-limit renewal refused by name, the
audit row, the revenue totals, and that a school user — owner included — can read
none of it.

What a test cannot decide is what the operator should actually charge. The prices
come from `plans`, which the operator sets.
