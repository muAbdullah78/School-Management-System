-- =============================================================================
-- The migration ledger — can it be trusted, and can it be forged?
--
-- 0069 added public.schema_migrations because nothing recorded what a given
-- database had actually had applied. Two things had already gone wrong without
-- it: a shipped bundle absorbed five migrations and a live school silently lost
-- fifteen, and when that school reported it the state had to be GUESSED from an
-- error message — wrongly, so the repair handed over failed on its own first
-- statement.
--
-- A ledger is only worth having if it cannot lie. Two ways it could:
--
--   1. Somebody edits it. 0001:704 grants SELECT, INSERT, UPDATE and DELETE on
--      every table in public to `authenticated`, and 0025:768 makes that the
--      default for tables created afterwards — which includes this one. If RLS
--      were off, or if a write policy existed, any signed-in clerk at any school
--      could rewrite the deployment record of the whole platform.
--
--   2. It claims a complete database when the database is half-applied. That is
--      worse than an empty ledger, because "69 of 69 applied" is what an
--      operator would read before deciding NOT to run a repair.
--
-- The rules this file defends:
--
--   1. NO SIGNED-IN USER CAN WRITE A ROW. Not a clerk, not an owner, not the
--      operator. Rows arrive only through the definer function or the service
--      role.
--   2. A SCHOOL USER CANNOT EVEN READ IT. It describes the platform, not a
--      tenant.
--   3. THE OPERATOR CAN READ IT, and fn_platform_schema_state refuses everyone
--      else.
--   4. fn_record_migration IS NOT CALLABLE FROM A BROWSER SESSION.
--   5. A GAP IS REPORTED. A bundle that rolled back halfway leaves a hole in the
--      numeric sequence, and a human reading a list of 69 filenames would not
--      see it.
--   6. RE-RECORDING KEEPS THE FIRST DATE. Every migration here is written to be
--      re-runnable, so a replay must not look like a fresh application.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/migration_ledger.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

