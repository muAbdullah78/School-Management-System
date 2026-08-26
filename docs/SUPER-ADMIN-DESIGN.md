# The super admin — design

What the operator console has to become before fifty schools is a business
rather than a hope, and what it must deliberately *not* become.

Read the criticism section first. Some of it is about your decisions, one piece
of it is about a change I made last week, and one piece says the most valuable
thing in this document is not a screen.

---

## 1. What exists today, stated honestly

The screenshot that started this said "1 total · 0 paying · 1 on trial" and
Rs 0 across every tile. That console was **not** broken. There is one school, it
is on trial, it has never been invoiced, so nothing has been invoiced,
collected, discounted or owed. Every figure was correct.

The problem is narrower and worse than "the numbers are wrong": the console can
do **one job**. It can bill. Here is the whole of it.

| Exists | What it does |
|---|---|
| `platform_admins`, `is_platform_admin()` | who the operator is |
| `fn_platform_schools` | one row per school: plan, status, days left, count, limit, outstanding, last paid |
| `fn_activate_subscription` | grant time + write the charge, refuse an outgrown plan |
| `fn_extend_trial` | +N days |
| `fn_platform_record_payment` | money arrived |
| `fn_platform_ledger` | one school's invoices and payments interleaved |
| `fn_platform_revenue` | invoiced / collected / discounted / owed over a period |
| `fn_platform_outstanding` | what one school owes |
| `fn_platform_refresh_counts` | recount every school |
| `fn_provision_school` | create a school — **no UI, unreachable** |
| `plans`, `subscriptions`, `platform_invoices`, `platform_payments` | the billing tables |
| `student_count_snapshots` | written every recount, **never read by anything** |
| `PlatformPage.tsx` (510 lines) | one screen: the list, a payment dialog, a statement dialog |

That is a billing tool. Everything else an operator does in a day has no
software behind it at all:

- **You cannot open a school.** There is no detail page. The row shows eight
  fields and that is every fact the console holds about a customer.
- **You cannot see what a school is doing.** Not who its users are, not when
  anyone last signed in, not whether it has ever set a fee head, billed a
  month, or taken a rupee. A school that paid and then never used the software
  looks exactly like a school that runs on it daily — until it doesn't renew.
- **You cannot help.** When a principal phones and says "the fee won't save",
  you have no way to see their screen.
- **You cannot start a school.** `fn_provision_school` has no button.
- **You cannot stop one.** No suspend, no cancel, no removal. 34 tables
  reference `public.schools` with `ON DELETE NO ACTION`: a school, once created,
  is permanent. Test schools from six months ago will still be in your console
  when you have fifty real ones.
- **There is no invoice.** `platform_invoices` holds rows; nothing renders a
  document a school can hand its accountant. No NTN, no withholding tax line.
  A Pakistani private school's accountant will ask for both.
- **An invoice raised in error is permanent.** No void, no credit note.
- **Nothing reminds you.** Renewals are a date in a list you must remember to
  look at.
- **No school can see its own bill.** They have to ask you.
- **You cannot tell schools anything.** No announcement, no maintenance notice.
- **You do not learn when the software breaks for someone.** If a clerk in
  Multan hits an error, you find out if they phone.
- **The website is a leaflet.** `site/index.html` links to `#trial`, `#contact`,
  `#features`, `#how`, `#money`, `#pricing`, `#faq` — its own anchors, and
  nothing else. There is no login link, no signup, no download. The desktop
  `.msi` is built by CI and published nowhere, so "download the app" currently
  means "email me and I'll send you a file".
- **Production has no deployment record.** Migrations are pasted by hand from
  `supabase/bundles/`. Nothing anywhere knows which of the 67 have been applied
  to the live database. That is the single largest risk in this document and it
  is not a screen.

---

## 2. Criticism, including of your decisions

You asked me not to sugarcoat. Six things.

### 2.1 "Full permanent read across all schools" — I'll build it, and I still think it's wrong

You chose this over consented, time-boxed access. I'll build what you chose.
Here is the argument you're overriding, so it's on the record.

