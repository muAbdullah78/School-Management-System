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
management, stock and inventory, student behaviour, daily student diary, study
material LMS, email alerts, school notice board, transport, parent complaints.

**Two items came back off that list**, on an explicit later decision:

- **Certificates and ID cards.** A Pakistani school cannot operate without a
  School Leaving Certificate — a family moving city cannot enrol a child
  anywhere else without one — so ruling it out ruled out a document the school is
  legally expected to produce. Built.
- **QR check-in for staff** — but still **no biometric**. Biometric needs a
  physical device and its own support burden; a QR code needs a printed card and
  a phone. The loopholes a QR system opens (photograph the code, mark in from
  home) are closed in software, and how is set out where that feature is
  described.

`biometric and facial-recognition attendance` stays excluded, and nothing in the
QR work moves toward it.

Where one of their screens mixes excluded and wanted work, only the wanted half
is listed.

---

## 1. Admission Management

| Their screen | Status | Notes |
|---|---|---|
| Admit Student | `done` | The form, plus the photograph — added on the pupil's profile once admitted rather than mid-form, because a clerk admitting a queue of children should not be blocked on finding a photo. The class photo sheet then fills them all in one pass. |
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
| Student photo | `done` | Upload from file or phone camera (0057). No webcam-capture screen: on a phone or tablet the file picker already offers the camera, and on a desktop a clerk photographing 800 children uses a phone. The class photo sheet is the part their product does not have. |
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
11. ~~**Global search, module search, birthdays**~~ Done (0050).
    ~~Student photos~~ Done (0057) — including the storage policies, which turned
    out to be testable after all: see below.
12. **Multi-campus** — last, because it touches every table, and only if a real
    school asks for it.

## Thirteen columns nothing uses (found by check-columns-used.sh)

The column-level twin of the reachability check found thirteen. Ranked by what
their absence actually costs a school, because several are not cosmetic.

**None left.** 0057, 0058 and 0060 wired all thirteen, and the baseline in
`check-columns-used.sh` is now **empty**. Every line removed from it went because
the column got used, never because the check was relaxed — and from here any
unused column fails the build outright, with no debt left to grant an exception
to.

### ~~Needs a decision — no Supabase Storage exists at all~~ Built (0057)

| Column | Status |
|---|---|
| `students.photo_url` → **`photo_path`** | Built. Upload on the pupil's profile and on a class photo sheet where the face IS the upload button, so a whole class is photographed in one screen rather than forty. Shown on the profile, the roster, the class sheet and the ID card. |
| `school_settings.logo_url` → **`logo_path`** | Built. Uploaded in Settings by owner or principal only, and printed on the challan (all three copies), the receipt, the result card, every certificate and both ID cards. |
| `staff.photo_path` (new) | Built. On the staff roster and the staff ID card. |

**What I said before, and why it was wrong.** The earlier note here refused to
build this on the grounds that `storage.objects` policies "cannot be exercised at
all" in this environment. That was a real risk, honestly stated, and the
conclusion was still wrong: a storage policy is *ordinary SQL over an ordinary
table*. `supabase/tests/photos.sql` builds a faithful `storage.objects` stub —
same shape, same `storage.foldername()` behaviour — installs the same four
policies, and drives them as `authenticated` from two schools **in both
directions**. 34 assertions. The isolation guarantee is tested, not asserted.

What genuinely cannot be tested here is that Supabase's storage API consults
those policies, plus the bucket's own size and mime limits and the signed-URL
flow. Those are one manual pass on the live project, written out box by box in
`docs/PHOTOS-CHECKLIST.md`. The design and every objection to it are in
`docs/PHOTOS-DESIGN.md`.

The columns were **renamed** rather than reused: they hold a storage *path* and
never a URL. A URL in a column is a URL that expires, or a public link that
outlives the child's time at the school. `verify.sql` fails if the old name is
still present, because that would mean every read in the app is looking at a
column that is not there.

### ~~Exam and board module — these look like correctness gaps~~ Built (0058)

They were not "gaps that look like" correctness problems. They **were** the
correctness problem, and it was worse than this note guessed. Reproduced on a
real database before anything was changed — one class of three in class 9,
English for everyone, Physics for Science, Civics for Arts, everyone who sat a
paper doing well:

| Pupil | Card said | Truth |
|---|---|---|
| Arts Child | 180/275 = **65.45%**, grade **C**, position **1** | 180/200 = 90.0%, A+ |
| Science Child | 160/275 = **58.18%**, grade **D**, position **2** | 160/175 = 91.4%, A+ |
| Unmarked Child | 0/275 = **0.00%**, grade **F**, position **3** | marks not typed in yet |

