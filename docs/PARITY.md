# Parity with OurSchoolSoftware — the complete inventory

This is the working checklist for matching OurSchoolSoftware's workflows, taken
from the 29-page screenshot set of their live admin panel (every sidebar module
expanded). It exists so nothing gets dropped: every item they have appears here
with an honest status, including the ones we are deliberately not building.

**Status key** — `have` shipped and reachable · `partial` exists but incomplete
or has no UI · `missing` not built · `excluded` deliberately out of scope

Every `have` here means *checked*, not *remembered*: the file exists and
something routes to it. Three items were first written down as `missing` and
turned out to be built and reachable — the tabulation sheet, the date sheet and
admit cards. Assume any status not yet re-checked could be wrong in either
direction, and check before building on it.

> A note on why we are copying them at all. Not for feature-count parity. Their
> workflows have been run by real schools for years, so the ORDER of steps, what
> is on screen at the moment of a decision, and what prints at the end have all
> been corrected by clerks who would otherwise have stopped using it. That is
> information we cannot get any other way, and it is worth more than our own
> guesses about how a Pakistani school office works.

---

## The exclusion conflict, resolved explicitly

The screenshots contain a great deal that was explicitly ruled out. The rule
applied throughout this document:

**Their workflow and logic; our delivery channels.**

Their product leans on paid SMS credits and a pair of mobile apps. Ours does
not. So every one of their ~25 SMS templates becomes a **WhatsApp click-to-chat**
template — same trigger, same merge tags, same enable/disable toggle, no credits
and no per-message cost. The workflow survives; the channel changes.

Modules ruled out entirely, and therefore absent from the plan below: SMS
sending and SMS settings, mobile apps and app notifications, biometric and
facial-recognition attendance, online classes, holiday calendar, salary and loan
management, stock and inventory, student behaviour, ID card printing,
certificates, daily student diary, study material LMS, email alerts, school
notice board, transport, parent complaints.

Where one of their screens mixes excluded and wanted work, only the wanted half
is listed.

---

## 1. Admission Management

| Their screen | Status | Notes |
|---|---|---|
| Admit Student | `partial` | We have the form. Theirs also has a **student photo** with upload *and* webcam capture — we have no photo anywhere and `students.photo_url` is a dead column. |
| Admit Bulk Student | `partial` | We have CSV import. Theirs is an on-screen grid for typing several siblings at once, with a class/section header applied to the whole batch. |
| Admission Requests | `missing` | Online applications awaiting approve/reject. |
| Admission Inquiries | `have` (0046) | Worklist-first: opens on who is overdue a call. Append-only follow-up log, one-action conversion through `fn_admit_student`, and a source breakdown. |
| Admission Reports | `missing` | Admissions Today / This Month / This Year / Admission Forms / **Blank Admission Form**, all printable. |

## 2. Student Management

| Their screen | Status | Notes |
|---|---|---|
| Student Information | `partial` | Ours opens as a list of 50 with no columns. Theirs is a filtered table (campus, class, section, type) with export and pagination. |
| Student Attendance | `have` | Ours is genuinely good — mark-all, keyboard entry, offline, print. |
| Student Promotion | `have` | Year Rollover. |
| Student Transfer | `missing` | Between **campuses**. Needs multi-campus first. |
| Student Birthdays | `have` (0050) | One screen for children and staff, today / 7 / 30 days, with a click-to-chat wish. |
| Student Info Reports | `partial` | Theirs: All Active / All Inactive / Class-Wise / All Passout / Free Students / Monthly Passout / Daily Passout / Gender-Wise. |

## 3. Parent Accounts

| Their screen | Status | Notes |
|---|---|---|
| Manage Accounts | `partial` | **Being built now.** The portal exists and was unreachable — nothing could link a parent to a family. |
| Account Requests | `missing` | A parent self-registers, the school approves. Their approve/reject each fire a message. |
| Parent Info Reports | `missing` | All Parents · Parent Credit Report · **Family Tree Report** · Defaulter Parents Report. Family Tree is the one to copy — one page per family showing every child and the combined balance. |

