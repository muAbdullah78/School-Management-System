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
| Admission Inquiries | `missing` | Lead management — a walk-in enquiry recorded before any admission, then converted. This is how they win the admission season. |
| Admission Reports | `missing` | Admissions Today / This Month / This Year / Admission Forms / **Blank Admission Form**, all printable. |

## 2. Student Management

| Their screen | Status | Notes |
|---|---|---|
| Student Information | `partial` | Ours opens as a list of 50 with no columns. Theirs is a filtered table (campus, class, section, type) with export and pagination. |
| Student Attendance | `have` | Ours is genuinely good — mark-all, keyboard entry, offline, print. |
| Student Promotion | `have` | Year Rollover. |
| Student Transfer | `missing` | Between **campuses**. Needs multi-campus first. |
| Student Birthdays | `missing` | Today's birthdays, students and staff, with a WhatsApp wish. |
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
| Staff Birthdays | `missing` | As above. |
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
| Print Balance Sheet | `missing` | |
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
| Find A Balance Sheet | `missing` — needs an as-at-date snapshot, not a range |
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
| Teacher Remarks | `missing` | Per-student comment on the result card. Nothing in the schema stores one. |
| Test Schedule / Exam Timetable | `have` | `DateSheet.tsx`, reached from Exam Setup. |
| **Tabulation Sheet** | `have` | `TabulationSheet.tsx`, reached from Result Cards. Corrected — first drafted as `missing`, then found and confirmed reachable. |
| **Position Holders** | `partial` | Position is computed and printed on the result card and the tabulation sheet. There is no standalone "top three in each class" screen. |
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
| Inquiry Add / Inquiry Admit | `missing` (needs enquiries) |
| Exam Marks / Final Exam Marks | `missing` |
| First / Second / Third Fee Reminder | `have` — two templates, escalating; sent from Bulk collect (0040) |
| Absent SMS | `missing` |
| Transfer Student | `missing` (needs campuses) |
| Fee Payment / Direct Student Payment | `have` — receipt on payment |
| Leave Approval / Leave Reject | `missing` (needs a leave flow) |
| Student / Staff Birthday Wish | `missing` |
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
| **Global search in the header** | `missing` | "Search Student / Teacher / Parent here…" from anywhere. |
| Module search in the sidebar | `missing` | "Search a module…" — with ~20 modules, this is how staff navigate. |
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
7. **Teacher remarks and a position-holders screen.** The tabulation sheet,
   date sheet and admit cards already exist — verified reachable, not assumed.
8. ~~**The reporting area**~~ Six of the eight done (0044). Remaining: a
   balance sheet (needs an as-at-date snapshot rather than a range) and a
   standalone accounts-summary screen.
9. ~~**WhatsApp automation**~~ Done (0043).
10. **Admission enquiries and requests.**
11. **Global search, module search, student photos, birthdays.**
12. **Multi-campus** — last, because it touches every table, and only if a real
    school asks for it.

Items 1–6 are what makes the product usable daily. 7–9 are what makes a head
teacher choose it. 10–12 are growth.