With `stream` unread, every pupil was marked out of *every* paper in the class,
so a zero was silently supplied for the other stream's syllabus. Two A+ pupils
printed as a C and a D. The ranking **inverted** — the Science pupil is genuinely
first — so prize day would have gone to the wrong child. And a pupil nobody had
marked printed as having failed, because one `coalesce(sum(…), 0)` made "no mark
exists" and "a mark of zero" the same thing.

| Column | Status |
|---|---|
| `enrollments.stream`, `subjects.stream` | Built. A subject with no stream is everyone's; a streamed subject is only for pupils in that stream, matched case-insensitively. A streamed class with a streamless pupil is **refused**, by name, rather than quietly given half a card. Set in Exams → Streams & Board Nos, as one list per class. |
| `exam_subjects.practical_max`, `subjects.is_practical` | Built. `mark_entries.practical_marks` is new; theory and practical are kept apart on the card and combined for the pass mark, validated against their own maximum. `is_practical` gates whether a paper may carry practical marks at all, so the two columns cannot disagree. |
| `assessments.weightage` | Built, **opt-in**. `exam_terms.assessment_weight_pct` defaults to 0, which is exactly the old behaviour, so no existing card moves on upgrade. A pupil with no weighted assessment gets 100% from the exam rather than a zero for a component that does not exist. |
| `enrollments.bise_reg_no` | Built. On the result card when present, and exportable as a board list. |
| `exam_subjects.pass_marks` | Was frozen onto every card since 0005 and never used. Now drives per-subject Pass/Fail and an overall verdict, and the card prints *both* the aggregate and the number of subjects failed so a school with a different promotion rule can apply it. |
| `result_cards.generated_at` | Printed, with the version, so two cards in circulation after a correction can be told apart. |

The rule that shaped all of it: **a refusal is recoverable, a plausible wrong
card is not.** Generation now refuses while marks are missing and names the
subject and the count — "Chemistry is missing for 12 pupils" is actionable where
a silent zero was not. An explicit provisional run is allowed, and then the card
says PROVISIONAL, excludes the unmarked papers from its denominator, and takes no
position. All three together; one without the others is the original defect with
a label on it.

51 assertions in `supabase/tests/exam_computation.sql`. The design and the
argument against each decision are in `docs/EXAM-COMPUTATION-DESIGN.md`,
including what is deliberately not built (per-pupil electives, a configurable
promotion rule, and GPA — `school_settings.grade_scale` still offers `gpa10` and
`fn_grade_for` still always returns letters, which is its own piece of work).

### Refundable deposits — a security deposit counted as profit — done (0060)

`fee_heads.is_refundable` and the `security_deposit` value of `fee_head_type` had
both existed since the first migration and nothing read either. That was not a
cosmetic gap. One pupil, Rs 2,000 tuition + Rs 5,000 **refundable** deposit,
family pays all 7,000:

| Figure | System said | Truth |
|---|---|---|
| `fee_income` | 7,000 | 2,000 |
| **`profit`** | **7,000** | **2,000** |
| balance-sheet liability for the deposit | 0 | 5,000 held |
| ways to record a refund | **none** | needed on every leaving |

`fn_finance_summary` summed every verified payment into `fee_income`, and a
deposit is a payment. A school of 200 pupils on a Rs 5,000 deposit showed **a
million rupees of profit that was a liability** — and a proprietor pays a salary
or a building instalment out of that number.

The design and the argument against each decision are in
`docs/DEPOSITS-DESIGN.md`. Three decisions matter:

- **A refundable charge gets its own challan.** Forced by an existing fact:
  `payment_allocations` allocates to an *invoice*, not a line, so on a mixed
  challan a part-payment cannot be split into "deposit" and "tuition". Any
  splitting rule would be one a parent can argue with at the counter and the
  school cannot defend, because it exists only inside the software. A trigger on
  `invoice_lines` enforces it on every path.
- **Netting on leaving is an adjustment, never a payment.** "You owe 3,000, your
  deposit is 5,000, here is 2,000 back" — recorded as a negative adjustment, so
  the day book and the till do not gain 3,000 that nobody handed over.
- **Deposits held survive the pupil leaving.** A child who has gone and not been
  refunded is exactly the money still owed, so the liability must not shrink when
  they go.

Safe by default: a school with **no** refundable head sees no change to any
figure, because every new sum is zero. 39 assertions in
`supabase/tests/deposits.sql`.

