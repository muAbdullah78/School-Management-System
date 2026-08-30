-- =============================================================================
-- Records left behind when a school row is deleted without its children.
--
-- Covers 0092, and one thing in it matters more than the rest.
--
--   A VALIDATED FOREIGN KEY IS A STATEMENT ABOUT THE PAST.
--
--   `convalidated = true` means Postgres scanned this table at some earlier
--   moment and found nothing wrong. It is not a live guarantee. Rows orphaned
--   afterwards by a path that did not run the enforcement triggers leave the
--   flag standing, and `ALTER TABLE … VALIDATE CONSTRAINT` on an
--   already-validated constraint returns success WITHOUT RE-SCANNING, so it
--   cannot even be used to find out.
--
--   I inverted three checkers — verify.sql, repair/why.sql and 0091 — to trust
--   that flag over a query, on the reasoning that Postgres had already scanned
--   the table and a SELECT had not. On a live project that inversion reported
--   PASS over a real orphan: a false clean, which is the worst kind of checker
--   failure, because the previous version at least made somebody look.
--
--   Assertions 20-24 are that reasoning, executed. They manufacture the exact
--   state, then assert the flag stays true, VALIDATE stays quiet, and the row
--   count is the only reading that tells the truth. If somebody ever restores
--   the inversion, these fail.
--
-- The rest proves the cleanup: what an ordinary DELETE does (it is REFUSED —
-- assertion 10, which is why the live state cannot have come from one), the
-- four refusals in front of the purge, and that a second school in the same
-- database is untouched by any of it.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/orphan_data.sql
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

-- Returns true when the statement was refused. Used for every refusal below:
-- asserting that something RAISES is the only way to test a guard, and a guard
-- that is never tested for its refusals is decoration.
create or replace function pg_temp.refused(p_sql text)
returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end;
$$;

create temporary table _orph (k text primary key, v uuid);

