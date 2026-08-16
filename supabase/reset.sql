-- =============================================================================
-- Reset a Supabase project back to empty, so the migrations can be loaded fresh.
--
-- WHY THIS FILE EXISTS: Supabase has no "Reset database" button. Project
-- Settings only offers Restart and Pause, neither of which touches your data.
-- The supported way to wipe a project you own is to drop the public schema.
--
-- ⚠️  THIS DELETES EVERY STUDENT, PAYMENT AND RECORD IN THE PROJECT.
--     There is no undo. Only run it on a project whose data is disposable.
--     If there is ANY chance the data matters, take Settings → Database →
--     Backups first, or use Settings → General → Export data in the app.
--
-- What it does NOT touch: your project URL, your API keys, your Edge Functions,
-- or the Supabase auth system itself. You do not need a new project.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- HOW TO USE
--
--   1. Supabase dashboard → SQL Editor → New query
--   2. Paste this whole file, press Run
--   3. Go to Authentication → Users and delete every user (see the note at the
--      bottom — this step is NOT optional)
--   4. Load supabase/migrations/0001 … 0034 in order, as in docs/SETUP.md
--
-- Verified end to end against Postgres 16: 34 migrations → this reset → 34
-- migrations again, clean both times.
-- =============================================================================

-- Everything the application owns lives in `public`, so one drop removes all of
-- it — 47 tables, the enums, the functions and every policy and trigger.
--
-- This also cascades to `on_auth_user_created`, the trigger sitting on
-- auth.users, because that trigger calls public.handle_new_user(). That is
-- correct and intended: migration 0011 recreates it. If it were left behind it
-- would fire on the next signup and fail, pointing at a function that no
-- longer exists.
drop schema public cascade;
create schema public;

-- Restore the grants a brand-new Supabase project ships with. Skipping these
-- leaves the API unable to see anything the migrations then create.
--
-- Each role is checked before it is granted to. That is not defensive
-- programming for its own sake: the DROP above has already happened by this
-- point, so a plain `grant ... to service_role` that hits a missing role
-- aborts the script halfway — schema deleted, grants never applied — and
-- leaves you with a project that looks reset but silently returns nothing
-- through the API. Skipping a role that does not exist is always safer than
-- stopping here.
do $$
declare r text;
begin
  foreach r in array array['postgres', 'anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      raise notice 'role % not present on this project — skipped', r;
      continue;
    end if;

    execute format('grant usage on schema public to %I', r);
    execute format('alter default privileges in schema public grant all on tables to %I', r);
    execute format('alter default privileges in schema public grant all on functions to %I', r);
    execute format('alter default privileges in schema public grant all on sequences to %I', r);

    -- Only the privileged roles get CREATE on the schema.
    if r in ('postgres', 'service_role') then
      execute format('grant all on schema public to %I', r);
    end if;
  end loop;
end $$;

-- =============================================================================
-- STEP 3 IS NOT OPTIONAL — DELETE THE OLD LOGINS
--
-- Logins live in `auth.users`, which is a different schema and therefore
-- SURVIVES everything above. Leaving them behind breaks the project in two
-- ways that are confusing to diagnose later:
--
--   * The old account can still sign in, but its profile row is gone. It lands
--     in the app belonging to no school and nothing works.
--   * Signing up again with that same email is rejected as already registered,
--     so you cannot recreate the account either.
--
-- Delete them in the dashboard: Authentication → Users → select all → Delete.
-- That is the supported route and it cleans up sessions and identities too.
--
-- The SQL equivalent is `delete from auth.users;` — it normally works from the
-- SQL Editor, but the dashboard is the safer path and takes ten seconds.
-- =============================================================================