## 4. Staff Management

| Their screen | Status | Notes |
|---|---|---|
| Staff Management | `have` | |
| Departments | `missing` | Staff grouped by department. |
| Staff Birthdays | `have` (0050) | Same screen. `staff.dob` did not exist and was added. Office roles only — personnel data. |
| Job Inquiries / CV Bank | `missing` | Applications for teaching posts. |

## 5. Fee Payment — the counter

Their busiest screen, and the one ours gets most wrong. Theirs opens with:

- Four tiles: **Unpaid Invoices · Income Today · Expense Today · Balance Today**
- **Two** search boxes side by side:
  - *Search Student By Name / Code* — with **scan a fee slip** for instant payment
  - *Search Student By Parent ID / CNIC* — "filter all connected students"
- **Latest Payments** table always visible: Student · Parent · Class · Fee · Paid · Late · Discount · Note · Accountant

| Item | Status |
|---|---|
| Family collection by father's CNIC | `have` (migration 0036) |
| Two-mode search, side by side | `missing` |
| Today's tiles on the counter screen | `missing` |
| Latest Payments always visible | `missing` — ours opens as an empty search box |
| Scan a fee slip to pull up the payment | `missing` — `fn_find_by_voucher` exists with no caller |

## 6. Accounting

| Their screen | Status | Notes |
|---|---|---|
| Generate Monthly Fee | `have` | |
| Generate Custom Fee | `missing` | A one-off charge to a chosen set of students. |
| Fee Types / Fee Heads | `have` | |
| Fee Structure | `have` | |
| Family Fee Calculator | `have` | Migration 0036. |
| Manage Advance Fee | `partial` | `family_credit` exists; no screen shows or applies it. |
| Direct Payment | `missing` | Payment without an invoice — walk-in, non-student. |
| Fee Installments | `missing` | Designed in docs, never built. |
| Print Balance Sheet | `have` (0045) | As at a date, not a range. Prints. |
| Deleted Fees | `missing` | An audit list of reversed/removed charges. |
| Generate Fee Increment | `partial` | `fn_fee_increment` exists, no UI. |
| Generate Fee **Decrement** | `missing` | We only ever built increment. |
| **Bulk Fee Payment** | `missing` | Take payment from many students in one pass. The single biggest gap: 100–400 collections a month currently means 100–400 searches. |
| Discounted Students | `partial` | We have a discount register. |
| Accounts Settlement | `partial` | Our till covers the per-collector half. |
| **Print Fee Vouchers** | `missing` | No printable challan exists anywhere. `docs/03-FEATURES.md` promises a 3-part bank-payable format; nothing implements it. For a Pakistani school the challan **is** the product — the parent takes it to the bank. |

## 7. Expense Management

| Their screen | Status |
|---|---|
| Add / Manage Expense | `have` |
| Expense Categories | `have` |

## 8. Reporting Area

| Their report | Status |
|---|---|
| Class Wise Basic Reports | `have` |
| Fee Defaulters Report | `have` |
| Head Wise Dues Summary | `partial` — `fn_head_wise_dues` has no UI |
| Income & Expense Report | `have` |
| Debit & Credit Statement | `have` (0044) |
| List Of Unpaid Invoices | `have` (0044) — per challan, with overdue age |
| Fee Discount Report | `have` (0044) — with the approver |
| Accounts Summary Report | `partial` — the statement's head totals cover it; no separate screen |
| Detailed Income Report | `have` (0044) — the statement, filtered |
| Detailed Expense Report | `have` (0044) — the statement, filtered |
| Find A Balance Sheet | `have` (0045) — a genuine as-at-date reconstruction |
| Admission Date Report | `have` (0044) — with a still-here column |

