-- =============================================================================
-- 0071 — Every function in public was callable by the open internet
--
-- Not a live hole. Hardening, and the reasoning for doing it now matters as much
-- as the change.
--
-- WHAT WAS TRUE
--
-- Postgres grants EXECUTE to PUBLIC on every function it creates, unless told
-- otherwise. Nothing in this schema ever told it otherwise, and 0001:702 grants
-- `usage on schema public to anon`. So all 212 functions in public were callable
-- by `anon` — the role a PostgREST request uses when it carries only the
-- anonymous key, which ships inside the browser bundle and is therefore public.
--
-- Measured, as `anon` with auth.uid() null, which is exactly an unauthenticated
-- request:
--
--   fn_provision_school  -> refused: Not permitted
--   fn_platform_schools  -> refused: Not permitted
--   fn_invite_user       -> refused: Only an owner or principal may invite a user
--   fn_dashboard_summary -> refused: Not permitted
--   fn_global_search     -> refused: Not permitted
--   fn_student_list      -> refused: Not permitted
--   next_counter         -> refused: no school context for this user
--   fn_birthdays         -> refused: Not permitted
--
-- Every one refused. So this was inert: each function gates on has_role(),
-- is_platform_admin() or current_school_id(), and an unauthenticated caller has
-- none of them. The deliberately-locked ones are locked properly too —
-- fn_signup_school, the unguarded twin of fn_provision_school, carries
-- acl={postgres=X/postgres} because 0027:236 revokes it from public, anon and
-- authenticated by name.
--
-- WHY CHANGE IT THEN
--
-- Because the only thing standing between the open internet and 212 functions
-- was that every single one remembered to gate itself. That is the same
-- arrangement that failed twice in 0070 — fn_queue_message forgot a school
-- filter, fn__apply_discount_lines forgot both — and when the next one forgets,
-- the difference between PUBLIC and `authenticated` is the difference between
-- "any of this school's staff" and "anybody on the internet".
--
-- WHY IT IS SAFE: IT IS A NARROWING, PROVABLY
--
-- The obvious version of this change — revoke from PUBLIC and hope — breaks
-- things, and I proved that before writing this: a trial revoke dropped
-- service_role from 212 executable functions to 1, and the signup Edge Function
-- calls fn_signup_school as service_role. School signup would have stopped
-- working on a live database.
--
-- So this reads the CURRENT effective privileges out of the catalogue and makes
-- them explicit BEFORE closing PUBLIC. Since PUBLIC includes both
-- `authenticated` and `anon`, granting each role exactly what it can already do
-- and then revoking PUBLIC is a strict narrowing for every role: nothing that
-- works today stops working, and `anon` — which holds no explicit grant of its
-- own — loses the lot.
--
-- Reading the catalogue rather than listing names is what makes this work in an
-- environment I cannot fully replicate locally. Supabase's own bootstrap grants
-- routines to anon, authenticated and service_role explicitly, which my test
-- harness does not do, so a hand-written list built here would be wrong there.
-- has_function_privilege() answers for whatever posture it is actually run
-- against.
--
-- A CAUTION ABOUT TESTING THIS, learned the hard way an hour ago: while probing,
-- I ran `grant execute on all functions in schema public to public` on a scratch
-- database to simulate the old state, and that silently undid 0027's deliberate
-- revoke — so fn_signup_school then "succeeded as anon" and for a moment looked
-- like a critical hole. It was not; it was my own setup. Broad grants are as
-- dangerous as broad revokes, and a probe that changes privileges is testing
-- itself.
--
-- WHAT STILL PROTECTS THE APP
--
-- check-rpc-contract.sh now asserts that `authenticated` can EXECUTE every RPC
-- web/src/lib/db.ts calls. That check is what makes this change checkable rather
-- than hopeful, and it immediately earned its place: it found that
-- fn_exam_marksheet, called from db.ts:1388 since 0015, had never been granted to
-- `authenticated` at all and worked only through the PUBLIC default. Without the
-- grant below, closing PUBLIC would have broken the exam marksheet screen at
-- runtime for every school.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The one function the app calls that never had a grant of its own
--
-- Found by check-rpc-contract.sh's new executability check, not by reading.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_exam_marksheet(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 1b. And the one the signup Edge Function calls, which has never been granted
--     to anybody
--
-- fn_signup_school carries acl={postgres=X/postgres}: 0027:236 revokes it from
-- public, anon and authenticated by name, deliberately, because it creates a
-- school with no authorisation check of its own. Its comment says "only the
-- service role can reach it".
--
-- Except nothing ever granted it to service_role either. It works in production
-- solely because Supabase's project bootstrap runs
-- `grant all on all routines in schema public to service_role` before any of
-- these migrations, so service_role picked it up by accident. A local database
-- built from supabase/migrations/ alone has never been able to run signup at
-- all — which is why this went unnoticed.
--
-- That is precisely the accidental-default arrangement this migration exists to
-- remove, so it gets stated rather than inherited. Without this line, section 2
-- below would faithfully preserve "service_role cannot call it" on any database
-- that was not blessed by the bootstrap, and school signup would be broken with
-- no obvious cause.
--
-- Guarded on the role existing: the local and CI harnesses do not always create
-- service_role, and a missing role must not fail a migration.
do $signup_grant$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function
      public.fn_signup_school(text, text, text, text, text) to service_role;
  end if;
