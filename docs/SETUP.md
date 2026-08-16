# Setting up the system — step by step

This is the one-time setup. You do it **once**, not once per school. After this,
schools sign themselves up and you just switch them on when they pay.

Read it top to bottom. Where you have to click something yourself, it says
**YOU DO THIS**. Everything else is already built.

---

## Before you start

You need:

- A computer with internet
- An email address you control
- About 45 minutes the first time

You do **not** need to understand any of the code.

---

## Step 1 — Create the Supabase project — **YOU DO THIS**

Supabase is where all the data lives. One project holds every school.

> ### Already have a project from earlier testing?
>
> You do **not** need a new one. That project becomes your company's central
> database — it is no longer "one school's database". Your Project URL and keys
> do not change, so nothing you have already configured needs re-pasting.
>
> **There is no "Reset database" button.** Project Settings only offers
> *Restart* and *Pause*, and neither one deletes data. To empty the project:
>
> 1. Open **SQL Editor → New query**, paste the whole of
>    [`supabase/reset.sql`](../supabase/reset.sql) and press **Run**.
>    ⚠️ This deletes every record in the project and cannot be undone.
> 2. Go to **Authentication → Users**, select every user, and **Delete** them.
>    **Do not skip this.** Logins live outside the part the script wipes, so an
>    old account would survive with no profile behind it — it can still sign in,
>    lands belonging to no school, and you cannot re-register that email either.
> 3. Come back here and continue from **Step 2** below, loading the migrations
>    from `0001`.
>
> If you would rather keep the old project untouched as a reference, just create
> a new one instead and follow Step 1 normally.

1. Go to **https://supabase.com** and click **Start your project**.
2. Sign up (the free plan is fine to begin with).
3. Click **New project**.
4. Fill in:
   - **Name**: `school-manager`
   - **Database password**: click Generate, then **copy it somewhere safe**.
     You will rarely need it, but if you lose it you cannot get it back.
   - **Region**: choose **Southeast Asia (Singapore)** — it is the closest to
     Pakistan, which makes the app feel faster.
5. Click **Create new project** and wait about two minutes.

### Get your two keys

1. In the left sidebar click **Project Settings** (the gear icon).
2. Click **API**.
3. You will see:
   - **Project URL** — looks like `https://abcdefgh.supabase.co`
   - **anon public** key — a very long string of letters and numbers
4. Copy both into a note. You need them in Step 3.

> There is also a **service_role** key on that page. **Never** put that one in
> the app or send it to anyone. It bypasses every security rule. It is only used
> automatically by the server-side functions in Step 4.

---

## Step 2 — Load the database structure — **YOU DO THIS**

This creates all the tables, rules and safety checks.

1. In Supabase, click **SQL Editor** in the left sidebar.
2. Open the folder `supabase/migrations/` from this project.
3. Open the files **in number order** — `0001_...` first, then `0002_...`, and
   so on to the last one (currently `0035_fee_ops.sql`). Run them **one file at
   a time** — the SQL Editor treats each run as one transaction, and the files
   are written to suit that. For each file:
   - Copy everything in it
   - Paste into the SQL Editor
   - Click **Run**
   - Wait for "Success"
   - Move to the next file

**Order matters.** Each file builds on the one before. If you run them out of
order you will get errors.

If a file gives an error, stop and send me the error message — do not skip it
and carry on, or the ones after it will fail too in ways that are harder to
diagnose.

---

## Step 3 — Point the app at your project — **YOU DO THIS**

1. In this project, go to the `web` folder.
2. Make a copy of `.env.example` and name the copy `.env`.
3. Open `.env` and fill in the two values from Step 1:

```
VITE_SUPABASE_URL=https://abcdefgh.supabase.co
VITE_SUPABASE_ANON_KEY=eyJhbGciOi...the long key...
```

4. Save the file.

That is the only configuration. The same values are used for every school —
a school is identified by **who logs in**, not by which copy of the app they run.

---

## Step 4 — Install the two server functions — **YOU DO THIS**

Two things must happen on the server rather than in the browser, because they
need the powerful key you were told never to expose: creating a school at signup,
and creating a teacher login.