## 9. Test Management and Exam Management

They keep these as two parallel modules — informal class tests and formal
terminal exams — which matches how Pakistani schools actually work. We collapse
them into one, and that is probably wrong.

| Their screen | Status | Notes |
|---|---|---|
| Test / Exam List | `have` | |
| Assign Grades | `have` | Grade scale in settings. |
| Marks Entry | `have` | |
| Teacher Remarks | `have` (0049) | Kept per exam term, not per printed card, so regenerating result cards cannot lose one. Class teacher writes it; a subject teacher on the same class cannot. |
| Test Schedule / Exam Timetable | `have` | `DateSheet.tsx`, reached from Exam Setup. |
| **Tabulation Sheet** | `have` | `TabulationSheet.tsx`, reached from Result Cards. Corrected — first drafted as `missing`, then found and confirmed reachable. |
| **Position Holders** | `have` (0049) | Top N per class, ties preserved as on the card (two firsts means no second), withheld results flagged before an announcement. |
| **Print Admit Cards / Slips** | `have` | `AdmitCards.tsx`, reached from Exam Setup. Corrected as above. |
| Print Marksheets | `partial` | Result cards exist and print; the `published_at` gate that releases them to parents has no UI. |
| Send Marks / Marksheets to parents | `missing` | Becomes WhatsApp. |
| Test / Exam Reports | `missing` | |

## 10. Notifications — their SMS, our WhatsApp

Their **Automation Settings** pattern is worth copying exactly: every event has
an editable template with `$merge_tags`, a **supported-tags** hint under the
box, and an **Enabled** toggle so a school can silence any one of them.

**Built** — Settings → Messages (0043). Editable body, clickable merge tags
drawn from the actual call sites rather than a guess, an Enabled toggle that
genuinely blocks the message, "Restore original", and a live preview with sample
values, which theirs does not have.

Their events, mapped to ours (excluded ones dropped):

| Their template | Ours |
|---|---|
| Admission SMS | `missing` |
| Inquiry Add / Inquiry Admit | `have` (0046) — WhatsApp, with the same triggers |
| Exam Marks / Final Exam Marks | `missing` |
| First / Second / Third Fee Reminder | `have` — two templates, escalating; sent from Bulk collect (0040) |
| Absent SMS | `missing` |
| Transfer Student | `missing` (needs campuses) |
| Fee Payment / Direct Student Payment | `have` — receipt on payment |
| Leave Approval / Leave Reject | `missing` (needs a leave flow) |
| Student / Staff Birthday Wish | `have` (0050) — click-to-chat from the Birthdays screen |
| Parent Account Approve / Reject | `missing` |
| Admission Approved / Rejected | `missing` |
| Staff Absent / Staff Late | `missing` |
| Diary, Salary Issue | `excluded` |

Three fee reminders rather than one is the detail to keep: escalating wording,
the third warning that the child will not be allowed to attend.

## 11. Cross-cutting — the things on every screen

These are not features, they are the reason their product feels finished and
ours does not.

| Pattern | Status | Notes |
|---|---|---|
| **Every list is a real table** | `missing` | Theirs: page-size selector, search box, **Excel / CSV / PDF / Print** buttons, pagination. Ours: 33 hand-rolled `<table>`s, no shared component, zero sortable columns, students silently capped at 50 rows. |
| **Global search in the header** | `have` (0050) | Children, staff, families, challans by voucher, receipts by number, enquiries. Role-aware in SQL. "/" focuses it. |
| Module search in the sidebar | `have` (0050) | Filters the nav this role can already see, so it cannot surface a module they lack. |
| **Multi-campus** | `missing` | Campus selector in the header, campus column on every list, transfer between campuses. We have an unused `campuses` table. Architecturally significant — decide before building more reports. |
| Print-first reports | `partial` | Every report screen of theirs is a grid of named reports each with a Print button. |
| Dashboard tiles that link to a report | `partial` | Their tiles all say "View Report". |
| Running session shown in the footer | `missing` | Small, but it is always visible and prevents entering marks into last year. |
| Student photo | `missing` | Upload and webcam capture. |
| Admin role management | `partial` | Theirs toggles web login and app login per admin. |
| School's own public website | `excluded` for now | They generate a full public site per school — gallery, principal's message, facilities, colours. A separate product; our marketing site is not the same thing. |

