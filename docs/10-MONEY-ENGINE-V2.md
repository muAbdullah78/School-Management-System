# The money engine, version 2 — design

This is a **design document, not code.** Nothing here is built yet. It exists so
that when we do build it, we build it once.

It supersedes nothing. The fee engine described in [`03-FEATURES.md`](03-FEATURES.md)
and implemented in migrations `0002`, `0017`–`0021` still stands; this document
describes the layer that goes on top of it and the three places where the
existing logic has to change.

---

## Why this exists

A teardown of OurSchoolSoftware's live panel (30 pages of screens and menus,
August 2026) found that our money engine is stronger than theirs on **integrity**
and weaker than theirs on **operations**. Specifically:

Ours is better at proving what happened — append-only records, gapless receipt
serials, discount approval with separation of duties, expected-vs-collected
reconciliation, a ghost-student check. Theirs can *delete a fee record*; there is
a "Deleted Fees" screen and a "Recycle Bin" in the sidebar. We should not copy
that, and we should say so out loud in every sales conversation.

Theirs is better at the thing that happens two hundred times a day: **a parent
standing at a counter with cash for three children.** They search by the father's
CNIC, pull up every connected student, take one payment, print one voucher, and
send one message. We make the clerk do three separate transactions.

That gap is not a screen. It is a level in the data model that we do not have.

---

## The core decision: the student keeps the ledger, the family holds the wallet

There are two ways to introduce families, and picking the wrong one costs a
rewrite later.

**Rejected — family invoicing.** One invoice per family per month, with lines per
child. It reads well on a whiteboard and falls apart in practice: fees are set
per class, discounts are granted per student, students leave mid-year, and a
sibling graduating must not disturb the other children's history. Every report we
already have would need rewriting.

**Chosen — student ledger, family wallet.**

- **Invoices stay per student.** Charges, discounts, fines, adjustments and
  arrears all remain exactly where they are today.
- **Payments belong to a family.** One payment, one receipt number, allocated
  across whichever children's invoices it clears.
- **Unallocated money is family credit** — an explicit, queryable balance rather
  than an accidental negative number.

Everything we have already built survives. The family layer sits above it.

### The consequence that matters

Today `student_balance()` computes payments as:

```sql
- sum(p.amount) from payments p where p.student_id = X and p.status = 'verified'
```

**That has to change.** Once a payment can span three children, the amount does
not belong to any one of them — it belongs to the invoices it cleared. The new
rule:

```sql
- sum(a.amount) from payment_allocations a
    join invoices i on i.id = a.invoice_id
    join payments p on p.id = a.payment_id
  where i.student_id = X and p.status = 'verified'
```

This is a better definition regardless of families, and it is what makes advance
payment work correctly and for free: money that has not been allocated to any
invoice is not subtracted from any student. It sits in the family wallet, where
it plainly belongs.

---

## Schema additions

### `families` — the payer

```
families
  id, school_id
  head_name                 -- "Muhammad Aslam"
  head_cnic                 -- the natural key at the counter; unique per school, nullable
  phone, whatsapp
  address
  created_at, updated_at
```

`students.family_id` — every student belongs to exactly one family. On admission:
if the father's CNIC matches an existing family, join it; otherwise create a
single-child family. **The existing `guardians` table stays** — it holds the
contact people (father, mother, uncle who does pickup). `families` is the
*billing* entity. They are different concepts and conflating them would be a
mistake.

Backfill for existing schools: one family per student, then let
`fn_link_students` (which already detects siblings) propose merges for review.
Never auto-merge on a name match — merging two families is destructive.

### `payments` — gains a family, loosens a student

```
payments
  + family_id      uuid not null references families(id)
    student_id     -- kept, now nullable: set only for single-student payments
  + till_session_id uuid references till_sessions(id)
```

`student_id` is retained so every existing single-student code path keeps working
and so a receipt can still say "this was for Ahmed". For a family payment it is
null and the children are derived from the allocations.

### `till_sessions` — per-collector cash control

```
till_sessions
  id, school_id
  opened_by, opened_at, opening_float
  closed_at
  counted_cash              -- what the clerk physically counted
  expected_cash             -- computed: float + cash payments in this session
  variance                  -- counted - expected, stored, never recomputed
  variance_reason           -- required when variance <> 0
  approved_by, approved_at  -- owner/principal signs off
  status                    -- 'open' | 'closed' | 'approved'
```

One open session per user at a time. Every cash payment attaches to the opener's
session. Closing requires counting; a non-zero variance requires a reason; the
variance is never silently absorbed.