**A gap in 0059 surfaced while wiring this.** `fn_profit_snapshot` — the Accounts
overview — is declared VOLATILE though it writes nothing, so 0059's "rewrite read
gates in STABLE functions" rule skipped it and it kept refusing `readonly`, on the
one screen the module exists for. `check-readonly-writes.py` was blind to it for
the same reason. Fixed both ways round (the gate, and the volatility declaration
so the guard can see it), and `readonly_role.sql` now **walks the observer's
navigation and requires every screen behind it to answer** — a "no write policy
names may_view" check can never find a screen that is offered and then refuses.

### The `readonly` role, and a save that silently did nothing — done (0059)

Two defects, and the second is not about `readonly` at all.

**`readonly` was incoherent in both directions at once.** It is in `ADMIN_ROLES`,
so it was shown the whole admin navigation. Asking the database what each of
those screens would return: students and attendance worked; invoices, payments,
expenses, till, discounts, certificates and the audit log all returned **zero
rows**; Reports → Debit & Credit and Staff both raised *Not permitted*; and the
**dashboard showed it `collected_month`, `collected_today` and
`finance_visible: true`**. So it was shown the school's takings on one screen and
an empty table on every screen behind it. It is also the *fallback* role, so that
was the experience of any invited login whose role nobody set.

Settled as an **observer**: reads everything a staff member can read, money
included, writes nothing anywhere. The reasoning and the argument against
including money are in `docs/READONLY-DESIGN.md`; the short version is that two
of the three money surfaces already showed it, so hiding money would have
followed the minority precedent and still left the dashboard leaking — and a role
that cannot see money cannot do the job schools want it for (a trustee, an
auditor, the proprietor's second-in-command).

One helper carries it — `may_view(roles) := has_role(roles) or
has_role('readonly')` — applied to 27 read functions and 19 SELECT policies
**programmatically**, from `pg_get_functiondef`, because hand-retyping
twenty-seven bodies is how a stack of fixes gets silently reverted. Two functions
are excluded by name: `fn_may_manage_class` and `fn_may_write_school_file` are
`STABLE` and look exactly like read gates, but they *authorise writes elsewhere*
— a teacher's mark entry and a storage upload policy consult them.

**The worse defect: a save that reported success and changed nothing.** RLS
treats the write verbs differently, and this is easy to forget:

- `INSERT` with no matching policy → **raises**
- `UPDATE` / `DELETE` with no matching policy → **zero rows, no error**

Every direct-table write in `db.ts` was `const { error } = await
sb.from(x).update(patch).eq('id', id)`, and `error` is null when nothing matched.
Demonstrated: as `readonly`, `insert into students` was refused with a policy
violation and `update students set full_name` returned **success, 0 rows**. The
app said *"Saved."*, the value was unchanged, and reopening the record showed the
old one. From the user's seat that is indistinguishable from lost work.

The same silence had already produced a second bug: when the `create-teacher`
Edge Function is not deployed, the fallback path called `signUp` **without
`school_id` in the metadata**, so `handle_new_user` returned early and created no
profile at all — the follow-up role update matched nothing, raised nothing, and
`createTeacherLogin` returned success on a login that could sign in and be told
*"This login is not attached to a school."*

`mustWrite()` now wraps all eleven direct writes: the statement carries
`.select('id')` and an empty result raises a message naming both real causes. And
an invite whose role is not recognised now lands **inactive** rather than quietly
acquiring the fallback role — a `coalesce` the test suite caught me getting wrong
twice, once returning `true` for an unrecognised role and once returning `NULL`
and failing the signup outright.

Guarded by `supabase/check-readonly-writes.py` (no write policy and no `VOLATILE`
function may name `may_view` or `readonly`; refuses to pass if `may_view` is used
in fewer than 30 places, so it cannot go vacuous) and 35 assertions in
`supabase/tests/readonly_role.sql` — where the UPDATE and DELETE assertions count
**rows affected**, not exceptions, because there is no exception to catch.

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
| `students.photo_url` | was the last item on this list; fixed in 0057, and the column renamed to `photo_path` because it holds a path and not a URL |

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


### A child leaving (0054)

The same thread pulled on the student side. Four findings, three of them defects.

**The only button was "Strike off".** `student_status` has four values — active,
struck_off, withdrawn, graduated. `graduated` is set by the year-end rollover,
which is right. **`withdrawn` was unreachable from anywhere in the app.** So a
child whose family moved city was recorded as *struck off*, which in Pakistan
means removed for non-payment or misconduct. It is what goes in the register and
what a parent would read on a leaving certificate. The most ordinary reason a
child leaves a school could not be recorded correctly.

**Reinstating a graduated child left the two facts contradicting.** The old
function reactivated enrollments only where status was `struck_off` or `left`.
Proven by running it rather than by reading it:

```
GRADUATED:       student=graduated enrollment=graduated
REINSTATED GRAD: student=active    enrollment=graduated
```

That child then reads as a current pupil on every student screen while being in
no class, billed nothing, and counted against no plan limit — `fn_count_students`
requires both statuses active. Nothing on any screen could reveal it. It is now
refused, with a message naming the enrollment status and saying what to do
instead.

**There was no date.** The only trace of a leaving was free text appended to
`students.notes` — "Status → withdrawn: Family moved to Karachi". No date, a
reason only if the clerk typed one, both in a blob holding every other note.
`students.left_on` and `students.leaving_reason` are now columns, and
`fn_students_left` is the report that reads them — without which they would be
two more columns written and never shown, which is the bug class in 0047.

**What already worked, now pinned by tests:** withdrawing a child stops next
month's challan and stops them counting toward the plan limit. Both are asserted
by generating invoices and calling `fn_count_students`, not by reading columns,
because one careless `create or replace` would break either silently.

**One piece of hardening, labelled as such.** `fn_generate_class_invoices` chose
who to bill from `enrollments.status` alone, while `fn_count_students` required
`students.status` and `deleted_at` too — two functions answering "who is a
current pupil" with different conditions. It cannot bite today (the status
function keeps both in step, and *nothing in the codebase writes
`students.deleted_at`*), so this is defence in depth and claiming otherwise would
be overclaiming. It is worth having because the failure mode is billing a child
who has left, and the change can only ever bill fewer children — never skip one
who is here.

