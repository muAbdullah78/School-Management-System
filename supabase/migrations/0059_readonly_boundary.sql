-- =============================================================================
-- 0059 — `readonly` was incoherent in both directions at once.
--
-- Demonstrated on a real database before anything here was written. Signed in as
-- a `readonly` login, and remembering that the app puts this role in ADMIN_ROLES
-- so it is shown the WHOLE admin navigation:
--
--   students, attendance ........................ works
--   invoices, payments, expenses, till,
--   discounts, certificates, audit_log .......... ZERO ROWS — screens look empty
--   Reports -> Debit & Credit ................... 'Not permitted to read the accounts'
--   Staff ....................................... 'Not permitted'
--   Dashboard ................................... collected_month 500,
--                                                 finance_visible TRUE
--   Fee counter summary ......................... income_today 500
--
-- So the dashboard showed this role the school's takings while every screen it
-- could click through to showed nothing. Somebody sitting in that seat concludes
-- the software has lost the data.
--
-- It is also the FALLBACK role: handle_new_user gives the first account in a
-- school 'owner' and every other account 'readonly', so this was the experience
-- of any invited login whose role nobody set explicitly.
--
-- THE DECISION, with the argument against it, is in docs/READONLY-DESIGN.md:
-- `readonly` reads everything a staff member can read, INCLUDING money, and
-- writes nothing anywhere. The short version of why money is included — two of
-- the three money surfaces already showed it, so hiding it would have followed
-- the minority precedent and still left the dashboard leaking; and a role that
-- cannot see money cannot do the job schools want it for.
--
-- The dangerous half is WRITING, and that stays absolutely shut. There is a CI
-- guard (supabase/check-readonly-writes.py) so no future migration can open it
-- quietly.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. One helper carries the whole rule
--
-- Every READ gate becomes may_view(...); every WRITE gate stays has_role(...).
-- The rule is then legible at a glance — this list may act, and an observer may
-- also look — and it lives in one place instead of being restated in
-- twenty-five function bodies.
-- ---------------------------------------------------------------------------
create or replace function public.may_view(variadic p_roles public.user_role[])
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(variadic p_roles) or public.has_role('readonly');
$$;

comment on function public.may_view(public.user_role[]) is
  'A READ gate: true for any of the given roles, and additionally for readonly. '
  'Must never appear in a write policy or a VOLATILE function — '
  'supabase/check-readonly-writes.py fails the build if it does.';

