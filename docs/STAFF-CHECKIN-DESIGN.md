# Staff QR check-in — the design, and the argument against each decision

No biometric. That was the instruction, and it is also the constraint that shapes
everything below: **a QR code cannot prove a body was at the gate.** It can prove
that a valid, currently-displayed code was presented by a signed-in account. The
job of this design is to close every gap between those two statements that can be
closed, and to say plainly where the remaining gap is rather than let a school
believe the register is stronger than it is.

---

## 1. What was actually wrong

A QR check-in already existed: a code on the staff-room wall, a deep link, an
optional geofence. Probed on a real database with one teacher, Miss Ayesha, whose
login is linked to her staff record. She is at home.

```
=== LOOPHOLE 1: can she insert her own attendance row directly, no code at all? ===
NOTICE:  INSERTED — no QR code was involved at all

 attendance_date | status  | source | no_code_scanned
-----------------+---------+--------+-----------------
 2026-08-24      | present | qr     | t

=== LOOPHOLE 2: can she back-date a week of attendance she never worked? ===
NOTICE:  back-dated 7 day(s) of attendance
 rows_in_her_register
----------------------
                    8
```

**1a. The QR system was decorative.** `staff_att_insert` allowed
`staff_id = my_staff_id()`, so a teacher could write her own attendance row
straight into the table. She set `source = 'qr'` herself. In the register the
forged row is indistinguishable from a real scan except that `code_id` is null —
and nothing anywhere looked at `code_id`. `fn_staff_check_in` is SECURITY
DEFINER, so that policy branch was never needed for the feature to work: it was
pure surplus, and it handed away the entire mechanism.

**1b. She back-dated a week.** Nothing constrained `attendance_date`. On a school
that pays by attendance that is payroll fraud in one call, and it would also
accept **future** dates — a month of attendance recorded in advance.

**1c. The code was static, with no expiry by default.** 32 hex characters, printed
on a poster, `valid_to` null. A photograph taken in September works in March. The
Location check exists and helps, but it is off by default and the coordinates are
supplied by the phone, so a determined person can send the school's own numbers.

**1d. No check-out, no lateness, no school day.** `staff_attendance` had
`checked_at` and nothing else. A teacher who scans at 8:00 and leaves at 8:20 is
recorded exactly like one who stays until 2:00. `attendance_status` has had a
`late` value since the first migration and nothing could ever produce it, because
`school_settings` held no start time — with no start time there is no such thing
as late.

---

## 2. Decisions

### D1 — A teacher can never write her own attendance row

The `staff_id = my_staff_id()` branch comes out of the INSERT policy. After this,
the **only** paths into `staff_attendance` are `fn_staff_check_in` (a scan) and
`fn_set_staff_attendance` (an office mark, audited). Both are SECURITY DEFINER, so
nothing about the feature changes.

**The objection:** removing a permission a teacher has today could break something
that relies on it. Checked rather than assumed — `check-rpc-contract.sh` and a
grep of `web/src` show no direct insert into `staff_attendance` anywhere in the
app, and the check-in page has always gone through the RPC.

This one change closes 1a and, with D2, most of 1b. It is worth more than
everything else in this document put together, because the rotating code is a
lock on a door that had no wall next to it.

### D2 — Attendance cannot be recorded for a day that has not happened

`check (attendance_date <= current_date)` on the table. Not a trigger: a CHECK is
declarative, applies to every path including a future one nobody has written yet,
and cannot be forgotten. Past dates stay valid for ever, so a dump and restore is
safe.

Back-dating by the **office** stays possible — a principal marking last Tuesday's
absence is ordinary work — but it goes through `fn_set_staff_attendance`, which is
role-gated and audited. A teacher cannot back-date at all, because after D1 she
cannot write the table.

### D3 — The code rotates, and a photograph is worth ninety seconds

A second mode, chosen per code:

