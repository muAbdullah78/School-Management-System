# A plan's student limit: the design, and the argument against each decision

Migration `0128_a_plans_student_limit_means_something.sql`, with the UI that has
to ship beside it.

---

## 1. What was actually wrong

Reported by the vendor, looking at his own console:

> the school is only allowed to have 150 students but it exceeds to 200 plus
> students so this is a loophole.

Every part of the platform knew. `plans.student_limit` held 150. The console
painted an "over limit" chip and `fn_platform_schools` returned
`needs_upgrade = true`. `fn_my_licence` computed `limit_state = 'over'`. And
nothing anywhere refused anything, so a school on the cheapest plan could carry
any number of children indefinitely and the only consequence was a chip on a
screen nobody was obliged to look at.

Worse, the product said out loud that this was fine. `fn_my_licence`'s own words
to the school were:

> You have 200 students, above the 150 your plan covers. We will move you to the
> right plan at your next renewal. **Nothing stops working.**

Two further faults hid behind that sentence, and both mattered more than the
missing block:

* It said nothing until a renewal was within **thirty days**, so a school could
  spend eleven months walking towards a wall it was never shown.
* It said nothing at all until already **over**, so the first warning arrived
  after the first refusal. `0067` had made the student count live, which is what
  the thirty-day gate was originally protecting against; enforcing the limit
  makes that protection the problem.

---

## 2. Decisions

### D1. The block stops everyone, including the owner

The vendor was offered "block the clerk, let the owner override" and chose
"block everyone". `fn__assert_room_for_students` is a hard raise with no role
exemption.

**The objection, and it is a real one:** the person who owns the school is now
refused by software he pays for, in front of a parent, on a Monday morning in
April. There is no "yes, I understand, do it anyway" button. An owner override
with an audit row would have given the same commercial pressure with none of the
outrage.

**Why the block still stands as chosen:** an override that the owner can press
is an override the owner presses, and then the limit is a suggestion again with
extra steps. The vendor's decision was taken with the risk named. It is blunted
four ways rather than argued away:

* The warning starts at **90%**, whatever the renewal date, so nobody meets the
  refusal without notice.
* **Two ways out are always available.** Ask for room from Settings then
  Subscription, or mark a child who has left as left, which frees a place and
  needs nobody's permission.
* The block is on **admission only**. Everything already entered is untouched:
  the register, the fees, the marks, the reports and every child on the roll
  carry on exactly as before, and nothing is deleted.
* The refusal names the count, the limit and both ways out, in one sentence.

### D2. Only the paths that raise the roll are gated, and `fn_rollover` is not one

Three functions carry the check: `fn_admit_student`, `fn_set_student_status`
(the coming-back branch only) and `fn_import_students`.

`fn_rollover` deliberately does **not**, and a guard in the migration fails if a
future edit adds it. Rolling a year over inserts enrolments for next year, which
is the same children a year older. Refusing it would leave a school that is over
its limit with no register, no challans and no classes for the new year. That is
not enforcement, it is taking the product away.

Marking a child as left is never gated either, for the same reason inverted: it
is the one way out that does not involve us.

### D3. The importer refuses the whole file before it starts

`fn_import_students` asks once, for `jsonb_array_length(p_rows)`.

**The objection:** importing the rows that fit is more useful than importing
none.

**Why refusing everything is right:** the alternative is 150 children created
and 150 identical failures reported, which leaves the school half imported and
the file no longer safe to re-run. A refusal up front that says how much room
there is leaves the school exactly where it started, with a file it can still
use once there is room.

### D4. No grandfathering

The migration **reports** every active school that is over, by name and by how
much, and grants nothing.

**The objection:** on the day this applies, a school that has been operating
happily at 200 on a 150 plan can no longer admit anybody, through no act of its
own.

**Why the report is still right:** recording every over-limit school's current
count as an allowance would mean the limit changes nothing on the one day it
starts existing. There is exactly one school over its limit today and it belongs
to the vendor. The console can grant an allowance to anyone who needs one, with
a reason, in one click.

### D5. The allowance is a per-school exception with a mandatory reason

`subscriptions.student_limit_override`, shaped exactly like
`grace_days_override` from `0079`, because it is the same kind of thing: a
per-school exception to a platform rule, and worthless without the reason beside
it. A check constraint makes the reason mandatory at the database, so the column
cannot be set from a `psql` prompt without one.

An allowance **below** the plan's own limit is refused unless a reason is given.
It is legitimate (a school moved down a plan and we are holding them to it)
and it is also exactly what a mistyped 15 for 150 looks like.

### D6. The request carries WHICH of the two things the school wants

`student_limit_requests.wants` is either `more_room` or `move_up`.

**The objection:** the reason field is free text and the operator can read it.

**Why a value is worth a column:** "we need room for 200 pupils" can mean *let
us past our limit on the plan we pay for* or *put us on the plan that covers
200*. The school does not much care which; it cares what the next child costs.
We care a great deal: one is a permanent hole in the price list and the other is
a school agreeing to pay more. Reading which one out of a sentence is a guess,
and a guess here is a phone call on every single request. So the box asks,
prices the answer using the school's own billing term, and sends the choice
through as a value the worklist can sort on.

### D7. Nothing tells a school to change its own plan

Nothing in this product lets a school change its own plan.
`fn_activate_subscription` is operator-only, the term chooser changes how often
they pay and not what they are on, and every renewal is a bank transfer somebody
confirms by hand.

The first draft of the reply to a request ended:

> and you can still move up a plan yourself from this screen if you would rather
> not wait.