The risk is not legal. Pakistan's data-protection bill has no meaningful
enforcement, so nobody is going to fine you. The risk is **commercial**, and it
lands at exactly the wrong moment: the sales meeting.

You are asking a principal to move every child's name, father's name, B-Form,
home address, family phone number, marks and fee history into a database you
control. Sooner or later — probably from a competitor — they will hear that you
can read all of it whenever you like, permanently, without asking. "We would
never look" is not an answer to that; it's the answer everyone gives.

The fix costs almost nothing and turns it around:

> Keep the access. **Log every visit. And show the log to the school.**

A "Support visits" list in the school's own Settings, showing the date, the
reason, and how long you were in, is a stronger sales line than silence:

> "If you call us with a problem, we can enter your account to see what you're
> seeing. Every single time we do, it's recorded, and you can read that record
> yourself in Settings."

That converts your permanent access from a thing you hope they don't ask about
into a thing you volunteer. **I am building the school-visible log as part of
this.** It doesn't restrict you — you still enter any school at any time
without asking — it just means you can't do it invisibly. If you want that
removed, say so and I'll strip it, but I'd be doing it under protest.

### 2.2 Impersonation must stay read-only, permanently

When a school phones about a bug, read-only lets you see it. It does not let
you fix it, and that will be frustrating. The temptation will be to make the
operator session writable.

Don't. Here is what a writable operator session destroys.

The whole reason a school trusts this software with money is that its own audit
trail is truthful — every payment names the clerk who took it, every mark change
names the teacher. The moment the vendor can write as any user, **every row in
every school becomes "possibly the vendor"**. A principal investigating a
missing Rs 40,000 can no longer conclude anything from the ledger. You would be
trading the software's core credibility for the convenience of not asking a
clerk to click Save.

If a school's data genuinely needs correcting, that's a named function that
takes the school id, does the one thing, and writes who did it and why — not
"become the principal and have a poke about".

So: `fn_operator_enter()` grants **SELECT reach only**. Writes are refused at
the database, not hidden in the UI.

### 2.3 I made the licence nag worse last week, and it needs fixing here

Migration 0067 made `subscriptions.student_count` live — every enrolment now
recounts the school immediately. That was right: a school on Starter (Rs 9,500)
that has quietly grown to 420 pupils was Rs 25,500/year of invisible revenue and
nobody found out.

But `LicenceBanner.tsx:35` shows the over-limit notice **to the school**, to
anyone in leadership. Before 0067 that fired whenever somebody happened to press
Refresh. Now it fires the same afternoon a school admits its 101st pupil.

Picture it: a principal admits a child in October, and the software immediately
tells them they've outgrown what they paid for in April. That doesn't read as a
helpful notice. It reads as a meter running, and as a shakedown.

**The operator should learn immediately. The school should learn at renewal.**
So: the console keeps the live flag and the "move them to Growth" prompt; the
school's banner stops mentioning the limit until it is inside 30 days of
expiry, when the conversation is happening anyway and the number is a fact
rather than an accusation. The hard lock at 110% of limit stays — that's abuse
prevention, not nagging.

### 2.4 The most valuable thing here is not a screen. It is a migration ledger

You have 67 migrations. Production gets them by you pasting bundles out of
`supabase/bundles/` into the Supabase SQL editor, in an order kept in your head
and in `SETUP.md`. **Nothing records what has actually been applied.**

With one school, a bad paste is an evening's annoyance. With fifty, a bad paste
is fifty schools down, no rollback, and no way to even determine which state the
database is in — and it will happen at 9am on a Monday, because that is when you
would be doing maintenance.

This is more important than every screen in this document, and it is completely
unglamorous:

- a `schema_migrations` table that records each file, its SHA-256, and when it
  was applied;
- `supabase/apply.sh`, which applies only what is missing, in order, each in its
  own transaction, and refuses to run if a file's hash no longer matches what
  was applied (i.e. somebody edited history);
- a **second Supabase project as staging**, which gets every migration first.
  Free tier. The cost is fifteen minutes of setup and a habit.

I'm putting this in Phase 1, before any console work.

### 2.5 Your backups are a rumour until you restore one

Supabase takes daily backups on the paid plan. Nobody has ever restored one.
An untested backup is not a backup — it's a belief.