This is the control OurSchoolSoftware has and we do not. Their fee screen shows
"Income Today — **only by you**" and their Accounting menu has "Accounts
Settlement". It makes each clerk personally accountable for a number at 4pm.
Our Day Book tells the owner what the *school* collected, which is a weaker
question.

### `expense_categories` / `expenses` / `other_income` — so an owner can see profit

```
expense_categories   id, school_id, name, sort_order, active
expenses             id, school_id, spent_on, category_id, amount, payee,
                     method, note, recorded_by, reversal_of, created_at
other_income         id, school_id, received_on, source, amount, method,
                     note, recorded_by, reversal_of, created_at
```

Both append-only with a `reversal_of` column, the same discipline as `payments`.

**Fee income is never hand-entered.** It is derived from verified payments. That
is deliberate and it is an anti-fraud property worth stating plainly: nobody can
inflate reported income by typing a number, because the only way income exists is
that a receipt was issued against a real invoice.

Profit = (fee income) + (other income) − (expenses).

Salaries are entered as an expense under a "Salaries" category. That gives an
honest profit number without building a payroll module, which is explicitly out
of scope.

### `invoice_installments` — due dates, not a second ledger

```
invoice_installments
  id, school_id, invoice_id, seq, amount, due_on, created_at
```

Installments drive **due dates and reminders only**. They do not create separate
balances and they do not participate in allocation. An invoice for Rs 12,000 split
into three parts is still one invoice with one balance; the installments say when
each slice becomes overdue and therefore when a reminder fires. Modelling them as
independent balances would double the ledger for no gain.

### `message_outbox` — channel-agnostic notification

```
message_outbox
  id, school_id
  to_phone, to_name
  template_key              -- 'payment_received' | 'fee_reminder_1' | ...
  payload                   -- jsonb: the resolved variables
  rendered_text
  status                    -- 'queued' | 'sent' | 'failed' | 'suppressed'
  channel                   -- 'whatsapp' | null
  provider_ref, error
  created_at, sent_at
```

Write to the outbox at the moment the event happens, always. Sending is a
separate concern that a worker handles if a channel is configured.

This decouples the WhatsApp decision from the plumbing: even with messaging
switched off entirely, the outbox is a complete record of what the school *would*
have told each parent, and the parent portal can display it. If messaging is
later switched on, nothing upstream changes.

### `invoices` — gains a scannable code

```
invoices
  + voucher_code   text unique per school   -- short, Code128-printable
```

---

## The counter flow, step by step

This is the interaction that happens two hundred times a day. It should take
fifteen seconds.

1. **Find the payer.** Three ways: scan the barcode on the printed voucher, type
   the father's CNIC, or search a student's name/GR. All three resolve to a
   **family**.
2. **Show the family sheet.** Every child, each child's outstanding by month,
   the family total, and the family's credit balance if any.
3. **Take one amount.** The clerk enters what was handed over. Method: cash /
   bank / wallet.
4. **Allocate.** Oldest invoice first, across all children in the family.
   - Default is strict FIFO. It protects the school's cashflow and removes a
     lever a dishonest clerk could pull.
   - **The screen must show what it did** — "Rs 8,000 → Ahmed Nov, Ahmed Dec,
     Fatima Nov; Rs 2,000 held as advance." Silent allocation is what causes
     arguments at the counter.
   - An override (pay a specific month first) is **owner/principal only** and
     recorded with a reason.
5. **Leftover becomes family credit.** Explicitly, visibly, on the receipt.
6. **One receipt, one gapless number**, listing every child it covered, showing
   the remaining family balance and **the name of the clerk who took the money**.
7. **Outbox row written** for the payer.

### Credit is applied automatically at generation

When next month's challan is generated and the family is holding credit, apply
it immediately as a real allocation with a note. Otherwise the family looks like
a defaulter while sitting on money, the defaulter list becomes untrustworthy, and
an untrusted list stops being read.

---

## Fee structure: effective dating, and the annual increment

Today `fee_structures` is `unique (session_id, class_id, fee_head_id)` — one
amount, forever, per session. Editing it changes the future *and* is invisible in
the past.

Past invoices are safe (`invoice_lines` snapshots both description and amount, so
history cannot be rewritten). But a mid-year raise cannot be scheduled and the
change leaves no trace.

**Add `effective_from date` and make the key `(session, class, head, effective_from)`.**
Generation picks the row whose `effective_from` is the latest date not after the
billing month.

Then the annual raise becomes one operation:

```
fn_fee_increment(scope, heads[], percent_or_amount, effective_from, preview boolean)
```

