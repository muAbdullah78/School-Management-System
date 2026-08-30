-- =============================================================================
-- Can one bad row stop the student counter — and take a bundle with it?
--
-- THE DEFECT THIS FILE EXISTS FOR. 0067 ended with
--
--     for v_school in select school_id from public.subscriptions loop
--       perform public.fn_refresh_student_count(v_school);
--     end loop;
--
-- which reads `subscriptions` and writes a row keyed to `schools`. On a live
-- project one subscription named a school that was not there, so the snapshot
-- insert violated its foreign key and the whole of bundle 6 rolled back:
-- photographs, exam computation, the observer role, deposits, certificates,
-- staff check-in and operator billing, all discarded to recount a number.
--
-- The rules defended here:
--
--   1. The recount SKIPS a school that is not in `schools` instead of raising.
--   2. One school that cannot be recounted does not stop the others.
--   3. The trigger path carries the same guard, so a clerk's admission can
--      never fail with a foreign-key error from a counter.
--   4. The counter still does its actual job: admitting a pupil moves the
--      number the operator console and the licence banner read.
--   5. A bulk import refreshes ONCE, not once per pupil.
--   6. The foreign key that makes rule 1 unnecessary is present, so the orphan
--      cannot be created in the first place.
--   7. No internal fn__ helper is callable by a signed-in user.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/counter_repair.sql
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

create or replace function pg_temp.raises(p_sql text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 64);
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

-- --- Fixture -----------------------------------------------------------------
-- Two real schools, so "one school's problem must not touch the other" is a
-- statement about two actual tenants rather than about one.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_owner uuid := '00000000-0000-0000-0000-0000000cc0a1';
  v_sess uuid; v_class uuid; v_sec uuid;
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Counter School A') returning id into v_a;
  insert into public.schools (name) values ('Counter School B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'starter', 'active', current_date + 30),
           (v_b, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'o@counter.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Counter Owner', 'owner', v_a)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_a) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_a) returning id into v_sec;

  create table public._cr (k text primary key, v uuid);
  insert into public._cr values ('a', v_a), ('b', v_b), ('sess', v_sess),
                                ('class', v_class), ('sec', v_sec);
  raise notice 'fixture: two schools, both subscribed, no pupils yet';
end $seed$;

-- =============================================================================
-- 1. The machinery is installed
-- =============================================================================
select pg_temp.ok(
  (select count(*) from pg_trigger t
     join pg_proc p on p.oid = t.tgfoid
    where not t.tgisinternal
      and p.pronamespace = 'public'::regnamespace
      and p.proname = 'fn__refresh_counts_touched'
      and t.tgrelid in ('public.students'::regclass, 'public.enrollments'::regclass)) = 6,
  '1. all six student-count triggers exist — three verbs on each of the two '
  || 'tables the count is computed from');

select pg_temp.ok(
  exists (select 1 from pg_proc where proname = 'fn__refresh_counts_touched'
           and pronamespace = 'public'::regnamespace
           and prosrc like '%join public.schools sc%'),
  '2. and the trigger function joins `schools`, so it can never ask for a count '
  || 'against a school that is not there');

-- =============================================================================
-- 2. The counter does its actual job
-- =============================================================================
do $live$
declare v_stu uuid; v_before int; v_after int;
begin
  select student_count into v_before from public.subscriptions
   where school_id = (select v from public._cr where k = 'a');

  insert into public.students (full_name, status, school_id)
    values ('Counted Child', 'active', (select v from public._cr where k = 'a'))
    returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id,
                                  status, school_id)
    values (v_stu, (select v from public._cr where k = 'sess'),
            (select v from public._cr where k = 'class'),
            (select v from public._cr where k = 'sec'), 'active',
            (select v from public._cr where k = 'a'));

  select student_count into v_after from public.subscriptions
   where school_id = (select v from public._cr where k = 'a');

  if v_after <> 1 then
    raise exception
      'FAIL  3. admitting a pupil left the count at % — the console and the '
      'licence banner would both show a school outgrowing its plan as empty',
      v_after;
  end if;
  raise notice 'PASS  3. admitting a pupil moves the count live (% -> %), which is '
    'the whole feature — before 0067 it was whatever it had been when somebody '
    'last pressed Refresh', v_before, v_after;
end $live$;