---

## Build order

Ordered by what a school touches most and what breaks worst, not by module
number.

Items 1-6 and 9 are **done** (PR #17). What follows is the remaining work.

1. ~~**Parent accounts** — make the portal reachable.~~ Done (0037).
   Along the way: `profiles.active` was written by the Settings screen and read
   by nothing, so "Deactivate" left a dismissed clerk with full access.
2. ~~**The fee counter**~~ Done (0038).
3. ~~**Printable fee vouchers**~~ Done (0039) — 3-part, batch per class, reprint.
4. ~~**Bulk fee payment**~~ Done (0040), with escalating WhatsApp reminders.
5. ~~**A real table component**~~ Done — applied to Students and Defaulters;
   the 50-row cap is gone (0041). Still to apply to the other 31 tables.
6. ~~**Dashboard honesty**~~ Done (0042). It also turned out to be leaking
   every school's admissions and collections to every other school, plus three
   more unscoped SECURITY DEFINER functions. A structural CI guard now blocks
   that class of bug.
7. ~~**Teacher remarks and a position-holders screen**~~ Done (0049). The
   tabulation sheet, date sheet and admit cards already existed — verified
   reachable, not assumed.
8. ~~**The reporting area**~~ Seven of the eight done (0044, 0045). Remaining:
   a standalone accounts-summary screen. The balance sheet (0045) was the one
   that could not be served by filtering the ledger, because it is a position
   AS AT a day rather than a range — summing `student_balance()` gives today's
   figure whatever date you print above it.
9. ~~**WhatsApp automation**~~ Done (0043).
10. ~~**Admission enquiries**~~ Done (0046). Still missing the other half:
    **admission requests** — online applications awaiting approve/reject.
11. ~~**Global search, module search, birthdays**~~ Done (0050). Student photos
    remain — they need Storage, which cannot be tested from here.
12. **Multi-campus** — last, because it touches every table, and only if a real
    school asks for it.

## Thirteen columns nothing uses (found by check-columns-used.sh)

The column-level twin of the reachability check found thirteen. Ranked by what
their absence actually costs a school, because several are not cosmetic.

### Needs a decision — no Supabase Storage exists at all

| Column | What is missing |
|---|---|
| `students.photo_url` | Student photographs. Theirs has file upload **and** webcam capture, and a photo appears on the student profile, class lists and ID cards. |
| `school_settings.logo_url` | The school's logo on the printed challan, result card and certificates. A fee voucher with no logo does not look like it came from the school. |

**Not built, deliberately.** Both need a Storage bucket, and bucket policies are
not table RLS — they are `storage.objects` policies, which this environment
cannot exercise at all (there is no Supabase here, only Postgres). Shipping
untested bucket policies for **photographs of children in a multi-tenant system**
is not a risk worth taking: the failure mode is one school fetching another
school's pupils' photographs. This needs to be built against a real project and
verified there.

### Exam and board module — these look like correctness gaps

| Column | What its absence implies |
|---|---|
| `exam_subjects.practical_max` | No practical marks. Pakistani boards examine practicals in the science subjects, so a science result computed without them is incomplete. |
| `assessments.weightage` | Assessments cannot be weighted, so a 10-mark class test may count the same as a 100-mark paper in whatever aggregates it. |
| `enrollments.stream`, `subjects.stream`, `subjects.is_practical` | No streams. Science / Arts / Pre-medical is fundamental from class 9, and subject lists differ by stream. |
| `enrollments.bise_reg_no` | The BISE registration number, which a school must hold for every board candidate. |

Worth ranking against real market knowledge before building: these change how
results are computed, and a semantic change to marks after a school has entered
them is not a safe thing to do casually.

### ~~Audit trail~~ — done (0048)

Both `correction_reason` columns are now written, and — the bigger half —
`corrected_from` is now READ. It had been recorded faithfully since the exam
module was built and nothing ever displayed it, so the school held the answer to
"my son got 45, you have written 40" and could not get at it.

`fn_mark_corrections` and `fn_attendance_corrections` are two new report tabs,
owner and principal only: a subject teacher can enter marks, which is exactly
why they must not be able to audit them. The marks entry screen asks for a
reason only when a mark that already had a value is being changed — a first
entry is not a correction, and demanding a reason for one trains teachers to
type anything to get past it. A change made with no reason is still reported,
flagged "none given".

### Minor

| Column | Note |
|---|---|
| `fee_heads.is_refundable` | A security deposit is money the school **owes back**. Unwired, it is billed and collected as ordinary income, and `fn_report_balance_sheet` counts it as settled rather than as a liability alongside `advance_held`. |
| `result_cards.generated_at` | Metadata only. |

### Staff leaving (0053)

`staff.left_on` was on the list above until 0053, and pulling on it found
something worse than an unused column.

The staff screen's "Deactivate" button wrote `staff.status`, and **nothing
anywhere reads `staff.status`** — `current_school_id()`, `has_role()` and
`is_staff()` all gate on `profiles.active`. So a teacher who resigned and was
"deactivated" could open the app the next morning and mark attendance, enter
marks and read every child's record in their class. Two switches existed: an
obvious one that did nothing about access, and an effective one in
Settings → Users that nobody would look for after pressing the obvious one.

Two further consequences followed from the same button:

* `sections.class_teacher_id` was left pointing at the departed teacher — and
  it is what result cards print. The Class Teachers screen builds its dropdown
  from *active* staff, so the stored id matched no `<option>` and the select
  rendered "— unassigned —". The screen said the section had no class teacher
  while the database had one and the card still printed their name.
* `left_on` was never written, so the school had no record of when anybody left.

`fn_staff_leave` makes it one action: the date, the revoked login, the vacated
class-teacher slots, the dropped current-and-future assignments, an audit row
with the reason, and a summary the screen turns into "Class 1-A and Class 1-B
now have no class teacher". Assignments for sessions that had already ended are
kept, because *who taught 1-A in 2023-24* must still be answerable. `fn_staff_rejoin`
undoes it and deliberately does **not** restore the class-teacher slots: a
replacement may be in them.

**Deliberately not silent.** The migration renames existing `'inactive'` rows to
`'left'` but does **not** close their logins. It cannot tell "resigned in March"
from "clicked by mistake", and revoking access from inside a migration is how
somebody still working gets locked out on a Monday. Instead the roster reports
anyone who has left whose login still works, and the staff screen shows that as
a red banner with a Close login button per person. The school sees the list and
decides.

## The bug class this project keeps producing (0047)

Almost every serious defect found in this work has been the same shape:
**correct logic that nothing could reach.** Not one of these was a logic error.

| What | Consequence |
|---|---|
| `fn_link_parent` had zero callers | the only writer of `profiles.family_id`, so every parent portal read threw |
| `fn_family_for` had zero callers | siblings never shared a family; family billing had never worked in production |
| `profiles.active` had no reader | "Deactivate" left a dismissed clerk full access |
| `message_templates.enabled` had no writer | the WhatsApp toggle was decorative |
| `result_cards.published_at` never selected | no result could reach a parent |
| `fn_find_by_voucher` had zero callers | a printed challan could not be scanned |
| `fn_reverse_other_income` had zero callers | a mistyped income entry could never be corrected, in an append-only ledger |
| `supabase/bundles/` stopped at 0039 | seven migrations never reached any real school |
| `students.photo_url` | still dead — the one item on this list not yet fixed |

Every one was found by hand, late, usually while building something unrelated.
So `supabase/check-reachable.sh` now asks the catalogue on every CI run: for each
function granted to `authenticated`, is it named by another function, a trigger,
an RLS policy, a column default, a check constraint, an index expression, a view,
or by `web/src`? If not, it is either a feature with no way to use it or dead code
that `authenticated` can nonetheless EXECUTE. Verified by planting
`fn_planted_orphan()` and confirming CI fails.

Its first run found `fn_reverse_other_income`, and pulling that thread found
something worse next to it: **other income had no read path at all.** It could
be recorded and fed the totals, but nothing ever listed the individual entries,
so a wrong one could not even be found. The Accounts screen now has an other
income register mirroring the expense register, with the reversal wired.

Two dead helpers, `auth_role()` and `is_parent()`, were dropped in 0047 after
confirming by catalogue query — not by reading — that nothing references them.

## Found while building the enquiry module (0046)

**THE BUNDLES STOPPED AT MIGRATION 0039.** `supabase/bundles/` is what a school
pastes into the Supabase SQL Editor, and its globs covered 0001-0039 only.
Migrations 0040-0046 were in no bundle at all, so a school installing from the
documented path got a database seven migrations behind the app: the fee counter,
the printable challan, bulk collection, the student roster, WhatsApp settings,
every money report, the balance sheet and the enquiry book would all error on
open, because the functions they call were not there.

CI did not catch it, and could not have: its check regenerates the bundles and
diffs them against what is committed. With 0040+ outside every glob the
regenerated output matched perfectly and the check stayed green. `verify.sql`
did not catch it either — it reported every row PASS on a bundles-1-to-3
install, which is the worst possible outcome: a school told its install is
sound while half the product is missing.

Fixed three ways, because one was clearly not enough:

* `4_operations.sql` now carries 0040-0046.
* `build-bundles.sh` asserts that **every migration is in exactly one bundle**
  and exits non-zero otherwise, so adding 0047 without a glob fails the build
  instead of silently shipping short.
* `verify.sql` gained a bundle-4 row naming one function from each of
  0038-0046, and CI now runs `verify.sql` against a fresh bundle-only install —
  the only place the install path and the install check actually meet.

Also worth recording: two assertions in `message_settings.sql` hard-coded
"five templates". Adding the two enquiry templates broke tests that were not
testing enquiries. Both now assert against `fn__default_message_templates()`,
which is the real invariant — every template the schema defines is offered on
the settings screen, so none can be a message a school cannot switch off.

## Found while building the balance sheet (0045)

Three things that were not on any list, recorded because each is the kind of
defect that stays invisible until it matters:

* **A school can never be deleted.** 34 tables reference `public.schools` with
  `ON DELETE NO ACTION`, so `delete from schools` fails outright. That is
  correct as a safety property — nobody should be able to erase a school by
  accident — but it means there is no path at all for a school leaving the
  platform, or for a data-deletion request. Relevant to item 8 below, the
  operator console.
* **Seven test suites could only ever be run once per database.** Each opened
  with a `delete from public.schools where name = '…'` "clean slate" that, per
  the above, deletes nothing on a fresh database and errors on a re-run. They
  committed their fixtures instead of rolling back, which is also what made
  `counter.sql` pass alone and fail after `fee_ops.sql`. All seven now roll
  back, all 17 suites pass three times over in both orders, and CI re-runs the
  whole set in reverse to keep it that way.
* **The documented way to run a rendering harness had never worked.** A CLI file
  argument FILTERS vitest's `include` rather than adding to it, so the command
  in `vite.config.ts` matched nothing and exited 1. Now `npm run harness`.

Items 1–6 are what makes the product usable daily. 7–9 are what makes a head
teacher choose it. 10–12 are growth.