**A near miss worth recording.** The first version of that change was hand-typed
from a partial view of the function and diffed against the live definition before
being committed. The diff showed it would have silently reverted five later
migrations: the `unique_violation` guard that makes generation re-runnable, the
`effective_from` lateral join for dated fee structures,
`fn__apply_discount_lines`, and — worst — the `fn_apply_family_credit` pass that
runs after generation. The migration would have applied perfectly cleanly. The
final version is `pg_get_functiondef()` output with eight lines inserted, and
0052 already says why: copy, never retype.

### The year-end rollover promoted children into other schools' classrooms (0055)

**The most serious defect found in this project.** `fn_rollover` had no test suite
at all — the one operation that touches every child in the school, once a year.

It decides where each class promotes to. With no explicit rule it took "the next
class up", and found it like this:

```sql
select id from public.classes c2
where c2.active and c2.level_order > c.level_order
order by c2.level_order limit 1
```

There is no school in that query, and the function is `SECURITY DEFINER`, so RLS
never applies. It searched **every school's classes** and returned the
globally-lowest class above the current level.

Not an edge case. Proven by running it:

* School A tops out at Class 10 with no class above it, so its leavers should
  *graduate*. School B has a Class 11. A's rollover reported "promoted: 1" and
  enrolled A's child in **B's classroom**.
* Worse, **the ordinary case**: A has Class 5 and Class 6, B also has a Class 6.
  Both sixes carry `level_order` 6, so the `limit 1` tie is settled by whichever
  row the heap hands back first — B's. Five consecutive runs put A's child in B's
  class every time.

The enrolment carries school A's `school_id` while pointing at school B's class.
A's own screens then print another school's class names, no fee structure exists
for that class so the child is billed nothing, and a child who should be an
alumnus is not.

`fn_rollover_undo` had its own unscoped query: it counted graduated children
across every tenant and returned the total to this school's principal.

**Why the existing guard missed it.** `dashboard.sql` assertion 20 checks that
every `SECURITY DEFINER` function reading a tenant table *mentions*
`current_school_id` / `assert_own` / `school_id` somewhere in its body.
`fn_rollover` calls `assert_own` on both session ids, so the whole function was
treated as scoped and its individual queries were never examined. **One correct
check exempted eight incorrect ones.** That coarseness is now recorded rather
than quietly patched: the guard proves a function was *considered*, not that
every query inside it is scoped. A per-query analysis in SQL is not something to
bolt on in a hurry.

**Two further changes that came out of the fix.**

Sorting the ladder by id to break ties was the first attempt and it was wrong: a
school with "Class 8" and "Class 8 Science" would have had its children silently
funnelled into whichever won, with nothing on screen to say a choice had been made
for them. An ambiguous rung is now reported as `unmapped` — a state the plan
already had, message "No target class chosen" — so the dry run shows the school
the ambiguity and asks for a rule. Getting there exposed that "no unique next
class" and "no class above at all" were the *same condition* in the old code, so
an ambiguous **middle** year would have been marked as having finished school.