do $bulk$
declare v_sess uuid := (select v from public._cr where k = 'sess');
        v_a uuid := (select v from public._cr where k = 'a');
        i int; v_stu uuid; v_snaps int;
begin
  -- One statement, forty pupils. A row-level trigger would recount forty times,
  -- each taking a lock on the same subscriptions row.
  insert into public.students (full_name, status, school_id)
  select 'Bulk Child ' || g, 'active', v_a from generate_series(1, 40) g;

  select count(*) into v_snaps from public.student_count_snapshots
   where school_id = v_a and counted_on = current_date;
  if v_snaps <> 1 then
    raise exception 'FAIL  4. a 40-row insert produced % snapshot rows', v_snaps;
  end if;
  raise notice 'PASS  4. a forty-pupil import refreshes ONCE — statement-level, '
    'so an import does not serialise against itself';
end $bulk$;

select pg_temp.ok(
  (select student_count from public.subscriptions
    where school_id = (select v from public._cr where k = 'b')) = 0,
  '5. and school B''s count is untouched — the trigger scopes to the schools the '
  || 'statement actually touched');

-- =============================================================================
-- 3. THE ONE THIS FILE EXISTS FOR: a school that is not there
--
-- The foreign key normally makes this impossible, which is why the test has to
-- drop it to build the state — inside a transaction that rolls back. That is
-- the state the live project was in, and the state the shipped 0067 could not
-- survive.
-- =============================================================================
alter table public.subscriptions drop constraint subscriptions_school_id_fkey;
insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values ('a0bf0f0c-56b0-4e83-af44-96869c07f542', 'starter', 'active', current_date + 30);

select pg_temp.raises(
  $$select public.fn_refresh_student_count('a0bf0f0c-56b0-4e83-af44-96869c07f542')$$,
  '6. asking for the orphan''s count directly still fails, and should — the '
  || 'snapshot row it would write has nowhere to point');

-- The loop 0090 ships, run against exactly the database that broke bundle 6.
--
-- The assertion names THIS FIXTURE'S two schools rather than counting rows.
-- Its first version required the total to be exactly 2, which passed against a
-- fresh database and failed in CI, where every suite runs in sequence against
-- one database and an earlier fixture had left a third school behind. A test
-- that asserts a global count is a test that depends on every other test —
-- and it fails for a reason that has nothing to do with what it is checking.
do $loop$
declare
  v_school uuid;
  v_done   uuid[] := '{}';
  v_fail   int := 0;
  v_a uuid := (select v from public._cr where k = 'a');
  v_b uuid := (select v from public._cr where k = 'b');
begin
  for v_school in
    select sub.school_id
      from public.subscriptions sub
      join public.schools sc on sc.id = sub.school_id
     order by sub.school_id
  loop
    begin
      perform public.fn_refresh_student_count(v_school);
      v_done := v_done || v_school;
    exception when others then
      v_fail := v_fail + 1;
    end;
  end loop;

  if v_fail > 0 then
    raise exception
      'FAIL  7. % school(s) could not be recounted. With the fix in place the '
      'orphan is never reached, so nothing should fail at all.', v_fail;
  end if;
  if not (v_a = any(v_done)) or not (v_b = any(v_done)) then
    raise exception
      'FAIL  7. the recount skipped one of this fixture''s schools (A in list: %, '
      'B in list: %)', v_a = any(v_done), v_b = any(v_done);
  end if;
  raise notice 'PASS  7. THE ONE THAT MATTERS: with an orphan present the recount '
    'reaches every real school and fails on none. The shipped loop raised here '
    'and discarded eleven migrations.';
end $loop$;

-- And the trigger path, which is what a clerk touches.
do $trigger$
declare v_stu uuid;
begin
  insert into public.students (full_name, status, school_id)
    values ('Admitted While Broken', 'active', (select v from public._cr where k = 'a'))
    returning id into v_stu;
  if v_stu is null then
    raise exception 'FAIL  8. the admission did not happen';
  end if;
  raise notice 'PASS  8. and a clerk can still admit a pupil while the orphan '
    'exists — a counter must never be able to refuse an admission';
end $trigger$;

rollback;

-- =============================================================================
-- 4. Back on the real database: the constraint that makes all of the above
--    unnecessary, and the helper grants
-- =============================================================================
begin;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

