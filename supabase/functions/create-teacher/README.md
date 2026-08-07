# `create-teacher` Edge Function

Creates a teacher/staff **login** (email + password) from inside the app, so the
principal never has to open the Supabase dashboard. Creating auth users requires
the `service_role` key, which must never live in the browser — so it runs here,
server-side, and first checks that the caller is an **owner/principal**.

## Deploy once (per school), during setup

```bash
# from the repo root, with the Supabase CLI logged in and linked to the project:
supabase functions deploy create-teacher
```

The function automatically receives `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
`SUPABASE_SERVICE_ROLE_KEY` from the platform — no secrets to set by hand.

## What the app does

Staff → **Add teacher login** calls this function (`supabase.functions.invoke('create-teacher', …)`).
On success the new login appears in Staff/Users and can be linked to a staff
record and assigned a class.

## If it isn't deployed

The app still works: the "Add teacher login" form shows a clear message telling
the principal to create the login in the Supabase dashboard
(Authentication → Users → Add user), after which the rest of the flow (link
staff, assign class, set role) is done in-app as normal.