-- ---------------------------------------------------------------------------
-- Fixture: two schools. The second exists only so that every sweep below can
-- prove the cleanup took nothing that was not asked for — a function that
-- emptied both tenants would pass a test that only counted the first one's rows.
-- ---------------------------------------------------------------------------
do $fixture$
declare v_dead uuid; v_live uuid; ops uuid := '00000000-0000-0000-0000-0000000b0001';
begin
  insert into public.schools (name, city) values ('Left Behind School', 'Multan')
    returning id into v_dead;
  insert into public.schools (name, city) values ('Untouched School', 'Sialkot')
    returning id into v_live;
  insert into _orph values ('dead', v_dead), ('live', v_live), ('ops', ops);

  insert into public.subscriptions (school_id, plan_code) values (v_dead, 'starter')
    on conflict (school_id) do nothing;
  insert into public.subscriptions (school_id, plan_code) values (v_live, 'starter')
    on conflict (school_id) do nothing;

  -- An operator, and a ledger row for the dead school. The ledger is the thing
  -- that must SURVIVE the cleanup, unlinked rather than deleted.
  insert into auth.users (id, email) values (ops, 'ops@orphan.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email) values (ops, 'ops@orphan.test')
    on conflict (user_id) do nothing;

  insert into public.platform_invoices (school_id, school_name, plan_code, cycle, months,
                                        period_start, period_end, amount, list_amount,
                                        issued_on, due_on)
  values (v_dead, 'Left Behind School', 'starter', 'yearly', 12,
          current_date - 30, current_date, 12000, 12000, current_date - 30, current_date);
end $fixture$;

-- ---------------------------------------------------------------------------
-- 10 — an ordinary DELETE cannot produce the state this file is about
--
-- This is the assertion that ruled out every explanation before it. `profiles`
-- and `school_settings` took their school_id from 0025's generic
-- `add column school_id uuid references public.schools(id)` loop, with no ON
-- DELETE clause, so both are NO ACTION and either one stops the delete before a
-- single row moves.
-- ---------------------------------------------------------------------------
do $plain$
declare d uuid := (select v from _orph where k = 'dead');
begin
  perform pg_temp.ok(
    pg_temp.refused(format('delete from public.schools where id = %L', d)),
    '10 a plain DELETE of a school is refused by its NO ACTION children');

  perform pg_temp.ok((select count(*) from public.schools where id = d) = 1,
    '11 and the school is still there, so nothing partial happened');

  perform pg_temp.ok(
    (select count(*) from pg_constraint
      where contype = 'f' and confrelid = 'public.schools'::regclass
        and confdeltype = 'a') > 0,
    '12 NO ACTION children of schools exist — the refusal above is structural');
end $plain$;

-- ---------------------------------------------------------------------------
-- Manufacture the real thing: delete the school with referential integrity
-- stood down, exactly as a restore, a PITR or `set session_replication_role`
-- does. This is the only way to reach the state, which is the finding.
-- ---------------------------------------------------------------------------
do $orphan$
declare d uuid := (select v from _orph where k = 'dead');
begin
  set session_replication_role = 'replica';
  delete from public.schools where id = d;
  set session_replication_role = 'origin';
end $orphan$;

-- ---------------------------------------------------------------------------
-- 20-24 — the false clean, executed
-- ---------------------------------------------------------------------------
do $stale$
declare d uuid := (select v from _orph where k = 'dead'); v_before bigint; v_after bigint;
begin
  perform pg_temp.ok((select count(*) from public.schools where id = d) = 0,
    '20 the school row is gone');

  perform pg_temp.ok(
    (select count(*) from public.subscriptions where school_id = d) = 1,
    '21 its subscription survived — the ON DELETE CASCADE never ran');

  perform pg_temp.ok(
    (select c.convalidated from pg_constraint c
      where c.conname = 'subscriptions_school_id_fkey'),
    '22 and the foreign key STILL reports itself validated, over a real orphan');

  select count(*) into v_before from public.subscriptions s
   where not exists (select 1 from public.schools sc where sc.id = s.school_id);
  alter table public.subscriptions validate constraint subscriptions_school_id_fkey;
  select count(*) into v_after from public.subscriptions s
   where not exists (select 1 from public.schools sc where sc.id = s.school_id);
  perform pg_temp.ok(v_before = 1 and v_after = 1,
    '23 VALIDATE CONSTRAINT succeeds and re-scans nothing — it cannot find this');

  perform pg_temp.ok(
    (select coalesce(sum(h.orphan_rows), 0) from public.fn__referential_health() h) > 0,
    '24 counting the rows is the only reading that is true — health check sees it');

  -- 25-26 — the fault that made all of this undeletable.
  --
  -- audit_trigger writes an audit_log row keyed to the school of the row being
  -- written, and audit_log.school_id is NOT NULL with a NO ACTION key to
  -- schools. With the school gone that insert is refused and it takes the
  -- caller's statement down with it, on all seventeen audited tables. The data
  -- was not orphaned, it was welded in place — and the error named audit_log,
  -- which explains nothing to whoever is reading it.
  perform pg_temp.ok(
    position('not exists (select 1 from public.schools s where s.id = v_school)'
             in pg_get_functiondef('public.audit_trigger()'::regprocedure)) > 0,
    '25 audit_trigger skips a school that is not there instead of refusing the write');

  -- A DELETE, not an UPDATE: enforce_school_id() is a BEFORE INSERT OR UPDATE
  -- trigger and refuses a row whose school_id is not the caller's, so an update
  -- here would fail for an unrelated reason and prove nothing about the audit
  -- trigger. Deleting is also what the cleanup actually does. The row goes for
  -- good, which is fine — assertion 51 requires every one of them gone anyway.
  perform pg_temp.ok(
    not pg_temp.refused(format(
      'delete from public.expense_categories where id = (select id from '
      'public.expense_categories where school_id = %L limit 1)', d)),
    '26 so an audited table belonging to the missing school can be written again');
end $stale$;

-- ---------------------------------------------------------------------------
-- 30-34 — the report
-- ---------------------------------------------------------------------------
do $report$
declare d uuid := (select v from _orph where k = 'dead');
        l uuid := (select v from _orph where k = 'live');
begin
  perform set_config('test.uid', (select v::text from _orph where k = 'ops'), false);

  perform pg_temp.ok(
    (select count(*) from public.fn_platform_orphan_report() where school_id = d) > 1,
    '30 the report names more than one table — the orphan is never just one row');

  perform pg_temp.ok(
    (select count(*) from public.fn_platform_orphan_report() where school_id = l) = 0,
    '31 and says nothing about the school that still exists');

  perform pg_temp.ok(
    exists (select 1 from public.fn_platform_orphan_report()
             where school_id = d and table_name = 'subscriptions' and treatment = 'delete'),
    '32 tenant records are marked for deletion');

  perform pg_temp.ok(
    exists (select 1 from public.fn_platform_orphan_report()
             where school_id = d and table_name = 'platform_invoices' and treatment = 'unlink'),
    '33 our own invoice is marked to be UNLINKED, never deleted');

  perform set_config('test.uid', '', false);
  perform pg_temp.ok(pg_temp.refused('select * from public.fn_platform_orphan_report()'),
    '34 and nobody but the operator can read it');
end $report$;

-- ---------------------------------------------------------------------------
-- 40-43 — the refusals in front of the cleanup
-- ---------------------------------------------------------------------------
do $refuse$
declare d uuid := (select v from _orph where k = 'dead');
        l uuid := (select v from _orph where k = 'live');
begin
  perform set_config('test.uid', '', false);
  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_purge_orphan_data(%L, %L)', d, d::text)),
    '40 a signed-out caller cannot clear anything');

  perform set_config('test.uid', (select v::text from _orph where k = 'ops'), false);

  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_purge_orphan_data(%L, %L)', d, 'not-the-id')),
    '41 the id has to be typed correctly');

  perform pg_temp.ok(pg_temp.refused(format(
    'select public.fn_platform_purge_orphan_data(%L, %L)', l, l::text)),
    '42 a school that still EXISTS is refused — this is not a way round the purge');

  perform pg_temp.ok(
    (select count(*) from public.schools where id = l) = 1
    and (select count(*) from public.subscriptions where school_id = l) = 1,
    '43 and that refusal left it completely alone');