Phase 1 includes doing it **once**, by hand, on the staging project, and
writing down the actual steps and the actual elapsed time. When a school's
principal deletes a class of 40 pupils and phones you in tears, the difference
between "we have backups" and "we restore to 6am, here is the ninety minutes it
takes" is your entire reputation.

### 2.6 Mapping the tenant boundary turned up two live cross-tenant defects

Not part of the super admin, but found while establishing what actually gates
tenant access — and both fixed in `0070_queue_message_scoping.sql` before
anything else was built on top.

1. **`fn_queue_message` handed one school another school's family.** It is
   `SECURITY DEFINER`, so RLS does not apply inside it, and it looked up the
   family with `where id = p_family_id` and nothing else. School A's owner passed
   School B's family id and School A's own outbox received School B's family head
   name, phone number, child's name and exact outstanding balance. Enumerable one
   uuid at a time.

2. **`fn__apply_discount_lines` let one school edit another school's fees.**
   Worse, because it is a write. It took an invoice id and an enrolment id
   straight from the caller and checked neither, and despite the `fn__` prefix —
   which in this schema means "revoked from the browser" — it had been granted to
   `authenticated`. School A cut what School B charges a parent from Rs 5,000 to
   Rs 4,000.

Both are the same shape: a definer function looking up a tenant row by a
caller-supplied id with no school filter. The plainest IDOR there is. Two
existing CI guards passed both — one hunts a deliberately different shape, the
other asks only whether a function *mentions* scoping somewhere, and
`fn_queue_message` mentions it twice. `check-definer-idor.py` now judges the
shape per statement.

**What I cannot claim.** I ran a broad sweep for other instances of this shape
and it died on a spend limit before any agent finished, so its "nothing found"
result is worthless. What I have is: the two above, proven and fixed; the new
guard reporting clean across 155 functions and 337 statements; and hand checks
of the near neighbours. That is not the same as a clean bill of health for the
whole schema, and I am not going to present it as one. Re-running that sweep is
on the list.

### 2.7 What I am deliberately NOT building, and why

You said "every feature a big company super admin has". A big company's super
admin exists because a big company has staff, auditors and regulators. You have
neither, and building for them costs weeks that buy nothing:

| Not building | Why not |
|---|---|
| Operator RBAC / roles / permission matrix | You are the only operator. Access control over yourself protects against nothing. I'll add `platform_admins.role default 'owner'` so it's a column change later, not a rewrite. |
| IP allow-listing, device pinning, operator 2FA policy | Supabase auth already has 2FA. The rest guards against a threat model (rogue employee) you don't have. |
| Hash-chained / tamper-evident audit log | Cryptographic proof matters when you must convince a court somebody else altered the log. Today the person who'd alter it is you. A plain append-only table is right. |
| Per-screen access logging inside a school | Logging *which school you entered and when* is the useful unit. Logging every page view is noise you will never read. |
| SSO / SAML / SCIM | For schools with an IT department. Pakistani private schools do not have one. |
| A CMS for the marketing website | See below. |
| Multi-currency, tax jurisdictions | One country, one currency. |
| Feature flags per school | You have one product and one tier structure. Plans already gate what needs gating. |

**On "complete admin control over everything" — one honest correction.** The
website is a static file on Cloudflare Pages; the desktop app is a Tauri build;
the portal is part of the same React bundle as the app. An admin screen cannot
"control" a static page's wording at runtime unless I build a CMS, and a CMS for
a five-section leaflet is a bad trade — it adds a database, an editor, a preview
and a publish step so that you can change a sentence you could change in a git
commit.

What the admin *should* control on the website, and will:

- **the prices shown** — read live from `plans`, so the site can never
  contradict the console;
- **the download link and version** — from a release registry you control, so
  "Download for Windows" points at a real, current file;
- **whether signup is open** — a switch, for when you want to sell by hand.

Wording changes stay a commit. That is the right answer, not a limitation.

---

## 3. What the operator actually does in a day

Every screen below exists to answer one of these. If a screen answers none of
them it isn't in the plan.