The rollover now also stamps `students.left_on` and `leaving_reason` when it
graduates a year group, capped at today with `least()` — a rollover run before the
session formally ends would otherwise write a leaving date in the future, which
`fn_set_student_status` refuses outright and a direct UPDATE would sneak past.
Without the stamp the largest leaving event of the school year would be absent
from the leavers report added in 0054.

**On the testing.** 38 assertions, and six mutations applied to prove they fail
when the code is wrong. On the first pass **four of five mutations were not
caught** — three because the fixture could not reach the guard (school B had no
graduates, so a scoped and an unscoped count both returned 1; the source session
ended in the past, so the future-date cap was unreachable; school A had only one
class per level, so the ambiguity path was unreachable) and one because the
mutation itself was malformed and the migration silently failed to apply. That is
the third time in this project a test has had to be repaired before it was worth
trusting, and it is the reason every mutation is now run and reported rather than
assumed.

### The rule that came out of 0055

Worth stating on its own, because it is the thing a whole-function scoping check
cannot see.

**Tenant scope chains through identity. It does not chain through a value.**

```sql
join public.invoices i on i.id = al.invoice_id     -- chains: al is already scoped
where i.student_id in (select id from base)        -- chains: base is already scoped
where c2.level_order > c.level_order               -- chains NOTHING
```

The first two inherit their scope from something the caller was verified to own.
The third is a scan of every school's rows wearing the appearance of a
correlated subquery, and it is exactly what `fn_rollover` did.

`supabase/check-definer-queries.py` now fails the build on that shape. It is
deliberately narrow: a broad version of the same idea flagged 65 of 157
`SECURITY DEFINER` functions, and every top candidate was a false positive —
correlated subqueries anchored to a scoped outer row, which the script cannot see
because the anchor is an outer alias rather than a parameter. A guard that cries
wolf 65 times gets ignored, and then it protects nothing.

Auditing all 157 functions for the narrow shape found **one** instance: the
rollover. That is the honest result — not "everything is scoped", but "one
specific dangerous pattern now has a tripwire, and it currently fires nowhere".


### The go-live importers looked up children across every school (0056)

`gr_no`, `admission_no`, `employee_no` and `roll_no` are **per-school counters**.
Every school on the platform has a GR 0001. Both bulk importers — the two tools a
school uses on its very first day — resolved and de-duplicated on those keys with
no school filter, inside `SECURITY DEFINER` functions where RLS never applies.

**`fn_import_students`**, de-duplicating:

```sql
select count(*) into v_cnt from public.students where gr_no = v_gr;
if v_cnt > 0 then ... 'GR ' || v_gr || ' already exists'
```

A school importing its register was told **"GR 0001 already exists"** because
*another* school had a GR 0001. A school could not complete its first bulk
import, and the rejection rate grows with every school that joins the platform.

**`fn_import_opening_balances`**, resolving who a row belongs to:

```sql
select id into v_student from public.students where gr_no = v_gr ...
```

plpgsql `SELECT INTO` takes the first row and raises nothing, so a row could
resolve to another school's child. Step 4 then checks enrolment in the target
session, the foreign child has none, and the row fails with **"Student is not
enrolled in the selected session"** about a pupil who is. Proven by running it.
The name path fails more visibly — *"Name Muhammad Ali matches several students —
use GR No"* for a school holding exactly one, with the advice pointing at the GR
path that is also broken. And the result row carries the resolved `name`, so the
import report could print **another school's pupil** back at the importer.

**This is the third time.** Migration 0042 already found this exact class and
described it correctly:

> "No school filter, so importing staff rejected rows as duplicates because
> ANOTHER school already used that employee number — and a teacher who works at
> two schools on the platform could never be added to the second, because their
> CNIC was 'taken'."

That diagnosis was right and it was applied to **one of the three importers**. The
student importer and the opening-balance importer were never revisited. A careful
sweep happened, it was correct, and two instances still shipped — which is the
argument for `supabase/check-import-keys.py` failing the build rather than for a
fourth sweep.

**Two things went wrong in my own work here, both worth recording.**

The first version of 0056 asserted *"this replacement changed something"*. Run it
twice and the second run raises, because the unscoped text is legitimately gone —
so a re-run would roll back the fixes it had already made. It now asserts the
**end state** (the unscoped form is absent *and* the scoped form is present),
which is idempotent and still fails loudly if the function has been rewritten and
neither form is there. Found by re-running it, not by reading it.

The first version of the test's assertion 2 used a GR number that **both** schools
happened to have — both counters produce 0001 — so the "duplicate" it objected to
was a real one in the importing school and the assertion tested nothing. The
fixture now runs school B's counter ahead of school A's so that B holds a number A
genuinely does not.