select pg_temp.ok(
  exists (select 1 from pg_constraint c
          join pg_class t on t.oid = c.conrelid
          join pg_namespace n on n.oid = t.relnamespace
          where n.nspname = 'public' and t.relname = 'subscriptions'
            and c.contype = 'f'
            and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%'),
  '9. subscriptions references schools, so the orphan cannot be created at all. '
  || 'Checked by what the constraint DOES, not by its name — one named '
  || 'subscriptions_school_id_fkey pointing elsewhere would pass a name check '
  || 'and give none of the guarantee');

select pg_temp.ok(
  not exists (select 1 from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname like 'fn\_\_%'
                and has_function_privilege('authenticated', p.oid, 'execute')),
  '10. and no internal fn__ helper is callable by a signed-in user. Postgres '
  || 'grants EXECUTE to PUBLIC on every function it creates, so this is one '
  || 'forgotten revoke away from being false');

-- =============================================================================
-- 5. NOT VALID — the state that made the diagnostic contradict itself
--
-- The live project reported an orphan AND "the foreign key is there" in the same
-- output. Both were accurate readings and one of them was meaningless: a NOT
-- VALID foreign key exists, satisfies a definition test, refuses every new
-- orphan, and has never looked at the rows already present.
--
-- Checking a constraint by what it REFERENCES rather than by its name was the
-- right instinct one step short. What it does is `REFERENCES schools(id)` AND
-- `convalidated`.
-- =============================================================================
select pg_temp.ok(
  (select bool_and(c.convalidated)
     from pg_constraint c
     join pg_class t on t.oid = c.conrelid
     join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public' and t.relname = 'subscriptions' and c.contype = 'f'
      and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%'),
  '11. and it is VALIDATED, not merely declared — so it has been checked against '
  || 'every row already in the table, and "the constraint exists" and "an orphan '
  || 'exists" can no longer both be true');

do $notvalid$
declare v_orphans bigint; v_valid boolean;
begin
  -- Build the exact live state inside the transaction: drop the constraint, add
  -- the orphan, put the constraint back NOT VALID.
  alter table public.subscriptions drop constraint subscriptions_school_id_fkey;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values ('a0bf0f0c-56b0-4e83-af44-96869c07f542', 'starter', 'active', current_date + 30);
  alter table public.subscriptions add constraint subscriptions_school_id_fkey
    foreign key (school_id) references public.schools(id) on delete cascade not valid;

  select count(*) into v_orphans
  from public.subscriptions s
  where s.school_id is not null
    and not exists (select 1 from public.schools sc where sc.id = s.school_id);
  select bool_and(c.convalidated) into v_valid
    from pg_constraint c join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and t.relname = 'subscriptions' and c.contype = 'f'
     and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%';

  if v_orphans <> 1 or v_valid then
    raise exception 'FAIL  12. could not build the NOT VALID state (orphans %, valid %)',
      v_orphans, v_valid;
  end if;
  raise notice 'PASS  12. a NOT VALID constraint holds an orphan and a foreign key '
    'at the same time — the state the definition test could not see';
end $notvalid$;

do $stillrefuses$
begin
  begin
    insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
      values ('c0bf0f0c-56b0-4e83-af44-96869c07f542', 'starter', 'active', current_date + 30);
  exception when foreign_key_violation then
    raise notice 'PASS  13. and it still refuses a NEW orphan, which is why nothing '
      'ever noticed: it is doing most of its job';
    return;
  end;
  raise exception 'FAIL  13. a NOT VALID constraint let a new orphan in';
end $stillrefuses$;

do $validate$
declare v_valid boolean;
begin
  -- 0091 refuses to validate while the orphan is there, correctly. Remove it and
  -- the validation is what closes the state for good.
  delete from public.subscriptions
   where school_id = 'a0bf0f0c-56b0-4e83-af44-96869c07f542';
  alter table public.subscriptions validate constraint subscriptions_school_id_fkey;

  select bool_and(c.convalidated) into v_valid
    from pg_constraint c join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and t.relname = 'subscriptions' and c.contype = 'f'
     and pg_get_constraintdef(c.oid) ilike '%references%schools(id)%';
  if not v_valid then
    raise exception 'FAIL  14. the constraint is still not validated';
  end if;
  raise notice 'PASS  14. once the orphan is gone the constraint validates, and '
    'from then on the two answers cannot disagree';
end $validate$;

rollback;