1. Who do I call this morning?
2. What is going on at *this* school?
3. A school is on the phone with a problem — what are they seeing?
4. I sold a school yesterday. How do I get them live?
5. Who owes me money, and has anyone chased them?
6. Am I growing, and who is about to leave?
7. Is the system healthy? Did anything break for anyone?
8. This school is finished with us. How do I get their data out and them off?

---

## 4. The design

### Phase 1 — Stop a disaster before building a console

**1a. Migration ledger.** `public.schema_migrations (filename pk, sha256,
applied_at, applied_by)`. `supabase/apply.sh` diffs the directory against the
table, applies the gap in filename order, one transaction per file, and aborts
if a recorded hash no longer matches the file on disk. Also `--dry-run`, which
prints what would be applied and touches nothing — the thing you run before
maintenance.

**1b. Staging project.** A second Supabase project. `apply.sh` takes a target.
The rule: staging, then production, never the other way. This is a habit, not
code, so it goes in the runbook with the exact commands.

**1c. Restore rehearsal.** `docs/RUNBOOK.md`: restore staging from a backup
once, by hand, and write down the real steps and the real elapsed time.

**1d. `operator_actions`.** Append-only: `at, admin_id, action, school_id,
detail jsonb`. Every operator function writes one row. This is what makes the
console's history real rather than reconstructed from billing rows.

### Phase 2 — See one school, and help it

**2a. School detail.** `fn_platform_school_detail(school_id)` — one call, one
screen, everything:

- **Identity** — name, city, address, contact name and phone, when they signed
  up, logo.
- **Licence** — plan, status, expiry, count against limit, full plan history.
- **Money** — outstanding, the ledger, every invoice with its state.
- **People** — every user, role, whether they've ever signed in, last sign-in.
  A school with one login that hasn't been used in three weeks is churning and
  nothing currently says so.
- **Are they live?** The onboarding checklist, computed not stored: session set
  · classes created · fee heads created · fee structure set · students admitted
  · a month billed · a payment taken · a challan printed · staff added. This is
  the most useful thing on the page. A school stuck at "no fee heads" is one
  phone call from being a customer for years, and today you have no way to know
  they're stuck.
- **Are they using it?** Last activity per area: last payment, last attendance
  marked, last mark entered, last certificate. Usage is the churn signal.
- **What have I done to them?** The `operator_actions` history for this school.

**2b. Impersonation.** The support tool, built as you chose it.

- `operator_sessions (id, admin_id, school_id, reason, started_at, ended_at,
  expires_at)`.
- `fn_operator_enter(p_school_id, p_reason)` — writes the row. Requires
  `is_platform_admin()`. **Requires a reason**, free text, one line, because a
  log with no reason is a log nobody can use, including you in six months.

**Correction to an earlier draft of this document.** It said overriding
`current_school_id()` was "the whole trick — **one function** grants reach where
40 new policies would have been needed". That was wrong, and measuring it is
what showed why. Every read policy on a tenant table has the shape

```
school_id = current_school_id()  AND  is_staff()          -- 25 tables
school_id = current_school_id()  AND  may_view(…roles…)   -- 20 tables
```

and `is_staff()`, `may_view()` and `has_role()` all read `public.profiles` by
`auth.uid()`. An operator has **no profiles row in the target school**, so all
three return false and the override alone would have shown them an empty
console. The real mechanism is three functions, not one:

| function | change | why |
|---|---|---|
| `current_school_id()` | falls back to the active session's school when there is no profiles row | a school user has a profiles row, so pays no extra lookup |
| `is_staff()` | `or is_operator_session()` | carries 25 read policies |
| `may_view(…)` | `or is_operator_session()` | carries 20 read policies |
| `has_role(…)` | **untouched** | this is the whole write refusal |

That last row is the good news, and it fell out of the census rather than being
designed: **all 43 write policies gate on `has_role()`.** Not one relies on
`current_school_id()` alone. So leaving `has_role()` untouched refuses every
operator write through RLS with no new code and no new trigger.