1. Install the Supabase command-line tool: **https://supabase.com/docs/guides/cli**
2. In a terminal, from this project folder:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy signup-school --no-verify-jwt
supabase functions deploy create-teacher
```

Your **project ref** is the `abcdefgh` part of your Project URL.

`--no-verify-jwt` on the first one is deliberate and necessary: a school
signing up does not have a login yet, so that function has to be reachable
without one. It creates nothing but a school and its owner.

---

## Step 5 — Make yourself the operator — **YOU DO THIS**

This is how you get the screen that lists every school.

1. Open the app and go to `/signup`.
2. Sign up with your **own** email — put anything as the school name, e.g.
   "Operator". You will delete this school in a moment.
3. In Supabase, go to **SQL Editor** and run this, replacing the email with the
   one you just used:

```sql
-- Make this login the platform operator
insert into public.platform_admins (user_id, email)
select id, email from auth.users where email = 'you@example.com';

-- Detach it from the dummy school and remove that school
update public.profiles set school_id = null
 where id = (select id from auth.users where email = 'you@example.com');

delete from public.schools
 where id not in (select school_id from public.profiles where school_id is not null);
```

4. Sign out and sign back in. You now land on the **operator console** at
   `/platform` instead of a school app.

You only ever do this once.

---

## Step 6 — Turn on the nightly student count — **YOU DO THIS**

The operator console shows each school's student count. Without this step that
number only updates when you press **Refresh counts** by hand, which means a
school could quietly grow past its plan for weeks before you notice.

1. In Supabase, go to **Database** → **Extensions**.
2. Search for **pg_cron** and enable it.
3. Go to **SQL Editor** and run:

```sql
select cron.schedule(
  'refresh-student-counts',
  '30 20 * * *',                                  -- 01:30 Pakistan time
  $$ select public.fn_refresh_all_student_counts(); $$
);
```

The time is in UTC — `30 20` is 1:30am in Pakistan, when no school is using the
system.

To check it later:

```sql
select jobname, schedule, active from cron.job;
```

If you skip this step nothing breaks; you just have to press **Refresh counts**
in the console yourself.

---

## Step 7 — Check it works

1. Open the app at `/signup` in a private/incognito window.
2. Sign up a fake school — "Test School", any email, any password.
3. It should take you straight into the setup wizard. Complete it.
4. Admit one student.
5. In your normal window, open `/platform`. You should see "Test School" with
   **trialing** and 14 days left.
6. Click **Activate** on it. It should flip to **active**.
7. Delete the test school when you are done:

```sql
delete from public.schools where name = 'Test School';
```

Everything belonging to it is removed with it.

---

## Day-to-day: what you actually do

### When a school signs up
Nothing. They appear in your `/platform` list on a 14-day trial automatically.

### When a school pays
1. Confirm the money is in your bank account.
2. Open `/platform`.
3. Find the school. The plan dropdown is already set to the right size for their
   student count.
4. Choose **1 year** (or the period they paid for) and click **Activate**.

That is it. They can carry on immediately.

### When a school needs more trial time
Click **+14d trial** next to them. Use it for schools genuinely mid-setup.

### Who to call each morning
The `/platform` list is sorted by what needs doing. Anything with orange text
needs a phone call. Everything below it is fine.

---

## Prices (already loaded)

| Plan | Students | Monthly | Yearly |
|---|---|---|---|
| starter | up to 200 | Rs 3,500 | Rs 35,000 |
| growth | 201–500 | Rs 5,500 | Rs 55,000 |
| institution | 501–1,500 | Rs 7,500 | Rs 75,000 |
| custom | 1,500+ | by agreement | — |

Yearly is priced as ten months — "two months free" — because one payment a year
is one collection instead of twelve chases.

To change a price later, run this in the SQL Editor:

```sql
update public.plans set price_yearly = 40000 where code = 'starter';
```

Existing subscriptions keep the price they were activated at until they renew.

---

## Things worth knowing

**Going over the student limit never stops a school working.** They get a note,
you get a flag in `/platform`, and you move them to the right plan at renewal.
Admissions never block — that is deliberate.

**A school that stops paying keeps its data.** After the period ends they get 14
days of grace where everything still works (this covers a bank transfer that has
not cleared yet). After that they cannot enter new information, but they can
still read everything and download all of it. Nothing is ever deleted for
non-payment.

**Backups.** Supabase backs up daily on paid plans. Turn this on before you have
real schools — Project Settings → Database → Backups. On the free plan there is
no automatic backup, so do not run real schools on it.

---

## If something goes wrong

- **A school says they cannot log in** — check `/platform`. If they show
  **locked**, they need to renew. If they show **active**, it is a password
  problem; reset it in Supabase under Authentication → Users.
- **A school says data is missing** — check they are looking at the right
  academic session. Settings → the session dropdown.
- **You see an error you do not understand** — copy the whole message and send
  it to me. Do not run SQL you were not given.
