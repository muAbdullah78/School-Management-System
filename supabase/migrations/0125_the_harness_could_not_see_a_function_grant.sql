-- =============================================================================
-- 0125 - An internal helper was reachable from a browser, and four guards could
--        not see it
--
-- CAUGHT BY A SCHOOL RUNNING verify.sql, which is the only reason this is a
-- migration and not an incident. One row of seventy-four:
--
--     one school cannot reach another's families or fees (0070)
--       FAIL: re-run bundle 7 (cross-tenant leak is OPEN)
--
-- That row's third clause asserts a blanket property: NO function named fn__ may
-- be executable by `authenticated`. The prefix is this schema's word for
-- "internal, called only by another function that has already scoped the ids",
-- and supabase/check-definer-idor.py exempts fn__ functions from its
-- per-parameter scoping analysis on exactly that basis. A grant turns the
-- exemption into a hole. It has done before: fn__apply_discount_lines carried
-- the fn__ prefix AND a grant to `authenticated`, and one school could write a
-- discount line onto another school's invoice.
--
-- WHAT WAS OPEN. Two functions.
--
--   fn__mirror_school_name   added by 0123 four hours earlier. Its migration
--                            says `revoke execute ... from public, anon` and
--                            stops there.
--   fn_record_migration      from 0069, and open since. Called only by the
--                            self-recording block at the foot of every bundle,
--                            which runs as postgres in the SQL editor. A
--                            signed-in school user could write rows into
--                            schema_migrations, which is the table verify.sql
--                            and detect.sql read to answer "what is installed
--                            here". Poisoning it makes both of them lie, and
--                            those two are what support relies on.
--
-- Neither is dramatic on its own: a trigger function refuses a direct call
-- ("can only be called as triggers"), and the ledger is a diagnostic. Both are
-- absolutely reachable, and the property is the point.
--
-- WHY REVOKING FROM `public` WAS NOT ENOUGH, which is the lesson. A new function
-- carries EXECUTE for PUBLIC by default, so `revoke from public` looks like it
-- closes everything. On a real Supabase project it does not: the project's
-- bootstrap runs
--
--     alter default privileges in schema public grant all on functions
--       to postgres, anon, authenticated, service_role;
--
-- so every new function ALSO gets an explicit grant to `authenticated`, and
-- revoking PUBLIC leaves it untouched. `revoke ... from public, anon,
-- authenticated` is the spelling that works, and it is the one
-- check-definer-idor.py prints when it fails.
--
-- AND WHY NOTHING CAUGHT IT BEFORE A SCHOOL DID. scripts/preflight.sh and
-- .github/workflows/ci.yml both build their databases with
--
--     alter default privileges in schema public grant all on TABLES to ...
--
-- and no such line for FUNCTIONS. So in every database this project tests
-- against, a new function comes out with no grant to `authenticated` at all,
-- every one of the four guards reads clean, and the defect is invisible until
-- it reaches a project Supabase set up. Both harnesses are fixed in the same
-- commit as this migration; on a database shaped like a real project, and with
-- this migration absent, verify.sql, detect.sql, check-definer-idor.py and
-- check-reachable.sh all fail.
--
-- Re-runnable, and the sweep is deliberately broader than the two known
-- functions: it covers every fn__ helper, so the next one added without a
-- revoke is closed by re-pasting this rather than by a fifth migration.
-- =============================================================================

do $revoke$
declare
  r     record;
  v_n   integer := 0;
  v_had text;
begin
  -- Every internal helper, not just the one 0123 added. `for all functions in
  -- schema` cannot be used here: it would also revoke the two hundred
  -- functions the application legitimately calls.
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like 'fn\_\_%'
       and (has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('anon', p.oid, 'execute'))
     order by 1
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    v_n := v_n + 1;
    v_had := coalesce(v_had || ', ', '') || r.proname;
  end loop;

  if v_n > 0 then
    raise notice '0125: closed % internal helper(s) that a browser could call: %',
      v_n, v_had;
  else
    raise notice '0125: no internal helper was reachable from a browser';
  end if;
end $revoke$;

-- The migration ledger. Named rather than swept, because it does not carry the
-- fn__ prefix and it is not internal: it is a real function with one caller,
-- the recording block at the foot of every bundle, which runs as the table
-- owner. Nothing in the application calls it and nothing should.
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is not null then
    revoke all on function public.fn_record_migration(text, text, text)
      from public, anon, authenticated;
    raise notice '0125: the migration ledger can no longer be written from a browser';
  end if;
end $ledger$;

-- ---------------------------------------------------------------------------
-- THE GUARD. Asserts the property the whole migration is about, and names what
-- is still open rather than only that something is.
-- ---------------------------------------------------------------------------
do $check$
declare v_open text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_open
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like 'fn\_\_%' or p.proname = 'fn_record_migration')
     and (has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('anon', p.oid, 'execute'));

  if v_open is not null then
    raise exception '0125: still reachable from a browser: %. The spelling that '
      'works is `revoke all on function public.<name>(<args>) from public, anon, '
      'authenticated`: revoking from public alone leaves the explicit grant that '
      'a real Supabase project gives every new function.', v_open;
  end if;
  raise notice '0125: no internal helper and not the migration ledger can be '
    'called from a browser';
end $check$;