The definer-function write path is covered too, and already by CI:
`check-readonly-writes.py` fails if any write policy or any VOLATILE function
mentions `may_view` or `readonly`. Its pattern gains `is_operator_session`, and
then the operator inherits the `readonly` guarantee that 0059 built and that
suite already defends. Impersonation is therefore not a new security boundary —
it is the existing observer boundary, pointed at a school the operator has no
profile in. That is a much smaller thing to get right than forty policies.

- **No session GUC.** The active session is read from the `operator_sessions`
  table, not from `set_config`. Supabase pools connections, so a session-level
  GUC can outlive the request that set it and be read by the next person on that
  connection — a cross-tenant leak with no attacker required. The safe design
  and the auditable one coincide here.
- Belt and braces on top of the above: writes are additionally verified refused
  on every tenant table by test, because "no write policy passes" is a claim
  worth checking rather than reasoning about.
- A red, non-dismissable banner: *"You are viewing Al Qalam School as the
  operator. Read only. Leave →"*. Non-dismissable because the failure mode is
  forgetting you're in someone else's data.
- `fn_operator_leave()`, and an expiry so a forgotten session doesn't live
  forever.
- **`fn_support_visits()` — school-facing.** Settings → *Support visits*: date,
  reason, duration. See §2.1.

### Phase 3 — Money, properly

**3a. The invoice document.** A real printable invoice: your name, address,
**NTN**, invoice number, school name and address, period, plan, line items,
amount in figures and in words, bank details, and a **withholding tax** line
(private schools deduct at source and will send you 96% of the invoice with a
tax certificate — if the system can't represent that, your ledger will be wrong
by 4% on every invoice forever).

**3b. Void and credit note.** `fn_platform_void_invoice(id, reason)` marks it
void, leaves it visible, excludes it from every total. A credit note for
partial reversal. Deleting is never an option — a vanished invoice number is
what an accountant asks about first.

**3c. Renewal automation.** `fn_platform_due_soon(days)` drives a "Renewals" tab
— 30/14/7/0/overdue buckets — and a one-click "raise the renewal invoice".
Generation stays deliberate; the *reminding* is automatic. A cron that silently
invoices fifty schools is how you end up arguing about a charge nobody made
knowingly.

**3d. Dunning ladder.** Per school: when was it last chased, by what, what
next. `platform_reminders`, and a WhatsApp click-to-chat template per stage —
same mechanism the school uses for parents. Consistent, and zero SMS cost.

**3e. School-facing subscription screen.** Settings → *Subscription*: plan,
expiry, count against limit, every invoice with a Print button, what's
outstanding, your bank details, and "I've paid — here's the reference", which
lands in the console as a payment to confirm. This one screen removes most of
your billing phone calls.

**3f. Payment method abstraction.** `platform_payments.method` already exists.
Add `gateway_ref` and a `payment_gateway` setting defaulting to `'none'`. Bank
transfer is the only live path; a gateway becomes a switch and one handler, not
a rewrite. (Recommendation, unasked: don't add a gateway until a school asks
twice. Pakistani schools pay by bank transfer and 2–3% on Rs 35,000/year is real
money for a convenience nobody requested.)

#### Phase 3 as built — and the one thing the design got wrong

Delivered in `0076_platform_settings.sql`, `0077_invoice_documents.sql` and
`0078_renewals_self_serve.sql`, with 125 assertions in
`supabase/tests/platform_billing.sql`. Four differences from the plan above,
each because the plan was wrong or incomplete:

**The withholding tax needed a column on the PAYMENT, not a line on the
invoice.** §3a said "a withholding tax line", which would have been ours to
compute. It is not. Section 153(1)(b) makes the deduction the *buyer's* legal
duty, and the rate depends on whether the school is on the Active Taxpayer List
and whether it is a prescribed withholding agent at all — neither of which we
can know. So the invoice carries a *note* asking for a rate and a CPR, and
`platform_payments.tax_withheld` records what the school actually deducted.
`settled = amount + tax_withheld`, and every balance in the product now uses it.
The 4%-wrong-forever problem §3a predicted is exactly right; the fix is on the
other side of the transaction.

**Sales tax is per invoice and defaults to zero.** Also not ours to guess: it is
provincial (PRA, SRB, KPRA, BRA), the rate differs, and printing a confident 16%
on an invoice from a business that is not registered to charge it invents a
liability. `fn_platform_set_invoice_tax` exists; the default is nothing.