-- Did the statement fail, for any reason? Used for the RLS assertions below,
-- where an INSERT with no matching policy RAISES.
create or replace function pg_temp.refused(p_sql text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end;
$$;

-- --- Fixture: one school with an owner, and the platform operator ------------
do $seed$
declare
  v_school uuid;
  v_owner  uuid := '00000000-0000-0000-0000-00000000ed01';
  v_ops    uuid := '00000000-0000-0000-0000-00000000ed0f';
begin
  insert into public.schools (name) values ('Ledger Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'trialing', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'owner@ledger.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Ledger Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  insert into auth.users (id, email) values (v_ops, 'ops@ledger.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email) values (v_ops, 'ops@ledger.test')
    on conflict (user_id) do nothing;

  create temp table _led (k text primary key, v uuid);
  insert into _led values ('school', v_school), ('owner', v_owner), ('ops', v_ops);
end $seed$;

-- --- 0. The baseline actually recorded THIS database -------------------------
-- First, because everything below deliberately deletes and forges rows. The
-- first version of these two assertions sat at the end of the file and failed on
-- a premise its own gap test had broken — 0044 was gone by then.
--
-- Not a tautology either: this suite runs against a database built by applying
-- every file in supabase/migrations/ in order, so 0069's adoption block really
-- ran here. If any of its six bundle probes were wrong, or if the array_append
-- bug that only appears on the refusal path had been left in, this is where it
-- surfaces.
do $pristine$
declare v_state jsonb; v_baseline bigint; v_total bigint;
begin
  select count(*) into v_baseline from public.schema_migrations where bundle = 'baseline';
  select count(*) into v_total    from public.schema_migrations;

  if v_baseline <> v_total then
    raise exception 'FAIL  0a. % of % ledger rows came from somewhere other than the baseline',
      v_total - v_baseline, v_total;
  end if;

  perform set_config('test.uid', (select v::text from _led where k='ops'), false);
  set local role authenticated;
  v_state := public.fn_platform_schema_state();
  reset role;

  -- No gaps AT ALL is the exact statement. A count check (>= 69) would pass over
  -- a partially-recorded chain, and passing over a partial revert is a mistake
  -- this project has made four times.
  if (v_state->>'gaps_total')::int <> 0 then
    raise exception 'FAIL  0b. a freshly-migrated database has % gap(s): %',
      v_state->>'gaps_total', v_state->'gaps';
  end if;
  if not exists (select 1 from public.schema_migrations where filename = '0001_core_schema.sql')
     or not exists (select 1 from public.schema_migrations where filename = '0069_migration_ledger.sql') then
    raise exception 'FAIL  0c. the chain does not run from 0001 to 0069';
  end if;

  raise notice 'PASS  0. the baseline recorded an unbroken chain of % migration(s)', v_total;
end $pristine$;

-- --- 1. The table is actually protected --------------------------------------
select pg_temp.ok(
  (select relrowsecurity from pg_class
    where oid = 'public.schema_migrations'::regclass),
  '1. RLS is enabled on schema_migrations. Without it the blanket grant in '
  || '0001:704 leaves the platform''s deployment record writable by every '
  || 'signed-in clerk at every school');

select pg_temp.ok(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'schema_migrations'
      and cmd <> 'SELECT') = 0,
  '2. there is NO write policy of any kind. A row that a session can insert is '
  || 'a row that can claim a migration was applied when it was not');

-- --- 2. A school user cannot read it or write it -----------------------------
do $$
begin
  perform set_config('test.uid', (select v::text from _led where k='owner'), false);
end $$;

set local role authenticated;

select pg_temp.ok(
  (select count(*) from public.schema_migrations) = 0,
  '3. a school owner reads ZERO rows — the ledger describes the platform, not a '
  || 'tenant, and the read policy is is_platform_admin() only');

select pg_temp.ok(
  pg_temp.refused($$insert into public.schema_migrations (filename) values ('test_forged.sql')$$),
  '4. a school owner cannot INSERT a row');

reset role;

-- Prove the UPDATE and DELETE cases against rows that really exist. RLS makes
-- those affect ZERO ROWS SILENTLY rather than raising, so "it did not throw" is
-- not evidence of anything — the count is.
do $$
declare v_before bigint; v_after bigint; v_touched bigint;
begin
  perform public.fn_record_migration('test_ledger_fixture.sql', 'test-fixture');
  select count(*) into v_before from public.schema_migrations;

  perform set_config('test.uid', (select v::text from _led where k='owner'), false);
  set local role authenticated;

  update public.schema_migrations set note = 'tampered';
  get diagnostics v_touched = row_count;
  if v_touched <> 0 then
    raise exception 'FAIL  5. a school owner UPDATED % ledger row(s)', v_touched;
  end if;

  delete from public.schema_migrations;
  get diagnostics v_touched = row_count;
  if v_touched <> 0 then
    raise exception 'FAIL  6. a school owner DELETED % ledger row(s)', v_touched;
  end if;

  reset role;
  select count(*) into v_after from public.schema_migrations;
  if v_after <> v_before then
    raise exception 'FAIL  6b. the ledger changed size under a school user (% -> %)',
      v_before, v_after;
  end if;
  raise notice 'PASS  5. a school owner cannot UPDATE a ledger row (0 affected)';
  raise notice 'PASS  6. a school owner cannot DELETE a ledger row (0 affected)';
end $$;

-- --- 3. Not even the operator can write it by hand ---------------------------
-- The operator is the one person who might reasonably want to, which is exactly
-- why it has to be refused: a deployment record its owner can edit is a record
-- that proves nothing to anybody, including its owner six months later.
do $opswrite$
declare v_touched bigint;
begin
  perform set_config('test.uid', (select v::text from _led where k='ops'), false);
  set local role authenticated;

  if not pg_temp.refused(
      $q$insert into public.schema_migrations (filename) values ('test_by_hand.sql')$q$) then
    raise exception 'FAIL  7. the operator inserted a ledger row directly';
  end if;

  update public.schema_migrations set applied_at = now() - interval '1 year';
  get diagnostics v_touched = row_count;
  reset role;
  if v_touched <> 0 then
    raise exception 'FAIL  8. the operator back-dated % ledger row(s)', v_touched;
  end if;
  raise notice 'PASS  7. the operator cannot insert a ledger row by hand';
  raise notice 'PASS  8. the operator cannot back-date a ledger row';
end $opswrite$;

-- --- 4. fn_record_migration is not reachable from a browser session ----------
select pg_temp.ok(
  not has_function_privilege('authenticated',
    'public.fn_record_migration(text, text, text)', 'execute'),
  '9. fn_record_migration is revoked from `authenticated`. It is SECURITY '
  || 'DEFINER, so a grant here would hand every signed-in user a way to write '
  || 'whatever it likes into the deployment record');

-- --- 5. The operator CAN read, and only the operator -------------------------
do $$
declare v_state jsonb; v_n bigint;
begin
  perform set_config('test.uid', (select v::text from _led where k='ops'), false);
  set local role authenticated;
  select count(*) into v_n from public.schema_migrations;
  v_state := public.fn_platform_schema_state();
  reset role;

  if v_n = 0 then
    raise exception 'FAIL  10. the operator cannot read the ledger';
  end if;
  if (v_state->>'applied_count')::bigint <> v_n then
    raise exception 'FAIL  10b. fn_platform_schema_state disagrees with the table (% vs %)',
      v_state->>'applied_count', v_n;
  end if;
  raise notice 'PASS  10. the operator reads % row(s), and the summary agrees', v_n;
end $$;

do $ownerstate$
begin
  perform set_config('test.uid', (select v::text from _led where k='owner'), false);
  set local role authenticated;
  if not pg_temp.refused($q$select public.fn_platform_schema_state()$q$) then
    raise exception 'FAIL  11. a school owner could read the platform schema state';
  end if;
  reset role;
  raise notice 'PASS  11. fn_platform_schema_state refuses a school user';
end $ownerstate$;

-- --- 6. A gap is reported ----------------------------------------------------
-- The failure mode this exists for: a bundle is ONE transaction, so a bundle
-- that dies halfway rolls back entirely and its migrations never arrive. The
-- ledger then holds 0001..0039 and 0050..0069 — and a human scrolling 60
-- filenames does not notice that 0040..0049 are absent.
do $$
declare v_state jsonb; v_gaps jsonb;
begin
  delete from public.schema_migrations where filename like '0044%';

  perform set_config('test.uid', (select v::text from _led where k='ops'), false);
  set local role authenticated;
  v_state := public.fn_platform_schema_state();
  reset role;

  v_gaps := v_state->'gaps';
  if v_gaps <> '["0044"]'::jsonb then
    raise exception 'FAIL  12. expected exactly one gap at 0044, got %', v_gaps;
  end if;
  if (v_state->>'gaps_total')::int <> 1 then
    raise exception 'FAIL  12b. gaps_total says %, not 1', v_state->>'gaps_total';
  end if;
  raise notice 'PASS  12. a missing migration in the middle is reported as a gap (%)', v_gaps;
end $$;

-- One badly-named row must not make the gap report useless.
--
-- It did: a fixture called '9999_...' drove the series' upper bound to 9999 and
-- the function returned 9,930 "missing" migrations. Two things stop that now —
-- only migration-shaped filenames count towards the bounds, and the list is
-- capped — and a console tile that can be flooded by one stray row is a tile the
-- operator stops reading.
do $flood$
declare v_state jsonb;
begin
  perform public.fn_record_migration('9999_typed_by_hand.sql', 'accident');
  perform set_config('test.uid', (select v::text from _led where k='ops'), false);
  set local role authenticated;
  v_state := public.fn_platform_schema_state();
  reset role;

  if jsonb_array_length(v_state->'gaps') > 25 then
    raise exception 'FAIL  12c. the gap list is unbounded (% entries)',
      jsonb_array_length(v_state->'gaps');
  end if;
  if (v_state->>'gaps_total')::int < 100 then
    raise exception 'FAIL  12d. premise broken — 9999 should have opened a huge range, gaps_total=%',
      v_state->>'gaps_total';
  end if;
  raise notice 'PASS  12c. one stray filename gives % capped entries out of % real gaps',
    jsonb_array_length(v_state->'gaps'), v_state->>'gaps_total';

  delete from public.schema_migrations where filename = '9999_typed_by_hand.sql';
end $flood$;

-- --- 7. Re-recording keeps the FIRST date ------------------------------------
-- Every migration in this project is written to be re-runnable, and bundles get
-- re-pasted. If a replay overwrote applied_at, "when did production get 0065?"
-- would answer with the date of the last replay, which is the one date nobody
-- is asking about.
do $$
declare v_first timestamptz; v_second timestamptz;
begin
  perform public.fn_record_migration('test_replay.sql', 'first-time');
  select applied_at into v_first from public.schema_migrations where filename = 'test_replay.sql';

  perform public.fn_record_migration('test_replay.sql', 'second-time');
  select applied_at into v_second from public.schema_migrations where filename = 'test_replay.sql';

  if v_second <> v_first then
    raise exception 'FAIL  13. a replay moved applied_at (% -> %)', v_first, v_second;
  end if;
  if (select bundle from public.schema_migrations where filename = 'test_replay.sql')
       <> 'first-time' then
    raise exception 'FAIL  13b. a replay overwrote which bundle first carried it';
  end if;
  raise notice 'PASS  13. re-recording a migration keeps the date it FIRST landed';
end $$;

select 'MIGRATION LEDGER: ALL TESTS PASSED' as result;

rollback;
