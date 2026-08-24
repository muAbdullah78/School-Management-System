# The `readonly` role, and the silent save

Two things were wrong here, and the second one is not about `readonly` at all —
it affects every role and it is the kind of defect a school discovers by losing
work. Both were demonstrated on a real database first.

---

## 1. What `readonly` actually experienced

`readonly` is in `ADMIN_ROLES` in the app, so it is shown the whole admin
navigation. Asking the database what each of those screens would return:

| Surface | What a `readonly` login got |
|---|---|
| Students, attendance | works |
| **Fees, payments, invoices** | the tables return **zero rows** — the screens look empty |
| **Expenses, till, discounts, certificates, audit log** | same, zero rows |
| **Reports → Debit & Credit** | `Not permitted to read the accounts` |
| **Staff** | `Not permitted` |
| **Dashboard** | shows `collected_month`, `collected_today`, `finance_visible: true` |
| **Fee counter summary** | shows `income_today` |

So the boundary was **incoherent in both directions at once**: the dashboard
showed this role the school's takings, and every screen it could click through to
showed nothing. A user in that seat concludes the software has lost the data.

It is also the **fallback role**. `handle_new_user` gives the first account in a
school `owner` and *every other account* `readonly`, so this is the experience of
any invited login whose role was not set explicitly.

## 2. The worse one: a save that silently does nothing

RLS treats the three write verbs differently, and this is easy to forget:

- **INSERT** with no matching policy → **raises**.
- **UPDATE** and **DELETE** with no matching policy → **affect zero rows and
  raise nothing.**

Every direct-table write in `db.ts` was written as

```ts
const { error } = await sb.from('students').update(patch).eq('id', id)
if (error) throw new Error(error.message)
```

`error` is null when zero rows matched. So a `readonly` user — or an
`accountant`, or anyone hitting a locked row, or anyone whose profile row does not
exist — edits a phone number, presses Save, sees **"Saved."**, and nothing
changed. Reopening the record shows the old value and the school blames itself.

Demonstrated: as `readonly`, `insert into students` was refused with a policy
violation, and `update students set full_name` returned **success, 0 rows**.

The same defect had already produced a second, unrelated bug. When the
`create-teacher` Edge Function is not deployed, `createTeacherLogin` falls back to
`signUp` **without `school_id` in the metadata**, so `handle_new_user` returns
early and creates no profile at all. `updateProfileRole` then updates a row that
does not exist — zero rows, no error — and the function returns success. The
teacher can sign in and is told *"This login is not attached to a school."*

---

## 3. Decisions

### D1 — `readonly` sees everything staff can see, including money

**The objection, and it is a real one:** `readonly` is the fallback role, so an
invited account whose role nobody set would land with sight of the school's
finances. A role that defaults on should default to the *least* privilege.

**Why it still wins:**

1. It is not reachable by a stranger. `handle_new_user` only creates a profile
   when the invite carries a `school_id`, so every holder of a `readonly` account
   is somebody the school itself invited.
2. Two of the three money surfaces already trust it — `fn_dashboard_summary`
   and `fn_family_sheet` show it money today. Choosing to hide money would mean
   following the *minority* precedent and would still leave the dashboard
   showing takings, i.e. it would not actually close anything.
3. A role that cannot see money cannot do the job schools want it for: a
   trustee, an auditor at year end, a proprietor's second-in-command, the head
   office of a two-branch school. Those people want the money and must not touch
   it.
4. The dangerous half is **writing**, and that stays absolutely shut — with a CI
   guard so no future migration can quietly open it.

**What this means for the fallback:** it is now a deliberate, documented default
rather than an accident, and it is stated in the Users screen so an owner
inviting somebody knows what the default grants. A school wanting an account that
cannot see money should be given `class_teacher`, which is genuinely narrower.

**What is NOT built:** a money-blind observer role. That is a *different* role —
"receptionist who can look up a child's class" — and it needs its own enum value
and its own policies. Recorded here rather than half-built by watering this one
down.

### D2 — One helper carries the whole rule

```sql
create function public.may_view(variadic p_roles public.user_role[])
returns boolean as $$ select has_role(variadic p_roles) or has_role('readonly') $$
```

Every read gate becomes `may_view(...)` instead of `has_role(...)`; every write
gate stays `has_role(...)`. So the rule is legible at a glance — *this list may
act, and an observer may also look* — and it lives in one place instead of being
restated in twenty-five function bodies.

**Rewritten programmatically, not by hand.** `pg_get_functiondef` +
`replace(…, 'has_role(', 'may_view(')` + `execute`, asserting the **end state**
rather than that a replacement matched, so re-running the migration is a no-op.
Hand-retyping twenty-five function bodies is how five migrations' worth of fixes
get silently reverted; that has already happened once in this repo.

**Two functions are excluded by name, with the reason in the migration:**
`fn_may_manage_class` and `fn_may_write_school_file`. Both are `STABLE` and both
look like reads, but they are **permission predicates that gate writes elsewhere**
— a teacher's mark entry consults the first, a storage upload policy the second.
Blanket-replacing there would hand `readonly` the ability to write through the
functions that call them. This is the trap in the whole approach and the reason
the exclusion list exists rather than a "stable means read" assumption.

### D3 — A write that changes nothing is an error

`mustWrite()` wraps every direct-table update and delete: the statement now
carries `.select('id')`, and an empty result raises a message naming what did not
happen.

**The objection:** an update that legitimately matches nothing — "set active =
false" on a row already inactive — now raises where it used to pass.

**Why that is still right:** a no-op update the user *asked for* is
indistinguishable, from outside, from a write the database refused. The only way
to tell them apart is to make silence impossible. And the message is specific:
*"That change was not saved — you may not have permission to edit this, or it may
have been changed by somebody else."* Both causes are real and both are worth
saying.

**Where it does not apply:** RPCs. A `SECURITY DEFINER` function raises its own
errors and already reports what it did, which is why every write that matters
(payments, marks, leavings, rollovers) goes through one. `mustWrite` is for the
eleven remaining direct-table writes.

### D4 — The UI stops rendering controls that cannot work

`canWrite(role)` replaces the scattered `role !== 'readonly'` checks. A control a
user is not allowed to use is not disabled-but-present in an ambiguous way — it
is absent, with one line saying why. The database is still the enforcement;
this only stops offering a button that would fail.

### D5 — The fallback teacher-login path passes `school_id`

One-line fix, but it is the difference between a working login and one that says
*"This login is not attached to a school."* And `mustWrite` would now have caught
it loudly instead of returning success.

---

## 4. The guard that keeps it true

`supabase/check-readonly-writes.py` asserts, against the live catalogue:

- no `INSERT`/`UPDATE`/`DELETE`/`ALL` policy mentions `readonly` or `may_view`
- no `VOLATILE` function mentions `readonly` or `may_view`
- `may_view` appears **only** in `STABLE`/`IMMUTABLE` functions and `SELECT`
  policies

It refuses to report success if it finds fewer than twenty `may_view` uses, so a
migration that dropped the helper cannot pass by making the check vacuous — the
same trick `check-definer-queries.py` uses.

`supabase/tests/readonly_role.sql` drives it from the other end: as an actual
`readonly` login, every table it should read is read, and every write verb on
every write path is attempted and must fail — including the UPDATE and DELETE
that used to return success with zero rows.
