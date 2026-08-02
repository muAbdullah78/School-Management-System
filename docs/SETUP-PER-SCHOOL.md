# Per-School Setup Guide

This is the checklist **you** (the seller) follow each time a school buys, to stand up their own isolated copy on **their** Google account. Every school has its own Supabase database, its own hosting, and its own login accounts — nothing is shared between schools.

> Target time once you've done it a few times: **~30–45 minutes** of setup, plus data import. Steps marked 🧑‍💻 are technical (done once per school); the app itself is then non-technical to use.

---

## What each school ends up with
- A **Supabase project** (their cloud database + login system + file storage) on their Google account.
- The **web app** deployed to a free host (Cloudflare Pages or Vercel) at a URL teachers open on their phones — e.g. `https://cityschool-manager.pages.dev`.
- The **desktop app** installed on the headmaster's Windows 10/11 PC (a wrapper around the same app).
- **Login accounts** for the owner, clerk, accountant, and teachers, each with the right role.

---

## Step 1 — Create the school's Supabase project 🧑‍💻
1. Ask the school for a **Google account** (or create one for them, e.g. `cityschool.manager@gmail.com`).
2. Go to **supabase.com** → sign in with that Google account → **New project**.
3. Name it (e.g. `city-school`), pick a **strong database password** (save it), choose the region **Singapore** (closest low-latency region to Pakistan).
4. Wait ~2 minutes for it to provision.
5. From **Project Settings → API**, copy two values (you'll need them in Step 3):
   - **Project URL** (looks like `https://abcdxyz.supabase.co`)
   - **anon public key**

## Step 2 — Load the database schema 🧑‍💻
Using the Supabase CLI on your own laptop (install once from supabase.com/docs):
```bash
supabase link --project-ref <the-project-ref-from-the-URL>
supabase db push          # applies everything in supabase/migrations
```
Then load the starting data: open the Supabase dashboard → **SQL Editor** → paste the contents of `supabase/seed.sql` → **Run**. (This creates the current session, an editable class ladder, and common fee heads.)

## Step 3 — Deploy the web app 🧑‍💻
1. In this repo's `web/` folder, copy `.env.example` to `.env` and fill in:
   - `VITE_SUPABASE_URL` = the Project URL from Step 1
   - `VITE_SUPABASE_ANON_KEY` = the anon key from Step 1
   - `VITE_SCHOOL_NAME` = the school's name (e.g. `City Public School`)
2. Push this project to a **GitHub repo on the school's account** (or your account — your call).
3. Connect that repo to **Cloudflare Pages** (free): build command `npm run build`, output directory `web/dist`, and add the three `VITE_*` values as environment variables. Deploy.
4. You now have the **teacher URL**. Make a QR code for it (any free QR generator) so teachers scan-and-bookmark.

## Step 4 — Create the login accounts 🧑‍💻
1. Supabase dashboard → **Authentication → Users → Add user** → create the **owner's** email + password.
2. In **SQL Editor**, make that user the owner (replace the email):
   ```sql
   update public.profiles
   set role = 'owner', full_name = 'Owner Name'
   where id = (select id from auth.users where email = 'owner@example.com');
   ```
   > A `profiles` row is created automatically for each new auth user by a small trigger; if you prefer, insert it manually. (This trigger is added in the Auth phase; until then, insert the profile row by hand.)
3. Repeat for the clerk, accountant, and each teacher, setting the correct `role`
   (`admin_clerk`, `accountant`, `class_teacher`, `subject_teacher`, `principal`, `readonly`).

## Step 5 — Install the desktop app on the headmaster's PC 🧑‍💻
1. Download the latest **Windows installer** (`.msi`) from the project's Releases (built by CI — see the desktop packaging notes).
2. Run it on the Windows 10/11 PC. On first launch it asks for the **school's app URL** (the Cloudflare Pages URL) — paste it once.
3. The desktop app is now the admin's everyday program; teachers just use the URL on their phones.

## Step 6 — Configure the school in-app (non-technical)
Log in as the owner and, in **Settings**:
1. Set the school **name, logo, address, principal name** (the title becomes "{name} Manager").
2. Confirm/adjust the **class ladder** and add **sections** (A/B…).
3. Set the **fee amounts** for each class and each fee head; add discounts policy.
4. Set the **grade scale** and **passing mark**.
5. Add **subjects** per class.

## Step 7 — Import the students (phased)
1. Give the school the pre-formatted Excel template (identity + class/section first).
2. Import current students to go live on **attendance** immediately.
3. Then import **fee slabs + opening arrears** to switch on **fees**.

## Step 8 — Go-live checks
- Every class has a fee slab; every student has a section; every teacher has a login.
- The owner can see the dashboard; a teacher can mark a class from their phone.
- Show the owner the **Export all data** button (their data is always theirs).

---

## Handover notes for the school
- **Their data lives in their Supabase project** — they own it. Supabase keeps automatic backups; the app also has **Export all data**.
- The free Supabase tier is enough to start; a busy school may later upgrade to the **Pro plan (~$25/mo)** for more storage and daily backups — that's their cost, not yours.
- Keep the Supabase database password and the Google account recovery info safe.
