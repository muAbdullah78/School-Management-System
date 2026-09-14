# Who does what, and who watches

Migrations 0133, 0134 and 0135. Bundle 38.

## The short version

Three roles went in and one came out.

| Before | After |
| --- | --- |
| Owner, Principal, **Admin / Clerk**, **Accountant**, Class teacher, Subject teacher, Read only, Parent | Owner, Principal, Class teacher, Subject teacher, Read only, Parent |

The principal lost two powers and gained two screens:

| | Before | After |
| --- | --- | --- |
| Mark the daily register | yes | **no** |
| Finalise a register | yes | **no** |
| Reopen a finalised day | yes | yes |
| Create a class test | yes | **no** |
| Mark a class test | yes | **no** |
| See which classes have marked | nowhere | **new screen** |
| See which tests are marked | nowhere | **new screen** |

## Why the office is one role now

The eight-role list was designed for an institution with a split office. The
schools this is sold to have two to six hundred pupils and an office that is a
room with a desk in it. The principal collects the fee, signs the receipt,
admits the child and reconciles the day, and when the work is too much for one
person the answer is a second principal login, not a different kind of account
with a different set of buttons missing.

Eight roles in a dropdown for a school that needs three is not neutral. It is a
question the buyer cannot answer, asked while they are setting the software up,
and getting it wrong is silent: the clerk they created cannot unlock a register
and nobody finds out until a Thursday.

## Existing clerks become principals, not observers

Fifty-two functions let exactly four roles take money: owner, principal,
admin_clerk and accountant. If a live school has a clerk at the fee counter,
moving that person to `readonly` means that at the moment the school pastes
bundle 38, the person taking money at the window cannot take money any more. No
warning, no error anybody could act on, just a Save button that is gone. On the
first of the month, with a queue.

Read only is the tidier answer and it is the one that breaks a school.

So they become principals, which is the account the school would have created
for them if the list had been three roles long from the start. The migration
names every account it moved, by email address, so the school can see who gained
approval rights and demote anybody it would rather not.

### What this costs, stated plainly

The clerk-versus-principal line was a real separation of duties, and merging the
two roles removes it. Three specific controls are gone:

* **A till can be signed off by the person who took the money.**
  `fn_approve_till` gates on `has_role('owner','principal')` and has no
  same-person check. It held before only because the person at the counter was
  an `admin_clerk`.
* **A charge can be voided by the office.** `fn_void_invoice` was refused to a
  clerk. It is not refused to a principal.
* **A leaving certificate can be released over unpaid fees by the office.** The
  override inside `fn_issue_certificate` was refused to a clerk.

None of these is quietly patched, because each fix is a decision about how a
school runs rather than one a migration gets to make. A same-person rule on the
till, for instance, would mean a school with one principal and an absent
proprietor could never sign a drawer off. `supabase/tests/finance.sql` records
the till case at the assertion where it used to be tested, so the next person to
read it finds out what changed and why.

## Why the enum values survive

Postgres has no `DROP VALUE`. Removing the two would mean building a new type
and rewriting every column, function signature and default that mentions the old
one, and 266 lines across 60 **shipped** migrations name `admin_clerk` or
`accountant` inside `has_role()` lists. Those files are frozen: a school
re-pasting bundle 4 would hit a type that no longer exists, and because a bundle
is one transaction the whole bundle would roll back.

So the values stay and a check constraint makes them unreachable. A value no row
can hold and no function can be given is already gone;
`has_role('owner','principal','admin_clerk','accountant')` in a frozen file
keeps working and keeps meaning "owner or principal".

Four doors are shut: `profiles.role`, `user_invites.role`, the
`guard_profile_role` trigger and `fn_invite_user`. The constraints are the
enforcement; the two functions exist so the error is a sentence rather than
`violates check constraint "profiles_role_live_chk"`.

## Why the head does not mark the register

A principal could mark attendance from an empty register, exactly as the class
teacher would. That is not a permissions detail, it is the register losing its
meaning: when the head can also make the statement, nothing on the record
distinguishes "the teacher marked Bilal absent" from "the office decided Bilal
was absent", and the attendance percentage that reaches a result card, the
parent portal and a fee decision stops being evidence of anything.