end $signup_grant$;

-- ---------------------------------------------------------------------------
-- 2. Make the current reality explicit, then close PUBLIC
--
-- Order is load-bearing: capture and grant first, revoke second. Reversed, the
-- capture would find nothing to capture.
-- ---------------------------------------------------------------------------
do $grants$
declare
  r record;
  v_auth integer := 0;
  v_svc  integer := 0;
begin
  -- `authenticated` — the signed-in browser session.
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('authenticated', p.oid, 'execute')
  loop
    execute format('grant execute on function %s to authenticated', r.sig);
    v_auth := v_auth + 1;
  end loop;

  -- `service_role` — the Edge Functions. Skipped silently if the role does not
  -- exist: the CI harness and the local one create anon and authenticated but
  -- not always service_role, and a missing role must not fail a migration.
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    for r in
      select p.oid::regprocedure as sig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and has_function_privilege('service_role', p.oid, 'execute')
    loop
      execute format('grant execute on function %s to service_role', r.sig);
      v_svc := v_svc + 1;
    end loop;
  end if;

  raise notice '0071: made explicit — authenticated on % function(s), service_role on %',
    v_auth, v_svc;
end $grants$;

-- Now the PUBLIC grant, and anon's own if Supabase's bootstrap gave it one.
-- Nothing in this product needs an unauthenticated caller to execute a function:
-- the marketing site is static, signup goes through an Edge Function on the
-- service role, and auth itself does not run through PostgREST.
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon;

-- And for functions added later, so this cannot silently regress. Applies to
-- objects created by the role running this migration, which is the role that
-- applies every other migration too.
alter default privileges in schema public revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- 3. Assert the result, in the same transaction that caused it
--
-- Two ways this could go wrong, both silent:
--
--   * anon keeps execute on something — the change did nothing.
--   * an RLS policy helper loses execute — then EVERY policy that calls it
--     errors for a signed-in user, and the app is dead rather than degraded.
--     These six are the ones RLS evaluates as the querying role, so they are
--     the ones whose loss is catastrophic rather than local.
--
-- Raising here rather than leaving it to a test: a half-applied grant change is
-- not a state worth debugging on a live database.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_anon integer;
  v_bad  text := '';
  f      text;
begin
  select count(*) into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_anon > 0 then
    raise exception '0071: anon can still execute % function(s) in public', v_anon;
  end if;

  foreach f in array array[
    'current_school_id', 'is_staff', 'may_view', 'has_role',
    'is_platform_admin', 'my_staff_id', 'my_family_id'
  ] loop
    if exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = f
         and not has_function_privilege('authenticated', p.oid, 'execute'))
    then
      v_bad := v_bad || '  ' || f || chr(10);
    end if;
  end loop;
  if v_bad <> '' then
    raise exception E'0071: a signed-in user lost EXECUTE on an RLS policy helper — every policy calling it would now error:\n%', v_bad;
  end if;

  raise notice '0071: anon can execute nothing in public; every RLS helper still reachable';
end $verify$;