Preview → commit, exactly like `fn_rollover`. It writes new rows; it never
updates old ones. Audited.

Every Pakistani school raises fees every year. In OurSchoolSoftware this is a
menu item ("Generate Fee Increment"). In our current system it is an afternoon of
manual entry across every class and every head — and that afternoon is precisely
when a school decides the software is a burden.

---

## Head-wise dues, and the honest pro-rata rule

"Which fee head is unpaid across the school" — tuition vs exam fee vs admission —
requires attributing collected money to heads. Our allocations are
**invoice-level**, not line-level.

Two options: allocate to heads in a priority order, or **pro-rata across the
heads on the invoice**. Pro-rata is chosen: it is simple, it is defensible, and
priority ordering invites the question "who decided tuition gets paid before
transport, and can they change it?"

The rule must be **written on the report**: *"Collections are apportioned across
fee heads in proportion to their share of each invoice."* A number whose
derivation is hidden is a number an owner cannot defend to an auditor.

---

## What we deliberately do not copy

**Deletable fee records.** Their "Deleted Fees" screen and "Recycle Bin" imply the
primary table no longer holds them. A deletable financial record is a hole in an
accounting system. Ours stay append-only, reversal writes a compensating entry,
and receipt numbers stay gapless so a missing one is a visible hole rather than a
silent absence. This is our strongest architectural argument and we should not
trade it for convenience.

**Bulk fee payment.** Marking many students paid at once is a genuine time-saver
and a genuine fraud vector — it is exactly the shape of "mark 40 students paid,
collect from 40 parents, bank 30". If we build it at all, it is owner-only,
capped, and lands on the reconciliation report as a distinct category.

**Their 25 message templates.** Birthday wishes, staff-late notices, leave
approvals. Noise. Five messages that matter beat twenty-five that train parents
to ignore the sender.

---

## The notification argument, stated once

Their Fee Payment template sends the parent: amount, discount, late fee,
remaining balance, **and the name of the clerk who received the money**.

We built the forensic layer. They built the deterrent. Our expected-vs-collected
report catches a dishonest clerk after the month closes, and only if someone runs
it. Their message makes the theft hard at the moment of collection, because the
parent becomes an independent witness holding a written record with a motive to
complain.

**The recommended list is five, not twenty-five:**

| Template | Fires when | Why it earns its place |
|---|---|---|
| `payment_received` | a payment is recorded | the deterrent — the whole argument above |
| `fee_reminder_1/2/3` | installment due date passes | this is the collections engine, not a courtesy |
| `student_absent` | attendance finalised, child absent | the one message parents genuinely want same-day |
| `result_published` | result card generated | high goodwill, once a term, near-zero annoyance |

Everything is written to `message_outbox` regardless. Whether a channel is
attached is a commercial decision, not an architectural one — but note that
without a push channel the deterrent collapses, because parents will not log into
a portal daily to check for a receipt they are not expecting.

---

## Build order

Each step is independently shippable and independently useful.

1. **`families` + backfill + merge review.** No behaviour change yet.
2. **Rewrite `student_balance` to derive from allocations.** Behaviour-preserving
   for single-student payments; must be proved so by the existing fee test suite
   before anything else lands on top.
3. **Family payment + family sheet + one receipt.** The counter gets 3× faster.
4. **Family credit made explicit** + auto-apply at generation.
5. **Expense ledger, other income, profit on the dashboard.** The owner pitch
   stops being a claim.
6. **Till sessions + settlement.**
7. **Voucher print with barcode + scan-to-collect.**
8. **Effective-dated fee structure + `fn_fee_increment`.**
9. **Installments + due dates.**
10. **`message_outbox`** (written always, sent only if configured).
11. **Head-wise dues report.**

Steps 1–4 are one coherent piece of work and should not be split across releases:
between step 2 and step 4 the system is coherent but the UI is telling a
half-story about where money went.

---

## Open decisions — these are the user's, not mine

1. **Is automated WhatsApp on the table?** It is not on the exclusion list, and
   without a push channel the deterrent layer does not exist. Everything else in
   this document works either way; the outbox is built regardless.
2. **Is the desktop app a window or a real offline system?** Today `desktop/` is
   a Tauri shell around the hosted web app — it needs internet and talks to the
   same Supabase. Marketing it as "desktop software, unlike their website" is not
   currently true. Genuine local-first sync is months of work and a real moat.
3. **FIFO override — owner-only, or clerk-with-reason?** Stricter is safer and
   slower.
4. **Does bulk fee payment get built at all?** See above.