**§3c's renewal safeguard could not have worked, and the test caught it.** The
plan implied a screen-side check for a school already invoiced ahead. The first
implementation reported `already_invoiced` on the worklist — an unvoided invoice
whose period starts after the current period ends — and that column can never be
true. `fn_activate_subscription` raises the invoice AND extends `period_end` in
the same statement, so the newest invoice always *ends* at `period_end` and never
starts after it. A double renewal produces two contiguous invoices and a
`period_end` that moved twice, and nothing downstream can tell that apart from
one long renewal. It would have shipped reading `false` on every row and looked
like a working safeguard.

The guard belongs where the write happens: a trigger refuses an invoice that
duplicates a live one exactly — same school, same plan, same period. That is
precisely the double-click case, where the second transaction has not seen the
first and computes the identical period. What the worklist reports instead is
`invoiced_to` beside `expires_on`, and `unbilled_days` — licence time nobody
billed for, which is a question this product genuinely could not answer before.

**The claim, not the payment.** §3e said "I've paid — here's the reference …
lands in the console as a payment to confirm". Built as a separate table,
`platform_payment_claims`, with no write policy and no path to money except
`fn_platform_confirm_claim`. A school-writable row in `platform_payments` would
let a school clear its own balance by typing a number, and the distinction is
worth the extra table.

Not built from §3d: a `platform_reminders` table. `operator_actions` already
records every deliberate act with a timestamp, so the reminder ladder reads its
own history from there (`last_reminded_at`, `last_reminded_stage`) rather than
keeping a second log that can disagree with the first. `fn_platform_mark_reminded`
records that WhatsApp was *opened* — not that the school read anything, which we
do not know and will not claim.

### Phase 4 — Lifecycle: start a school, and end one

**4a. Provision from the console.** A UI for `fn_provision_school` — name, city,
contact, plan, trial length — plus an owner invite in the same step, through
`user_invites` (0065). Signup by hand is how the first fifty schools arrive.

**4b. Licence control by hand.** Suspend (immediately, with a reason, the
school sees it), unsuspend, cancel. Today lock is purely calendar-driven, which
means a school that has stopped paying and stopped answering the phone stays
live until its date. Per-school grace override for the school that always pays
late and always pays.

**4c. Offboarding — the hard one.** 34 tables reference `public.schools` with
`ON DELETE NO ACTION`, so today a school is permanent. Three steps:

1. **Export everything** — one archive: students, guardians, enrolments,
   invoices, payments, marks, attendance, staff, certificates. Given to the
   school; also your own defence against "you deleted our records".
2. **Archive** — hidden from the console, licence dead, data intact. The
   reversible state, and the right default.
3. **Purge** — `fn_platform_purge_school(id, confirmation_phrase)`, deleting in
   FK order, refusing unless the export has been taken and the phrase typed
   matches the school's name. Irreversible, so it must be hard to do by
   accident.

### Phase 5 — Know the business

**5a. Real metrics.** MRR and ARR from active subscriptions (not from what was
invoiced — a yearly invoice is not twelve months of MRR). Trial→paid conversion.
Churn. Net revenue retention. Average revenue per school. **Growth chart from
`student_count_snapshots`** — the table already written on every recount and read
by nothing; it is your customers' growth, which is your own.

**5b. Render `revenue.by_plan`.** Computed by `fn_platform_revenue` today and
displayed nowhere.

**5c. Phone-sized.** Fifty schools means calls in a car park. The console is a
`max-w-6xl` desktop grid. Being able to record a payment and check a licence
from a phone is worth more than three new reports.

### Phase 6 — Connect the three surfaces

**6a. Release registry.** `app_releases (version, channel, platform, url,
sha256, notes, published_at, is_current)`. The operator records a release; the
website's download button and the app's "update available" both read it. Today
the `.msi` is a CI artifact nobody outside CI can reach.

**6b. Wire the website.** Sign in (→ app), Start free trial (→ signup),
**Download for Windows** (→ current release), Manage subscription (→ the app's
subscription screen). Prices read from `plans`. A signup-open switch.