That was false, and false in the worst way: the school goes looking for a
control that is not there, does not find it, and phones anyway. "Move us up" is
therefore worded as a **request**, and a guard in the migration fails if any of
the three functions that talk to a school ever says otherwise.

### D8. The clerk is told, in different words

The limit notice used to go to the owner and the principal only, and while the
limit was advisory that was right: a clerk shown "you are over your plan" reads
it as "stop admitting children", which is the exact behaviour a soft limit
exists to avoid.

Enforcing the limit inverts the reasoning. The clerk is the person who presses
Admit, so a clerk who is told nothing meets the refusal for the first time with
a parent standing at the desk. `fn_my_licence` now returns a second wording,
`limit_notice_staff`, which says what is happening, that it is not their doing,
and who can fix it, and which does **not** send them to a Settings screen their
role cannot open.

---

## 3. What was found on the way, and fixed

Three defects that existed before this migration and would have made it worse:

* **`LicenceBanner` gated the notice on `limit_state !== 'ok'`.** `limit_state`
  is `'ok'` while the count is at or **below** the limit, so a school sitting
  exactly on its limit, the moment the next admission is refused, had its
  warning suppressed by the component while the server was willing to give it.
  The whole 90% band would have been invisible too. The decision moved into
  `limitBanner()` in `web/src/lib/licence.ts`, where it is tested; the gate is
  now the notice being non-null and nothing else.
* **`fn_platform_school_detail` reported `plans.student_limit`,** which was the
  whole truth until the allowance existed. After it, that number is the one
  number on the platform that is *not* what the school is allowed: the page
  would show 150 for a school granted 400, paint "over limit" on it, and have
  the operator grant the allowance a second time.
* **"Move them to growth at renewal"** on the same page was fine while the limit
  was advisory and became wrong the day it was enforced: nothing waits for a
  renewal any more, the school is refusing admissions today.

And one in the migration itself, caught by `scripts/preflight.sh`'s CRLF pass:
the rewrite of `fn_set_student_status` was two chained `replace()` calls, and the
second could not match on a body stored from a CRLF paste, because the newline
*before* `else` had just been inserted as a bare line feed while the one *after*
it was still the body's own `\r\n`. `public.fn__anchor_regex()` now builds a
whitespace-tolerant pattern from a fragment written exactly as it appears in the
source, which is the remedy `supabase/check-patch-anchors.py` has been asking
for since bundle 12 lost seven migrations to the same flaw on a live school.

---

## 4. What the operator actually does

For somebody who has not used the console before.

**When a school asks for room** a tab appears in the operator console called
**Requests for more room**, with a number on it. The tab is not there when the
queue is empty, on purpose: a permanently empty tab teaches you to stop reading
the nav, and the nav is the only thing in that console that says what needs
doing.

Open it and each card shows the school, who to ring, what they asked for, how
many children they have **now** (which may have moved since they asked), what
their plan covers, what they said, and the cheapest plan on sale that would
cover the request.

Two buttons:

* **Give them room** sets an allowance and answers the request in the same
  transaction. Type the number of pupils they may have. It replaces their plan's
  limit for as long as it is set, on whatever plan they are on, does not expire,
  and bills them nothing on its own. Giving less than they asked for needs a
  note, because the note is what the school reads as the answer to "why did we
  get 200 when we asked for 400".
* **Answer no** needs a reason in a sentence the school will read. If there is
  a plan that fits them, the reason comes pre-written naming it, and you can
  edit it.

**When a school asked to move up** rather than for a favour, the card says so.
That is a sale, not an exception: put them on the bigger plan from their own
page, **Billing → Activate**, which prices the term and raises the invoice. Come
back and grant an allowance only if they need the room before the invoice is
settled.

**Without waiting to be asked**, which is how most allowances get granted
because the conversation that produces one happens on the phone: open the
school from the Schools list. Under **Licence** there is a **Student limit** block with
**Give them room** and, once one exists, **Take it back**. Taking one back is the
dangerous button: it stops the next admission the moment you save it, so the
count is spelled out beside it and the reason is mandatory.

Every one of these lands in **that school's own audit log**, with your name on
it, so they can see they asked and this is the answer.

## 5. What the school sees

Nothing at all below 90% of their limit except one grey line on Settings →
Subscription reading "148 of the 200 pupils your plan covers", with a small
**Need room for more?** link.

From 90% the panel opens on its own and the licence banner starts saying so on
every screen. At 100% the panel leads with what has stopped and, immediately
after, what has not, because a school reading it arrived there from a refusal.

The request box asks for a number, a reason, and which of the two things they
want. If there is a bigger plan it is named with its price for the term they
already pay on, so the choice is about money and not about guessing. One request
at a time, and the second is refused by a unique index at the database rather
than by a screen. They can take it back if they would rather upgrade instead.

The answer appears on the same screen, with your reason verbatim, because a
request that goes quiet is the thing that produces a phone call.

---

## 6. What this can and cannot prove

`supabase/tests/student_limit.sql` runs 78 assertions on a three-pupil plan: the
block on all four paths including the owner, the importer creating nothing, the
90% line, the request box's reason floor and one-at-a-time rule, the operator's
grant and decline, the allowance being a limit too rather than a waiver, a
school being unable to see another school's request or grant itself room, and
last, on its own because it is the assertion most likely to be broken by a
future change, a school with a completely full roll still being able to roll
its academic year over.

What no test can decide is whether 150, 350 and 640 are the right numbers. Those
come from `plans`, which the operator sets, and the suite deliberately overwrites
them with 3, 8 and 20 so that every figure in it is arithmetic about a threshold
rather than a claim about where the commercial bands sit.