It also made the head's screen useless for the job the head has. A principal
opening Attendance got a class picker and a list of pupils: a tool for marking
one section. What a head needs at 9.40 in the morning is the opposite shape, and
the software could not answer it for anybody.

**What the principal keeps** is `fn_unlock_attendance`. Reopening a finalised day
is an approval, not a marking, and without it a child marked absent by mistake
stays absent on every result card ever printed.

**The owner is deliberately left able to mark.** `owner` is the signup account
rather than a job title; a school of this size often has one account with any
authority, and the school's own answer to a teacher being off sick is to hand
their login to somebody else for the day. No screen offers marking to the owner
by default: the attendance page gives them the same oversight dashboard, with
marking one deliberate click away. If that is ever decided against, the change is
to delete `'owner'` from `fn_may_write_register` and from nothing else.

## Subject attendance

A second, optional register a subject teacher may keep for their own subject.
Every way in which it is weaker than the daily register is a decision:

* nothing is locked or finalised
* it feeds no attendance percentage, nothing on a result card, nothing a parent
  sees. Two answers to "was this child present today" is the failure migrations
  0097 and 0100 were written to end
* **a subject nobody marked is not shown as outstanding, anywhere.** There is no
  "not done" for subject attendance, because nobody was ever asked to keep it. A
  panel listing forty unmarked subjects every morning would train the head to
  ignore the screen that also tells them a class register is missing

Only the head, the owner, an observer and the teacher who wrote it can read it.
There is no insert, update or delete policy at all: the one way in is
`fn_mark_subject_attendance`, so the rules live in one place.

## Scheduling a test

The column always accepted a future date. That is not the same as supporting it:
a test dated next Saturday sat in the same list as one held last Tuesday, with
nothing to say which was which, and the marks grid opened for both.

Now the date means something.

* A test may be dated in the future. That is scheduling.
* **Marks may not be entered before that date**, refused in words, because the
  alternative is a mark against a paper nobody has written.
* The date must fall inside the academic year and no more than a year ahead.
  Both are about a mistyped year, and the second matters more than it looks: a
  test four years out never appears in the unmarked list and is never noticed
  again.

## What "unmarked" means

At least one pupil with neither a mark nor an absence, on a test whose date has
passed, that is not locked.

Not "has no marks at all". The common failure is not forgetting the test
happened; it is marking twenty of thirty-four, being interrupted, and never
coming back. A reminder that only fires on a completely blank test misses
exactly that case.

A test dated **today** is not chased. The paper may be sat this afternoon.

## Where the rules live

| Question | Function |
| --- | --- |
| May this caller mark or finalise a register? | `fn_may_write_register()` |
| May this caller set, mark or lock a class test? | `fn_may_set_a_test(...)` |
| Which classes have marked today? | `fn_attendance_day(session, date)` |
| Which subjects were marked today? | `fn_subject_attendance_day(session, date)` |
| What papers do I still owe? | `fn_my_unmarked_tests(session)` |
| What have my teachers set, and is it marked? | `fn_tests_overview(session, from, to)` |
| Which roles may a school hand out? | `fn_assignable_roles()` |

`fn_may_mark_subject` is deliberately **not** changed. It also gates
`fn_enter_marks`, which is the formal exam path, and a school's exam process is
a different thing with a different chain of responsibility. Widening this change
into exams was not asked for and would be a surprise.

Both new predicates are named `fn_may_` rather than `fn__`. An `fn__` helper is
revoked from `authenticated` by convention and by a guard, and a predicate used
inside a row-level policy is evaluated as the querying user: revoked, it would
make every insert into `attendance_daily` fail with a permission error on the
helper rather than a refusal from the policy.

## The screens

| Role | Attendance | Tests |
| --- | --- | --- |
| Class teacher, Subject teacher | marking screen, two tabs: daily register and subject attendance | set, schedule and mark their own, with a reminder for anything past and unfinished |
| Principal, Read only | oversight dashboard: three piles, a read-only register, the subject panel | overview with a calendar filter and a marked/unmarked column |
| Owner | oversight dashboard, with "Mark a register" | overview, with "Set a test" |

Routing by role rather than disabling buttons is the point. A head still given a
class picker, a roster and a Save button will fill one in, press Save, and be
refused by a sentence they did not expect, having done the work.