| Mode | What the school does | Photograph of it is worth |
|---|---|---|
| **Printed poster** (existing) | print the QR, put it on the wall | **for ever** (or until `valid_to`) |
| **Rotating display** (new) | leave a phone, tablet or the office monitor showing the check-in screen | **30–90 seconds** |

The rotating token is `code.window.digest`, where `window = floor(epoch / 30)` and
the digest is a truncated `sha256(secret || window || secret)`. The server accepts
the current window and the one before it, so a scan is good for between 30 and 60
seconds — and the round trip from rendering to posting is well inside that.

**The secret never leaves the database.** The gate display does not compute the
token; it calls `fn_checkin_display()` every few seconds and renders what comes
back. The alternative — send the secret to the browser and let it compute the
tokens — is shorter code and it means anybody who can read that page's memory, or
the network tab, can mint valid tokens from home for ever. A rotating code whose
seed is in a browser is not a rotating code.

**Why not built-in HMAC:** `pgcrypto` is not installed in this project's Postgres
and no migration has ever required an extension; CI runs on plain Postgres 16.
`sha256()` is built in from PG11. The construction is `H(secret || ':' || window
|| ':' || secret)` — the trailing secret is there so that even the full digest
would not permit a length-extension, which costs nothing to include.

**Why a static code is still allowed:** most Pakistani schools will print the
poster, because it needs no device and no power at the gate. Taking that away
would push them off the feature entirely. What is not acceptable is letting them
believe it is more than it is, so the Settings screen states the weakness in the
same words as this table, and a code marked rotating **refuses a plain code** —
otherwise the rotation is decorative in exactly the way 1a was.

**The remaining hole, stated rather than hidden.** A teacher at the gate can
photograph the rotating QR and send it to a colleague at home who uses it within
the minute. No QR system can stop that; only proving a body was present can, and
that is biometric, which is excluded. What this design does instead is make it
**visible**: every check-in records the token window, the device string and the
second it happened, and the daily register shows them, so two check-ins four
seconds apart on the same token from two different devices is a question a
principal can ask. Silent is worse than possible.

### D4 — A second scan is the check-out

One code, one screen, one habit: scan on the way in, scan on the way out. A third
scan moves the check-out later — people leave, come back for a meeting, and leave
again, and the last departure is the one that matters.

**The objection:** a teacher who scans twice by accident on arrival has just
checked herself out at 8:01. Answered with a floor: a second scan within the
`late_grace_minutes` window of the first is treated as a repeat of the check-in,
not a departure, and the response says so.

### D5 — Lateness needs a school day, so the school day becomes a setting

`school_settings.day_starts_at`, `day_ends_at`, `late_grace_minutes` (default 10).
Arrival after `day_starts_at + grace` is `late`, and `late_minutes` records by how
much. With no `day_starts_at` set, **nothing is ever late** — the status stays
`present` and `late_minutes` is null. Inventing a default start time would mark a
whole staff room late on the day the school upgraded.

`worked_minutes` is filled in at check-out. It is the number a school needs for
payroll, and it is derived from the two timestamps rather than stored twice.

### D6 — An office mark outranks a scan, and overriding a scan needs a reason

If the office has recorded a status for that day, a scan does **not** overwrite
it; the teacher is told what is recorded and to see the office. Otherwise a
teacher marked absent could scan the absence away.

The reverse — the office overwriting a scan — is allowed, because a principal who
knows a teacher left at nine outranks the machine. But when the existing row came
from a scan, `fn_set_staff_attendance` **requires a reason**, which lands in the
audit log. Overriding a recorded fact with a judgement is exactly the thing that
should be explainable a month later.

### D6a — A refusal RETURNS; it does not raise

The first draft logged the attempt and then raised the exception. That logs
nothing. plpgsql has no autonomous transaction, so the raise rolls the log row
back with it — the refusal register would have been permanently empty, and the
brute-force counter in D7, which counts rows in that register, would never have
counted past zero. Two features, both silently dead.

