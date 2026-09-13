# Two steps to sign up, and a discount that survives to the next invoice

Bundle 37: migrations 0131 and 0132. The reasoning lives beside the code; this
records what is spread across files and the decisions that were taken against
the brief.

## 1. The signup form did two jobs

It asked six facts somebody already knows and then made a commercial decision:
which of three plans, which of three terms, nine prices and two savings figures.
The panel that asked it was the tallest thing on the page.

Plan selection moved to its own screen. The account is created at the end of
step one.

**That is the answer to abandoned signups, and it is the whole of it.** Holding
step one in the browser loses a customer who has already given us everything the
moment they close the tab. Storing the half-filled form means a public,
unauthenticated endpoint holding a stranger's email and phone number: a spam
target and personal data nobody consented to. There is no partial state because
there is no partial state. A school that stops after step one is a real customer
on a real fourteen-day trial, on the first plan on sale, who can change it from
Settings. That is already what happens when the price list fails to load.

The Edge Function's default term became **1 month, not 12**. The form no longer
sends one, and leaving `?? 12` would have put every new school on a yearly term
between the two screens, which is the defect 0127 exists to fix, reintroduced
through a default.

## 2. The plan screen shows the invoice it produces

Every figure comes from `fn_signup_plans`, which is `fn__plan_price`, which is
the function that prices the first real invoice. A browser copy of that
arithmetic would agree until one of the nine rates moved.

**A price that did not load is not drawn as a price.** The first version rendered
the panel whatever happened, so a failed read produced a confident "Due after
your trial: Rs 0" on the screen where a school decides to buy. The whole screen
now stops instead. Caught by `pages.smoke.test.tsx`, which exists for exactly
that.

`fn_my_choose_plan` is new because **no function in the product could write
`plan_code` or `term_months`**, while the signup form has always closed with
"you can change the plan or the term any time from Settings". Settings showed
the plan and nothing more.

What it allows, and why it is narrow:

| | Plan | Term |
| --- | --- | --- |
| Trialing | yes | yes |
| Active | **no** | yes |

The term is safe: it prices the next renewal. The plan is not, in either
direction. Upward, a school that has paid for Starter until March gets the
bigger student limit free until renewal. Downward, it loses a limit it has paid
for. The honest fix for the first is a pro-rata invoice, which is a billing
subsystem this product does not have and must not grow by accident inside a
signup change. An active school is refused in words that say what to do, and the
operator console can still move them in one click.

It also refuses a move into a plan smaller than the roll, counted fresh, because
the alternative is a school that cannot admit a child the next morning.

## 3. The discount engine

Two tables, and the split between them is the design.

- `discount_codes` is what is on offer. The vendor edits it any time.
- `subscription_discounts` is what a school was promised, **frozen at the moment
  they redeemed it**.

A school that redeemed 20% forever keeps 20% forever even if the code is later
edited to 5%, retired, or deleted. The alternative is a renewal run charging a
school something different from what they were told. It also makes an invoice
reproducible from a row that cannot move under it.

**One live discount per school**, enforced by a partial unique index rather than
by a function. Stacking is a rabbit hole: two percentages compound or add
depending on who you ask, and every answer is defensible, which is how a billing
dispute starts.

**It applies in one place: `fn_activate_subscription`.** Every invoice this
product raises comes through it, the operator console and the renewal run alike.
Anywhere else would mean a discount that works when an operator clicks and not
when the nightly run fires.

It does not touch a hand-typed `p_amount`, and it writes its reason into the
invoice note rather than into two new columns: that function already refuses to
charge anything but list price without a reason, and the reason already prints
on the invoice.

### The edge cases, each decided rather than left to the caller

