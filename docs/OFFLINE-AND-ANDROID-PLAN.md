# Offline, and the Android app: the plan

Schools in cities with weak or patchy internet will not buy software that stops
when the connection drops. This phase makes The School Manager keep working with
no internet, on an Android app from Google Play and on the office computer, and
catch up by itself when the connection comes back.

This is the plan, its critique, and the order of work. Each chunk is finished
(tested, merged) before the next starts.

---

## 1. The shape of it

**One app, three ways to run it, one database.**

| Where | How | Offline |
|---|---|---|
| Android phones and tablets | Android app from Google Play (new) | Yes |
| Office computer | The Windows program that already exists (`desktop/`) | Yes (after chunk 6) |
| Any browser | The website, as today | Yes, once opened online |

All three are the same React app (`web/`), so the Android app looks and works
exactly like the website: one codebase, one set of screens, one set of fixes.
The Android app is the web app packaged with [Capacitor](https://capacitorjs.com)
(Ionic's native runtime): the screens ship inside the app, so it opens with no
internet at all, and small native pieces add what a phone needs (printing,
sharing a receipt, the back button, network status).

**How web and app stay "connected":** they are not connected to each other. They
all talk to the same Supabase database. Each device keeps a copy of what its
login needs, and a list of work done offline (the outbox). When the internet
returns, the device sends the outbox and refreshes its copy. Every other device
sees that work on its next refresh.

**Why not rebuild the app in Kotlin or React Native:** two apps drift. Every fee
rule, every screen and every fix would have to be written twice. **Why not a
Trusted Web Activity (a website in a Play Store wrapper):** its storage belongs
to Chrome, and "Clear Chrome data" would delete fees collected offline that have
not been sent yet. Capacitor keeps the data in the app's own private storage.

---

## 2. The rule that keeps it correct

**The server stays the only source of truth, and offline work is replayed
through the same server functions.**

The business logic lives in about 300 database functions (fees, receipts,
balances, licence, exams). Copying that logic into the phone would create a
second implementation that disagrees with the first. So:

- **Reading offline:** the device shows the last copy it fetched, labelled
  "as of 9:40 am", plus its own pending work on top.
- **Writing offline:** the device records a *command* ("mark Class 5 present on
  1 Nov", "Rs 2,000 received from Ali on 1 Nov") with its own ID. On sync the
  server runs the same function the online screen would have run, exactly once.
  If the server refuses (the day was finalised, the pupil has left), the command
  goes to a **Needs attention** list on the device. Nothing is ever dropped
  silently.

---

## 3. What works offline, and what does not

Making all ~300 actions work offline is neither possible nor wise. Money
corrections, billing runs and publishing results need the live state. Three
tiers:

**Tier A: works fully offline (read and write)**

| | Who |
|---|---|
| Daily attendance and subject attendance | Teachers, office |
| Marks entry (exam papers and class tests) | Teachers |
| Fee collection at the counter, single child and whole family, with receipt | Office |
| Expenses | Office |
| Pupil list, search and profiles; balances as of the last sync, with pending payments taken off | Office, teachers (their classes) |
| Today's collection summary (synced plus pending) | Office |
| New admissions (only if chosen for release 1, see questions) | Office |

**Tier B: readable offline, from the last sync**

- Parent portal: fees, statement, attendance, results, tests.
- Ledgers, challans already generated (they can be printed), date sheets.
- Results already published, and reports opened while online.

**Tier C: online only.** These are clearly marked "needs internet"; nothing is
broken or half-done.

- Billing runs and challan generation.
- Exam setup, result generation and publishing.
- Payment reversals, refunds and credit notes.
- Settings, logins and staff accounts.
- Subscription.
- CSV import and the Rapid Data Entry grid. These stay exactly as they are,
  untouched (standing instruction).
- The operator console.

---

## 4. Server side (one new migration, `0157`, bundle 57)

1. **Devices and leases.** `sync_devices` records:
   - who and what: device ID, school, user, platform and app version;
   - when: first seen and last seen;
   - the lease end;
   - whether it is revoked.

   `fn_sync_hello` runs at the start of every sync. It returns the server time,
   the lease, the minimum supported app version, and whether this device may
   still work.
2. **The lease** is how long a device may work offline before it must connect:
   - It runs N days from the last sync (see questions).
   - It never runs past the day the school's licence locks.
   - It stops a locked school, a removed teacher or a stolen phone from
     carrying on offline indefinitely.
   - It is checked both on the device and again on the server. Every lease is
     kept (`sync_leases`), so the server accepts a command only if it was made
     while its device held one, however late it arrives. A device back after its
     lease ran out starts a new lease, and work dated in the gap is refused.
   - A school that locks while a device is offline keeps the work done before
     the lock (it goes in after the lock, past the subscription gate, for that
     one command only). Work dated after the lock waits on the device and goes
     in when the school renews.
3. **Exactly once.** `client_commands` keeps one row per command ID. A command
   resent after a dropped connection returns its first result and is not applied
   twice. The row is written in the same transaction as the work.
4. **One entry point.** `fn_offline_apply` checks the device, the lease and the
   dates. It then sends each command type to the existing function that does that
   work. Release 1 command types:
   - attendance for a day;
   - subject attendance;
   - exam marks;
   - test marks;
   - a payment;
   - a family payment;
   - an expense;
   - admission, if chosen.
5. **The day it happened, not the day it synced.**
   - A payment taken offline is saved with `created_at` set to when the money
     was taken. Every report already files payments by `created_at`, so
     Monday's cash lands in Monday's cash book and no report had to change. The
     same holds for an offline admission and its admission fee.
   - Attendance and expenses already take a date.
   - The server refuses times in the future and anything over 120 days old.
6. **The newer entry wins by when it was made.** Attendance and marks rows now
   carry `authored_at`: now for the screens, the moment it was made for an
   offline entry. An offline entry older than what is already there (a
   correction made later on another device) is left out, and the device is told
   which pupils were left.
7. **Receipt numbers** follow the decision in the questions: a block of 200 per
   device, topped up below 100, taken off the school's own counter. A number
   already used, or never given to the device, is recorded under a fresh number
   and flagged for the owner; the same payment sent twice is recognised by its
   receipt and kept once.
8. **The existing functions keep their parameters.** The database is updated by
   pasting files. Old app versions in schools' hands must keep working.
9. **Tests.** A new SQL suite, `the_work_goes_on_without_the_internet.sql`, covers:
   - a command sent twice is applied once;
   - leases, revoked devices and bad clocks;
   - two devices marking the same class;
   - marks entered after results were published;
   - payments for pupils who have left, and over the pupil limit;
   - every refusal returned as a sentence.

## 5. Device side (`web/src/offline/`, shared by all three)

1. **Local database:** IndexedDB, via the small `idb` library. Unlike
   localStorage it has no 5 MB limit, and writes are atomic. Everything is
   stored under the signed-in user and school. Unsent work stays on the device
   for the login that made it; the offline copies (chunk 3) are wiped on
   sign-out.
2. **Outbox:**
   - Commands are kept in order, each pending, held (waiting on another entry
     that needs attention) or needing attention. An applied command leaves the
     outbox, and the server's answer is kept for the notices.
   - A receipt number is taken in the same IndexedDB transaction that saves the
     payment, so two tabs can never print the same number.
   - A command that needs another (a fee for a pupil admitted offline) goes
     only after that one is applied, never in the same batch.
   - Signing out with unsent work asks first ("3 entries have not been sent").
     The work stays on the device for that login and is sent the next time
     they sign in there.
   - On a shared office computer, another person's unsent work waits for that
     person. It is never sent under the wrong login.
   - A device the school has switched off hands in everything it holds (the
     server keeps it for the owner) and then forgets it.
3. **Sync** runs when the connection returns, when the app resumes, every
   minute while online, and from a **Sync now** button. Each run:
   1. refreshes the sign-in;
   2. says hello;
   3. sends the outbox, oldest first;
   4. refreshes the copies.

   Only one browser tab syncs at a time (Web Locks).
4. **Offline copies ("packs")** are kept at the fetch boundary: supabase-js is
   given a fetch (`readCache.ts`) that keeps a copy of every read, per login, in
   IndexedDB, and answers from it when the network fails, or after four seconds
   on a crawling connection while the request carries on and refreshes the copy.
   Only table reads and RPCs Postgres guarantees cannot write (STABLE or
   IMMUTABLE and calling nothing volatile, generated from the database and
   checked in CI) are ever answered from a copy; writes always go to the
   network. Screens need no rewrite, and copies are wiped on sign-out. Each
   role's pack is also fetched ahead of time, through the same functions with
   the same arguments the screens use:
   - **Teacher:** their classes, rosters, attendance days and tests.
   - **Office:** pupils with balances, fee heads, today's collections and recent
     receipts.
   - **Parent:** their children's fees, attendance and results.

   A slow connection fetches the packs in pieces, and an interrupted fetch picks
   up where it stopped.
5. **Clock.** The device stores how far its clock is from the server's and
   corrects for it. A clock that jumps backwards is noticed.
6. **What people see:**
   - a status chip: *Online*, *Offline: 4 waiting*, or *Last synced 2 hours ago*;
   - "as of" times on offline data;
   - a pending badge on unsent payments and marks;
   - the Needs attention list, with the reason and what to do.
7. **The existing attendance queue** (localStorage) is moved into the outbox on
   first run. No pending marks are lost.

## 6. The Android app (`mobile/`, Capacitor)

1. **Packaging.**
   - The built web app goes inside the app.
   - The package name is permanent once published: `site.theschoolmanager.app`,
     the website's domain reversed. The name on the phone is The School Manager.
     `mobile/check-versions.mjs` fails the build if either place drifts.
   - Android 7.0 and later, built for API 36 (Capacitor 8).
   - No Android backup and no copying to a new phone: the app holds its own
     receipt-number blocks, and a copy on a second phone would print the same
     numbers. A new phone signs in afresh.
2. **Native pieces.**
   - Network status: Android's own view of the network is passed to the
     WebView, so `navigator.onLine` and the online and offline events work and
     no screen needs to know it runs in an app.
   - The back button follows the app's own history.
   - Printing through Android's print system: receipts, challans and result
     cards. The browser's print does nothing inside an Android app.
   - Saving and sharing files (CSV exports, a receipt PDF to WhatsApp).
   - Splash screen and icons, made from the existing artwork.
3. **Google Play payment rules.**
   - An app on Google Play may not sell a subscription, or point people to pay
     outside Google Play.
   - So the Android app shows the subscription's status and "managed by your
     school's owner", with no prices, bank details, "I have paid" form, discount
     codes or plan buying.
   - The website and the Windows program keep all of that.
   - Signup stays on the website. The app is sign-in only.
4. **Build.**
   - GitHub Actions builds a debug APK on every pull request that touches
     `web/` or `mobile/`, and a signed release bundle (`.aab`) on every tag
     `android-vX.Y.Z`.
   - The upload key lives in repository secrets; `mobile/README.md` has the
     steps and the checklist to run on a real phone.
   - The first upload to Google Play is by hand (Play Console requires it).
   - Old app versions are told to update when the server needs a newer one.

## 7. Google Play readiness

- **Privacy policy page** on the website (required; there is none today). It
  covers pupils' and parents' data, held for schools.
- **Data safety answers** and the **content rating**.
- **Target audience 18+**: staff and parents. Children as users would bring
  Google's Families policy, so the portal is a parent login.
- **A demo school with sample data**, and sign-in details for Google's
  reviewers. A sign-in-only app is rejected without them.
- **Store listing:** title, descriptions, phone and tablet screenshots (taken
  from the live preview), and a feature graphic.
- **Your account is a personal developer account.** Google requires a closed
  test with at least 12 testers for 14 days in a row before a personal
  account's new app can go to production. The pilot schools' staff can be those
  testers. **Plan for about three weeks** between the first upload and public
  release.

---

## 8. Critique: what could go wrong, and how the plan closes it

| Risk | Closed by |
|---|---|
| The phone and the server disagree on fees or balances | No business logic copied to the phone; commands run the server's own functions |
| A command applied twice on a flaky network | Command IDs plus `client_commands`, in the same transaction |
| Offline work lost (cleared data, sign-out, another user on the PC) | App-private storage; sign-out blocked while unsent; outbox kept per user; Needs attention never silently cleared; browsers asked to keep storage permanently (`storage.persist`) |
| Monday's cash in Wednesday's cash book | Business date carried in the command; offline payments saved with `created_at` = when the money was taken |
| A wrong phone clock | Server time offset kept from each hello; dates checked against the lease |
| A locked school staying offline to avoid paying | Lease of N days, never past the lock day, checked on the server too |
| A fired teacher or stolen phone | Lease runs out; revoked devices refused and wiped at their next sync |
| Two teachers mark the same class offline | Last one received wins per pupil, recorded in the audit log; a finalised day or published results go to Needs attention |
| An admission that would exceed the pupil limit | Refused at sync with the reason |
| A stale balance misleading the clerk | "As of" times on offline data, and pending payments taken off the balance |
| Old app versions after a database change | Existing functions never change their parameters; versioned command types; minimum version in the hello |
| Google Play rejection (payments, a "website wrapper", privacy, no reviewer login, minors) | Section 6.3, the native pieces, and section 7 |
| Printing and downloads silently doing nothing in the Android app | Native print and share bridges |
| The Windows program refusing to open offline | Its launch check fails offline and sends the clerk to the connect screen; fixed so a known address opens offline (chunk 6) |
| Scope creep ("everything offline") | Tiers A, B and C; Tier C is labelled "needs internet", not broken |

---

## 9. Chunks, in order

Each chunk ends with:
- tests, and every existing suite still passing;
- a pull request with green CI.

| # | Chunk | Done when |
|---|---|---|
| 1 | **Server sync foundation:** migration 0157 (devices, leases, exactly-once commands, payments dated when taken, receipt blocks, `authored_at`, `fn_offline_apply` with the release 1 commands), SQL suite, bundle 57 | `the_work_goes_on_without_the_internet.sql` passes; every suite and guard passes |
| 2 | **Offline engine:** IndexedDB store, outbox, sync loop, clock, lease, Needs attention, status chip, sign-out guard, migrating the old attendance queue | Unit tests with a fake IndexedDB pass; the browser works offline end to end |
| 3 | **Offline copies by role** (teacher, office, parent) and "as of" labels | Every Tier A and B screen opens offline from a fresh sync |
| 4 | **Offline writing in the screens:** attendance, marks, fee collection with receipts, expenses (and admissions if chosen) | Playwright offline tests: work offline, reconnect, the server holds exactly the right rows |
| 5 | **Android app:** Capacitor project, native pieces, Play payment rules, signed build in CI | A signed `.aab` from CI; the owner installs it and runs the device checklist |
| 6 | **Windows program offline:** launch check fixed; offline verified | Opens and works with the network unplugged |
| 7 | **Google Play:** privacy page, data safety, listing, demo school, closed test with 12 testers for 14 days | Production access granted; release 1 published |
| 8 | **Hardening:** focused review of the sync code, the guide chapter, release notes | Findings fixed; documentation published |

## 10. Decisions (taken 1 Nov 2026)

1. **Offline in release 1:** attendance (daily and subject), marks entry (exam
   papers and class tests), fee collection with expenses, **and new
   admissions**. An admission made offline gets its admission number when it
   syncs. A duplicate child, or a roll over the plan's limit, is caught at sync
   and shown in Needs attention.
2. **Receipt numbers:**
   - Each device is given its own block of receipt numbers in advance, topped up
     at every sync, so a receipt printed offline is final at once.
   - Blocks are taken from the school's counter, so they never collide with
     numbers the server hands out.
   - The school's numbers are no longer one unbroken sequence across devices.
     Every block, and any numbers a device never used, is recorded.
3. **Offline limit:** 7 days from the last sync, and never past the day the
   school's licence locks.
4. **Portal:** one login per family. The app's audience is staff and parents
   (18+).