**6c. Announcements.** `platform_announcements (audience, severity, message,
starts_at, ends_at)` → a banner in the app and the portal. "Maintenance Sunday
6–7am" should not be fifty WhatsApp messages.

**6d. Portal and app gaps** (task #31, listed here because the operator is the
one who hears about them): portal Print prints blank; portal results omit
PASS/FAIL and practicals; no parent self-registration; no forgot-password; no
subject-teacher assignment screen; `fn_fee_increment`, `fn_head_wise_dues` and
`fn_link_students` are unreachable from any UI; `campuses`/`shifts` are dead
tables; no expense-category management.

---

## 5. Order of work, and why

| Phase | Why here |
|---|---|
| 1 — ledger, staging, restore, `operator_actions` | A console you can't safely deploy behind is worth nothing. Unglamorous, first. |
| 2 — school detail + impersonation | The two things you cannot do at all today. Biggest jump in what the console *is*. |
| 3 — invoices, void, dunning, self-serve | Money. The withholding-tax line and the school-facing screen remove most billing phone calls. |
| 4 — provision, suspend, offboard | Needed the day school #2 arrives, and the day school #1 leaves. |
| 5 — metrics, phone layout | Valuable, but only once there are enough schools for a trend to mean anything. |
| 6 — releases, website, announcements | Connects the surfaces. Depends on Phase 1's ledger discipline. |

Two things do not wait for their phase: **§2.3, the licence-nag fix** (my own
regression, going in immediately), and the **`revenue.by_plan` render** (the
figure is already computed).

---

## 6. What "no loopholes" means here, concretely

Every phase ships with the guard that makes the claim checkable, because on this
project the pattern has been that a defect survives review and dies to a test:

- **Impersonation cannot write.** A test enters a school as the operator and
  attempts an INSERT, an UPDATE and a DELETE on students, payments and
  mark_entries, and asserts all six are refused *by the database*.
- **Impersonation cannot be self-granted.** A test proves a school user calling
  `fn_operator_enter` is refused, and that `raw_user_meta_data` cannot reach it
  (`check-metadata-trust.py` already enforces the general rule).
- **Every operator function logs.** A test asserts each `fn_platform_*` /
  `fn_operator_*` writes an `operator_actions` row — because a log with holes is
  worse than no log, it's a false alibi.
- **Void excludes.** A test voids an invoice and asserts revenue, outstanding
  and the school's own subscription screen all move by exactly that amount.
- **Purge leaves nothing.** A test purges a fixture school and asserts zero
  surviving rows across all 34 referencing tables — by querying the FK catalogue,
  not by listing tables I remembered.
- **The migration ledger cannot lie.** A test alters an applied file's bytes and
  asserts `apply.sh` refuses to run.
- **RLS stays universal.** `tenant_isolation.sql` check 4d (added this week)
  already fails CI if any new table in `public` arrives without RLS — which is
  what stops any of the new platform tables becoming a hole.

---

## 7. The two things I need from you

Not blockers — I'm building Phase 1 and 2 now regardless — but both change the
detail.

1. **Your NTN and registered business name and address**, for the invoice
   template (§3a). ~~Placeholders until then.~~ **Done differently, and you do
   not need to tell me at all:** the settings screen exists — the operator
   console, *Our billing details* — and every field starts empty rather than
   plausible, because a placeholder like "Your Company (Pvt) Ltd" reads as
   configured and would be printed on a real invoice by somebody who assumed it
   was. Until you fill it in, the console shows a warning dot on the tab, the
   invoice preview refuses to look finished, and `supabase/verify.sql` reports
   `ACTION NEEDED` with the reason. Nothing about it lands in the repository.

   The NTN is the field that matters most: without it a school cannot claim the
   software as an expense, and cannot file the tax it is required to deduct from
   what it pays you — so it will either pay you late or pay you short, and it
   will not phone to say why.
2. **The 30-day figure in §2.3.** I'm making the school's over-limit notice
   silent until 30 days before expiry. If you'd rather they were told
   immediately, say so — I think that's a mistake and I've said why, but it's
   your business.