| | |
| --- | --- |
| Flat discount larger than the price | invoice is zero, never negative; the saving recorded is what was given |
| 100 percent | allowed, and gives zero. A free term for a reference customer is a real deal |
| Trial extension on a paying school | refused. Silently doing nothing reads as a broken code |
| Same code twice | refused, by name, with the date they first used it |
| School changes plan mid-trial | the discount stays. It is attached to the school, and its terms were frozen |
| Code retired afterwards | every school already on it keeps it |
| Code nobody redeemed | can be deleted. One that has been redeemed can only be retired |

All seventeen are asserted in `supabase/tests/discounts.sql` (36 assertions).

## 4. Classes and sections

The wizard pre-filled "A" and created a section called A inside every class,
unconditionally. Most Pakistani private schools have one class per year and no
sections, so the commonest case got a subdivision it does not have: "Class 5 / A"
on every register, result card and challan, with the class and its only section
as two rows describing one room.

`enrollments.section_id` has been nullable since 0001 and every screen already
copes with a sectionless class, so the fix is entirely in what the wizard
creates. No migration was needed.

**Against the brief on one point.** The brief asked for extra sections "starting
from B", treating the class itself as A. That leaves a two-section class as one
unnamed section and one called B, and the register would offer "Class 5" and
"Class 5 / B" as if they were different kinds of thing. A class has either no
sections or a complete set of them, so the Yes branch prefills "A, B".

## 5. Two guards this earned the hard way

Both were found by preflight, not by reading.

**An overload is a dead signup.** The first draft added an eighth parameter to
`fn_signup_school_on_plan` for the region. Postgres treats that as a second
function, and a seven-argument call then matches both and is refused as "is not
unique". Dropping the seven-argument one first fixes a clean install and breaks
something worse: bundle 33 has shipped and is frozen, so any school that
re-pastes its bundles brings it back and public signup goes down on a live
deployment. 0127's header describes this trap and the first draft walked into it
anyway. The region now lives under a third name,
`fn_signup_school_on_plan_in_region`, exactly as 0127 put a second name beside
`fn_signup_school`. verify.sql, detect.sql, 0132's own guard and
`plan_and_term.sql` all now refuse an overloaded name in the chain.

**A guard in a frozen bundle cannot be extended, so the code moves instead.**
0130 refuses any function that takes a date from the caller and writes a row.
`fn_platform_save_discount` does both, for a vendor campaign window that has
nothing to do with any academic year, and 0130's exemption list is inside the
frozen bundle 36. Left alone, re-pasting bundle 36 aborts on that guard, and
because a bundle is one transaction the 0130 date bounds it re-applies roll back
with it: `fn_mark_attendance`, `fn_charge_deposit` and
`fn_generate_class_invoices` silently revert to accepting any date at all. The
write is now factored into `fn__discount_write`, which takes a whole row and no
date. Both halves are true statements about the code, which is the difference
between this and writing the guard's escape hatch into a comment.

## 6. One unrelated fix, found by the clock

`dates_in_the_calendar.sql` assertion 5 asserted that `current_date + 1` is
refused. `fn_mark_attendance` refuses anything after
`(now() at time zone 'Asia/Karachi')::date`. Between 19:00 and midnight UTC
those differ by a day, so "tomorrow" was today as the product sees it, the
function correctly accepted it, and the suite failed. Five hours of every day.
Found at 19:02 UTC, which is the only reason it was found. A test that is wrong
for five hours a day is worse than no test: it teaches people that a red run
means run it again.

## What is checked, and where

| Check | File |
| --- | --- |
| Seventeen discount edge cases, 36 assertions | `supabase/tests/discounts.sql` |
| What a school may and may not change about its own plan, 13 assertions | `supabase/tests/plan_choice.sql` |
| No signup name is overloaded | 0132's guard, verify.sql, detect.sql, `plan_and_term.sql`, `plan_choice.sql` |
| The plan screen and the discounts console open, and say so when reads fail | `src/test/pages.smoke.test.tsx` |
| What the three screens look like, at both widths | `web/tools/signup-flow-preview.test.tsx` |