end $refuse$;

-- ---------------------------------------------------------------------------
-- 44 — it refuses to run while foreign keys are switched off
--
-- The cleanup deletes across a dependency graph. Doing that with enforcement
-- down would skip the same checks that produced the mess and could leave a
-- second generation of orphans inside the tables being cleaned.
-- ---------------------------------------------------------------------------
do $replica$
declare d uuid := (select v from _orph where k = 'dead'); v_refused boolean;
begin
  set session_replication_role = 'replica';
  v_refused := pg_temp.refused(format(
    'select public.fn_platform_purge_orphan_data(%L, %L)', d, d::text));
  set session_replication_role = 'origin';
  perform pg_temp.ok(v_refused,
    '44 the cleanup refuses to run while referential integrity is stood down');
end $replica$;

-- ---------------------------------------------------------------------------
-- 50-57 — the cleanup itself
-- ---------------------------------------------------------------------------
do $purge$
declare
  d uuid := (select v from _orph where k = 'dead');
  l uuid := (select v from _orph where k = 'live');
  res jsonb; r record; v_left text; v_n bigint; v_live_before bigint; v_live_after bigint;
begin
  perform set_config('test.uid', (select v::text from _orph where k = 'ops'), false);

  select count(*) into v_live_before from public.subscriptions where school_id = l;

  res := public.fn_platform_purge_orphan_data(d, d::text);

  perform pg_temp.ok((res->>'purged')::boolean and (res->>'rows_deleted')::bigint > 0,
    '50 the cleanup reports what it removed');

  -- Every table in the catalogue, not a list somebody maintained. A list is how
  -- detect.sql's exemption list drifted and reported MISSING on a correct
  -- database for two rounds.
  for r in select t.table_name from public.fn__school_id_tables() t loop
    execute format('select count(*) from public.%I where school_id = $1', r.table_name)
      into v_n using d;
    if v_n > 0 then
      v_left := coalesce(v_left || ', ', '') || r.table_name || ' (' || v_n::text || ')';
    end if;
  end loop;
  perform pg_temp.ok(v_left is null,
    '51 and nothing anywhere in public still points at that id: ' || coalesce(v_left, 'clean'));

  perform pg_temp.ok(
    (select coalesce(sum(h.orphan_rows), 0) from public.fn__referential_health() h) = 0,
    '52 the health check now agrees');

  -- The ledger. This is the assertion that separates a cleanup from a delete.
  perform pg_temp.ok(
    (select count(*) from public.platform_invoices
      where school_name = 'Left Behind School' and school_id is null) = 1,
    '53 our invoice survived, unlinked — a business keeps its sales ledger');

  perform pg_temp.ok(
    (select count(*) from public.operator_actions where action = 'orphan_data_purged'
       and detail->>'school_id' = d::text) = 1,
    '54 and the clearing is on record, with what was found before it ran');

  perform pg_temp.ok(
    (select (detail->'by_table') ? 'subscriptions' from public.operator_actions
      where action = 'orphan_data_purged' and detail->>'school_id' = d::text),
    '55 the record lists the tables, so it can be read years later');

  -- An unlinked audit row with the id stripped and nothing put in its place is
  -- a record of something having been done to somebody, which is not a record.
  -- 0080 stamps the school NAME before unlinking; here there is no name left, so
  -- the id is what goes in.
  perform pg_temp.ok(
    not exists (select 1 from public.operator_actions where school_id = d)
    and exists (select 1 from public.operator_actions
                 where detail->>'orphaned_school_id' = d::text),
    '55b the operator history was unlinked, and still says which school it was');

  select count(*) into v_live_after from public.subscriptions where school_id = l;
  perform pg_temp.ok(v_live_before = 1 and v_live_after = 1
    and (select count(*) from public.schools where id = l) = 1,
    '56 the other school is exactly as it was');

  res := public.fn_platform_purge_orphan_data(d, d::text);
  perform pg_temp.ok(not (res->>'purged')::boolean and res ? 'why',
    '57 running it again finds nothing and says so, rather than pretending to work');
end $purge$;

-- ---------------------------------------------------------------------------
-- 60-62 — grants
-- ---------------------------------------------------------------------------
do $grants$
begin
  perform pg_temp.ok(
    not has_function_privilege('authenticated', 'public.fn__school_id_tables()', 'execute')
    and not has_function_privilege('anon', 'public.fn__school_id_tables()', 'execute'),
    '60 the internal table list is not callable from a browser');

  perform pg_temp.ok(
    not has_function_privilege('authenticated', 'public.fn__referential_health()', 'execute'),
    '61 nor is the health check');

  perform pg_temp.ok(
    has_function_privilege('authenticated',
      'public.fn_platform_purge_orphan_data(uuid, text)', 'execute')
    and not has_function_privilege('anon',
      'public.fn_platform_purge_orphan_data(uuid, text)', 'execute'),
    '62 the cleanup is reachable by a signed-in operator and not by anon');
end $grants$;

rollback;
