# Google Play: putting The School Manager on the store

Everything Play Console asks for, ready to paste, and the order to do it in.
How the app is built and signed is in `mobile/README.md`; why it looks the way
it does is in `docs/OFFLINE-AND-ANDROID-PLAN.md`.

**Plan for about three weeks.** A personal developer account must run a closed
test with at least 12 testers for 14 days in a row before Google allows a
release to everyone (step 6).

## 1. Create the app

Play Console, Create app:

| Field | Answer |
|---|---|
| App name | The School Manager |
| Default language | English (United Kingdom), en-GB |
| App or game | App |
| Free or paid | Free |

Keep **Play App Signing** on. Google holds the key that signs the app on
phones; ours (`mobile/README.md`) only signs uploads.

## 2. Store listing

**Short description** (80 characters at most):

> Fees, attendance and results for Pakistani schools, online or offline.

**Full description:**

> The School Manager runs a Pakistani school's day: the register, fees and
> receipts, marks and result cards, admissions, and the parent portal. It keeps
> working when the internet does not.
>
> FOR THE OFFICE
> • Take fees and print the receipt, for one child or a whole family at once
> • See who has paid, who owes, and arrears month by month
> • Record expenses and keep the day book
> • Admit new pupils, with brothers and sisters linked and the admission fee taken
>
> FOR TEACHERS
> • Mark the daily register or subject attendance in seconds
> • Enter exam and test marks, and the results work themselves out
> • Your classes, tests to mark and birthdays on one screen
> • Check in at the gate by scanning the school's QR poster
>
> FOR PARENTS
> • One login for the whole family
> • Fees due, attendance and test results for each child
>
> WORKS OFFLINE
> Registers, marks, fee collection, expenses and admissions keep working with no
> connection for up to seven days. A receipt printed offline is final: each phone
> holds its own block of receipt numbers, so two phones never print the same one.
> Everything is sent when the connection returns, and every other device sees it.
>
> SAFE BY DESIGN
> • Every change is recorded with who made it and when
> • Nothing is deleted: a mistake is corrected with a reversal
> • Each school's records are kept apart by the database itself
> • The school can download a complete copy of its records at any time
>
> The app is for schools that use The School Manager. Your school gives you your
> login.

| Field | Answer |
|---|---|
| App icon | `mobile/store/icon-512.png` |
| Feature graphic | `mobile/store/feature-graphic.png` |
| Phone screenshots | `mobile/store/screenshots/*.jpg`, in their numbered order |
| Category | Education |
| Contact email, phone, website | as on the website's contact page; website `https://theschoolmanager.site` |
| Privacy policy | `https://theschoolmanager.site/privacy` |

The screenshots and the two images are made by `node scripts/shoot-play-store.mjs`
from the live preview (it says how). They show the app as the app shows itself:
no prices and no way to pay, which Google checks.

## 3. App content

| Declaration | Answer |
|---|---|
| Privacy policy | `https://theschoolmanager.site/privacy` |
| Ads | No, the app contains no ads |
| App access | All or some functionality is restricted. Give the demo school's owner login (step 5), with the note: "A demo school with invented records. Sign in with the email and password below." |
| Content rating | Category: Utility, Productivity, Communication or Other. Every question about violence, sexual content, language, drugs and gambling: No. Users interact or share content: No (there is no chat; records are entered by the school). Shares the user's location with other users: No. Digital purchases: No. Expect a rating for everyone. |
| Target audience | 18 and over only. The users are school staff and parents; pupils do not sign in. |
| News app | No |
| Government app | No |
| Financial features | None. The app keeps a school's fee records; it moves no money. |
| Health | No |
| Data safety | Section 4 |

## 4. Data safety

| Question | Answer |
|---|---|
| Does the app collect or share user data? | Collects: Yes. Shares: No (the services that run it, Supabase and Cloudflare, are service providers, which Google does not count as sharing) |
| Is all data encrypted in transit? | Yes |
| Can users ask for their data to be deleted? | Yes: through their school, or by writing to us (privacy page, "How long it is kept, and removing it") |

Data collected, all **required** (the app cannot work without it), none used for
advertising or analytics:

| Data type | Why |
|---|---|
| Personal info: Name | App functionality, Account management |
| Personal info: Email address | Account management (staff logins) |
| Personal info: Phone number | App functionality (parents' numbers on the school's records) |
| Personal info: Other info (B-Form and CNIC numbers, dates of birth) | App functionality |
| Financial info: Other financial info (fees billed and paid) | App functionality |
| Photos | App functionality (a pupil's or teacher's photo, if the school adds one) |
| Location: Precise location | App functionality (staff check-in, only where the school checks location; collected only at the moment of checking in) |
| App activity: Other actions (who changed what, and when) | App functionality, Fraud prevention, security and compliance |
| Device or other IDs (an id the app makes for itself) | App functionality, Fraud prevention, security and compliance |

Not collected: messages, contacts, calendar, files, audio, health, web browsing,
crash logs or diagnostics, advertising IDs.

## 5. The demo school for Google's reviewers

A sign-in-only app is rejected without a login that works. Use the simulated
school, built through the software's own functions and safe to paste into the
live project:

1. In the Supabase SQL Editor, paste `supabase/sim/paste/1_set_the_school_up.sql`
   to `13_check_it_worked.sql`, in order. The last one says whether it worked.
2. Rename the school in Settings, School to "Demo School", so a reviewer is not
   puzzled by the simulated name.
3. From the operator console, give it an owner login the way a real school is
   given one, for example `play-review@theschoolmanager.site` with a long
   password. Keep its subscription active.
4. Put that email and password under App access (section 3).

## 6. The closed test, then everyone

1. Testing, Closed testing: create a track, upload the signed `.aab` from the
   "Android app" workflow (tag `android-v1.0.0`, see `mobile/README.md`).
2. Add at least **12 testers** by email (the pilot schools' staff are the
   natural ones) and send them the opt-in link. Each must opt in and install.
3. Keep at least 12 opted in for **14 days in a row**. Ask them to run the
   checklist in `mobile/README.md`, especially the offline steps.
4. Then, Production, Apply for production access. Google asks what the test
   found and what changed; the answers are the checklist results.
5. Release to production. Later releases: tag `android-vX.Y.Z` and upload.

## 7. Before every release

- The checklist in `mobile/README.md` on a real phone.
- `node scripts/shoot-play-store.mjs` if the screens changed.
- The privacy page still true: anything new the app collects goes in section 4
  and on `https://theschoolmanager.site/privacy` before the release, not after.