So `fn_staff_check_in` returns `{status: 'refused', reason, message}` and the row
commits. The web wrapper turns a refusal back into a thrown error, so no caller
can treat one as a successful check-in by accident.

Two things still raise: not being signed in, because there is no account to log
against; and the geofence being switched on with no school position set, which is
a misconfiguration by the office rather than an attempt by a teacher, and does not
belong in a register of suspicious activity.

### D7 — Failed attempts are recorded, and brute force is stopped

`staff_checkin_attempts` — one row per refusal, with the reason. Without it, a
teacher trying last term's photograph forty times, or a script walking an
eight-character token, is invisible.

The token space is 8 hex characters, which is 4.3 billion per 30-second window.
That is comfortable, but "comfortable" is not a control: more than **10 failures
in 10 minutes** from one account is refused outright until the window passes. The
count is per account rather than per school, so one person's locked-out phone
cannot stop the rest of the staff checking in.

### D8 — The daily register is the thing that makes any of this useful

`fn_staff_attendance_day(p_date)`: every staff member, present or not, with the
status, arrival, departure, minutes late, minutes worked, whether a code was
actually scanned, which code, and the device string. A school that cannot see
which rows were scanned and which were typed cannot audit its own register, and
1a survived precisely because nothing displayed `code_id`.

---

## 3. What is deliberately NOT built

- **Biometric of any kind.** Excluded by instruction, and the reason this document
  is careful about what a QR can and cannot prove.
- **Trusting the phone's location as evidence.** The geofence stays, because it
  raises the effort, but the coordinates come from the client and a browser can be
  told to lie. It is a deterrent, not a control, and the Settings copy says so.
- **Device registration** — binding a staff member to one phone. Tempting, and
  wrong for a school where a teacher's phone breaks, gets replaced, or is shared.
  The device string is recorded as a hint for a human, not enforced.
- **Per-shift or per-period check-in.** Some schools run two shifts. Until one
  asks, one arrival and one departure per day is the whole model.
- **Payroll.** Salary and loan management is on the exclusion list. `worked_minutes`
  is recorded because a school will export it; nothing computes pay.

---

## 4. What this can and cannot prove

`supabase/tests/staff_checkin.sql` rebuilds the two loopholes from section 1 and
asserts they are shut: the direct insert is refused, the back-dated week is
refused, a future date is refused, a plain code against a rotating record is
refused, a stale token is refused, the previous window still works, a scan does
not overwrite an office mark, the second scan checks out, lateness is computed
only when a start time is set, failures are logged and the eleventh in ten minutes
is refused, and none of it crosses a school boundary in either direction.

What it cannot prove is that the person holding the phone is the person who owns
the account. That is the boundary of a QR system, and the register's own honesty —
showing which rows were scanned and which were typed — is what a school has to
work with inside it.

---

## 5. Found by building this

**Nobody could admit a student.** The check-in suite is the first test in this
project to write `students` as the `authenticated` role rather than as the table
owner, and it stopped dead:

```
ERROR:  permission denied for function fn_photo_path_ok
```

A CHECK constraint's function runs with the privileges of whoever writes the row.
0057 put such a constraint on `students.photo_path`, `staff.photo_path` and
`school_settings.logo_path`, then revoked the function from PUBLIC — the default
grant that was the only reason it worked — without granting it to
`authenticated`. Admitting a child, adding a teacher and saving the school's own
address were all impossible for every signed-in user.

Thirty-four assertions in `photos.sql` covered that constraint and none of them
could see it, because they all write as the table owner and the owner bypasses
both RLS and function-privilege checks. **A test that runs as postgres is not
testing what a school experiences.** Fixed in 0063; guarded by
`supabase/check-constraint-functions.sh`, which asks the question of every
constraint function rather than that one; and asserted in `photos.sql` 35 and 36,
which admit a child as a signed-in owner and then confirm the constraint still
refuses another school's folder from that same position.