revoke all on function public.may_view(public.user_role[]) from public;
grant execute on function public.may_view(public.user_role[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Read gates in SECURITY DEFINER functions
--
-- Rewritten PROGRAMMATICALLY from pg_get_functiondef, not by hand. Twenty-five
-- function bodies retyped by hand is how a stack of earlier fixes gets silently
-- reverted — that has already happened once in this repo — and the end state is
-- asserted rather than the fact that a replacement matched, so re-running this
-- migration is a no-op.
--
-- THE TRAP, and why there is an exclusion list rather than a "STABLE means read"
-- assumption: two of these are STABLE and look exactly like reads, but they are
-- PERMISSION PREDICATES that gate writes somewhere else.
--
--   fn_may_manage_class      — a teacher's mark entry and attendance marking
--                              consult it. Adding readonly here would let a
--                              readonly login enter marks.
--   fn_may_write_school_file — the storage.objects INSERT/UPDATE policies
--                              consult it. Adding readonly here would let a
--                              readonly login overwrite a child's photograph.
--
-- Blanket-replacing in either would hand `readonly` the ability to write through
-- the functions that call them, which is the exact thing this migration is
-- supposed to make impossible.
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  r record;
  v_def text;
  v_new text;
  v_changed integer := 0;
  -- Never rewritten. See the comment above; each is a write gate wearing a
  -- read gate's clothes.
  c_exclude text[] := array['fn_may_manage_class', 'fn_may_write_school_file'];
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       -- STABLE or IMMUTABLE only. A VOLATILE function can write, and a read
       -- gate is not what has_role is doing inside one.
       and p.provolatile in ('s', 'i')
       and p.prosrc like '%has_role(%'
       and not (p.proname = any (c_exclude))
       -- may_view itself, obviously.
       and p.proname <> 'may_view'
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := replace(v_def, 'public.has_role(', 'public.may_view(');
    v_new := replace(v_new, ' has_role(', ' may_view(');
    if v_new <> v_def then
      -- pg_get_functiondef emits no trailing semicolon.
      execute v_new;
      v_changed := v_changed + 1;
    end if;
  end loop;
  raise notice '0059: rewrote % read gate(s) to may_view', v_changed;
end;
$rewrite$;

-- The end state, asserted. Not "a replacement matched" — that is not idempotent,
-- and an idempotent check is what lets a school re-run this file safely.
do $check$
declare v_left integer; v_bad text;
begin
  select count(*) into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef and p.provolatile in ('s','i')
     and p.prosrc like '%has_role(%'
     and p.proname not in ('fn_may_manage_class', 'fn_may_write_school_file', 'may_view');
  if v_left > 0 then
    raise exception '0059: % read function(s) still gate on has_role', v_left;
  end if;

  -- And the thing that must never be true.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.provolatile = 'v'
     and p.prosrc like '%may_view(%';
  if v_bad is not null then
    raise exception '0059: may_view reached a VOLATILE function: % — that is a write gate', v_bad;
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 3. SELECT policies
--
-- Nineteen tables had a SELECT policy naming explicit roles with readonly absent,
-- which is why those screens returned zero rows.
--
-- cmd = 'r' ONLY. An ALL policy (students_write, invoices_write) covers SELECT
-- too, and rewriting one of those would open a write.
-- ---------------------------------------------------------------------------
do $policies$
declare
  r record;
  v_new text;
  v_changed integer := 0;
begin
  for r in
    select c.relname as tbl, pol.polname as pol,
           pg_get_expr(pol.polqual, pol.polrelid) as qual
      from pg_policy pol
      join pg_class c on c.oid = pol.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and pol.polcmd = 'r'                      -- SELECT and nothing else
       and pg_get_expr(pol.polqual, pol.polrelid) like '%has_role(%'
     order by c.relname, pol.polname
  loop
    v_new := replace(r.qual, 'has_role(', 'may_view(');
    execute format('alter policy %I on public.%I using (%s)', r.pol, r.tbl, v_new);
    v_changed := v_changed + 1;
  end loop;
  raise notice '0059: rewrote % SELECT policy/policies to may_view', v_changed;
end;
$policies$;

do $check$
declare v_bad text;
begin
  -- Every SELECT policy that names roles must now use may_view.
  select string_agg(c.relname || '.' || pol.polname, ', ') into v_bad
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and pol.polcmd = 'r'
     and pg_get_expr(pol.polqual, pol.polrelid) like '%has_role(%';
  if v_bad is not null then
    raise exception '0059: SELECT policies still gate on has_role: %', v_bad;
  end if;

  -- And no write policy may mention it. This is the one that matters.
  select string_agg(c.relname || '.' || pol.polname, ', ') into v_bad
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and pol.polcmd <> 'r'
     and (coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
       || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')) like '%may_view(%';
  if v_bad is not null then
    raise exception '0059: may_view reached a WRITE policy: %', v_bad;
  end if;
end;
$check$;

-- ---------------------------------------------------------------------------
-- 4. The two money surfaces that already trusted readonly, made explicit
--
-- fn_dashboard_summary decided `finance_visible` from a has_role list that
-- happened to include readonly, which is where the incoherence started: the
-- tiles were shown and the screens behind them were empty. Now that the screens
-- work, the tile is honest — but the decision should be legible rather than
-- incidental, so it is restated here in terms of may_view.
--
-- Rewritten programmatically for the same reason as section 2: fn_dashboard_summary
-- is one of the largest functions in the schema and hand-retyping it would be
-- the third time this project nearly reverted a stack of fixes that way.
-- ---------------------------------------------------------------------------
do $finance$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_dashboard_summary';
  if v_def is null then return; end if;
  -- Section 2 has already turned its gates into may_view; this only asserts it.
  if v_def not like '%may_view(%' then
    raise exception '0059: fn_dashboard_summary was not rewritten — check section 2';
  end if;
end;
$finance$;

-- ---------------------------------------------------------------------------
-- 5. A write that changes nothing must be visible
--
-- RLS treats the three write verbs differently and it is easy to forget:
--   INSERT with no matching policy      -> RAISES
--   UPDATE / DELETE with no matching policy -> ZERO ROWS, no error
--
-- So `update students set full_name` as a readonly login returned SUCCESS. The
-- app said "Saved." and nothing changed. The web layer now checks the affected
-- rows (see mustWrite in web/src/lib/db.ts), but the same protection belongs on
-- the paths that go through the database, for anything that bypasses the app.
--
-- THE FIX LIVES IN THE APP, and only in the app, on purpose.
--
-- The first draft of this section added a `fn_assert_wrote(rows, what)` helper
-- here "so new functions have no excuse". supabase/check-reachable.sh then
-- failed the build, correctly: nothing called it. A helper granted to
-- `authenticated` that no caller uses is precisely the dead code that check
-- exists to catch, and exempting it would have been arguing with my own guard to
-- keep a line I had just written.
--
-- It is not needed either. Every write that matters already goes through a
-- SECURITY DEFINER function, and those raise their own errors — they do not
-- depend on a row count to notice a refusal, because the role check happens
-- before the UPDATE rather than being discovered by it. What was missing was
-- the check on the ELEVEN direct-table writes in web/src/lib/db.ts, and that is
-- where mustWrite() now sits.
--
-- Recorded here rather than left silent, because "why is there no database-side
-- guard for this?" is a reasonable question to ask of the next person reading
-- the migration.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 6. The invited login that had no profile at all
--
-- When the create-teacher Edge Function is not deployed, the app falls back to a
-- plain signUp — and that call passed no school_id, so handle_new_user returned
-- early and created NO profile row. The follow-up `update profiles set role`
-- then matched zero rows, raised nothing, and the app reported success. The
-- teacher could sign in and was told "This login is not attached to a school."
--
-- The app-side fix is to pass school_id. This is the belt: when a profile row is
-- created with no explicit role it is created INACTIVE, so an invite that lands
-- half-finished is inert rather than silently granted the fallback role. Every
-- access gate in the schema already keys on profiles.active (0053).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_school   uuid := nullif(new.raw_user_meta_data->>'school_id', '')::uuid;
  v_asked    text := nullif(new.raw_user_meta_data->>'role', '');
  v_is_first boolean;
  -- Whether the requested role is one we recognise. Metadata is CLIENT-SUPPLIED,
  -- so this is a whitelist and not a cast: casting 'superuser' to user_role would
  -- fail the signup itself, and honouring it is obviously worse.
  --
  -- coalesce is load-bearing. `null in (...)` is NULL, not false, so without it
  -- an invite with NO role at all made v_known NULL, `v_is_first or NULL` NULL,
  -- and the insert died on profiles.active NOT NULL — turning a half-finished
  -- invite from "inert" into "the signup fails". Found by running the suite, not
  -- by reading the line.
  v_known    boolean := coalesce(v_asked in ('principal','admin_clerk','accountant',
                                             'class_teacher','subject_teacher',
                                             'readonly','parent'), false);
begin
  -- No school in the invite metadata: create nothing rather than orphan a row.
  -- The provisioning function attaches the profile explicitly in that case.
  if v_school is null then
    return new;
  end if;

  select count(*) = 0 into v_is_first
  from public.profiles where school_id = v_school;

  insert into public.profiles (id, full_name, role, school_id, active)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(coalesce(new.email, ''), '@', 1)),
    (case when v_is_first then 'owner'
          when v_known   then v_asked
          else 'readonly' end)::public.user_role,
    v_school,
    -- Active only when we KNOW who this is: the school's first account, or an
    -- invite that named a role we recognise. Everything else lands INERT and
    -- waits for the owner to give it a role on the Users screen.
    --
    -- `v_known`, not `v_asked is not null`. The first version of this line used
    -- the latter, so an invite carrying an unrecognised role — say a typo, or a
    -- client sending 'superuser' — fell back to `readonly` and was created
    -- ACTIVE, quietly acquiring sight of the whole school. Caught by assertion
    -- 32 of supabase/tests/readonly_role.sql, which exists for exactly that.
    (v_is_first or v_known)
  )
  on conflict (id) do nothing;

  return new;
end;
$$;
