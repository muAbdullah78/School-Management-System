-- =============================================================================
-- Does a school outgrowing its plan ever get noticed?
--
-- subscriptions.student_count is a STORED number, and it drives every signal the
-- operator prices a school by: the console's "N students / limit", limit_state,
-- over_limit_flagged_at, suggested_plan, needs_upgrade — and the licence banner
-- the SCHOOL itself sees.
--
-- Before 0067 it was refreshed from exactly two places: fn_activate_subscription
-- and a manual "Refresh counts" button. No trigger on students, none on
-- enrollments. Proven on a real database with 400 pupils enrolled on Starter:
--
--   actually_enrolled | console_shows | plan_allows | flagged_over_limit
--   ------------------+---------------+-------------+--------------------
--                 400 |             0 |         100 | f
--
-- and the school's own banner also read 0 of 100, so neither side ever learned.
-- Rs 25,500 a year of invisible revenue per school, on the Starter-vs-Institution
-- gap alone.
--
-- The rules this file defends:
--
--   1. THE COUNT MOVES WHEN THE ROLL MOVES, on all six paths — insert, update
--      and delete, on both students and enrollments. fn_count_students joins
--      both tables, so a pupil marked withdrawn changes the count even though
--      their enrolment row was never touched.
--   2. ONE REFRESH PER STATEMENT, not per row. A 400-pupil import must not
--      recount the school 400 times, each taking the same row lock on
--      subscriptions and serialising the import against itself.
--   3. THE OVER-LIMIT FLAG IS RAISED, because the count alone tells nobody to act.
--   4. AN IMPORT MUST NEVER FAIL BECAUSE OF A COUNTER. A school row can exist
--      before its subscription does.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/student_count.sql
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

create or replace function pg_temp.stored() returns integer language sql as $$
  select student_count from public.subscriptions
   where school_id = (select id from public.schools where name = 'Count School');
$$;

create or replace function pg_temp.real_count() returns integer language sql as $$
  select public.fn_count_students((select id from public.schools where name = 'Count School'));
$$;

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare v_s uuid; v_o uuid := '00000000-0000-0000-0000-00000000cc01';
        v_sess uuid; v_cl uuid;
begin
  insert into public.schools (name) values ('Count School') returning id into v_s;
  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, student_count)
    values (v_s, 'starter', 'active', 'yearly',
            current_date - 30, current_date + 335, 0);
  insert into auth.users (id, email, raw_app_meta_data)
    values (v_o, 'owner@count.test', jsonb_build_object('school_id', v_s::text));
  -- The operator, for the console assertion. fn_platform_schools() gates on
  -- is_platform_admin(), so checking it as the school's owner raises
  -- 'Not permitted' — which is the boundary working, not a test failure.
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-00000000cc99', 'operator@count.test');
  insert into public.platform_admins (user_id, note)
    values ('00000000-0000-0000-0000-00000000cc99', 'Count test operator');
  perform set_config('test.uid', v_o::text, false);

  insert into public.academic_sessions (school_id, name, is_current, starts_on, ends_on)
    values (v_s, '2026-27', true, current_date - 60, current_date + 300) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_s;
  insert into public.classes (school_id, name, level_order)
    values (v_s, 'Class 1', 1) returning id into v_cl;
end;
$seed$;

-- Every OTHER school this suite needs, created here rather than where it is
-- used. Creating a school while signed in as another school's owner trips the
-- cross-tenant provisioning guard — fn_provision_school seeds expense_categories
-- and enforce_school_id refuses: "row addressed to school X, caller belongs to
-- Y". Schools first, logins second; the same ordering the certificates and
-- operator-billing suites needed.
do $others$
declare v_nosub uuid; v_b uuid; v_sess uuid; v_cl uuid;
begin
  perform set_config('test.uid', null, false);

  -- Deliberately WITHOUT a subscription row.
  insert into public.schools (name) values ('No Sub School') returning id into v_nosub;

  insert into public.schools (name) values ('Other Count School') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on, student_count)
    values (v_b, 'starter', 'trialing', current_date + 14, 0);
  insert into public.academic_sessions (school_id, name, is_current, starts_on, ends_on)
    values (v_b, '2026-27', true, current_date - 60, current_date + 300) returning id into v_sess;
  insert into public.classes (school_id, name, level_order)
    values (v_b, 'Class 1', 1) returning id into v_cl;

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000cc01', false);
end;
$others$;

-- =============================================================================
-- 1. Rule 2 — statement-level, asserted structurally
--
-- The outcome tests below would pass with row-level triggers too, so the
-- performance decision needs its own assertion. pg_trigger.tgtype bit 0 is the
-- ROW flag; statement-level triggers have it clear.
-- =============================================================================
select pg_temp.ok(
  (select count(*) from pg_trigger
    where not tgisinternal
      and tgrelid in ('public.students'::regclass, 'public.enrollments'::regclass)
      and tgfoid = 'public.fn__refresh_counts_touched'::regproc) = 6,
  '1. six triggers exist — insert, update and delete on both students and '
  || 'enrollments. A subset leaves the count stale through whichever verb is '
  || 'missing, which is the same defect in a narrower window');

select pg_temp.ok(
  not exists (select 1 from pg_trigger
               where not tgisinternal
                 and tgfoid = 'public.fn__refresh_counts_touched'::regproc
                 and (tgtype & 1) = 1),
  '2. and every one is FOR EACH STATEMENT, not FOR EACH ROW — row-level would '
  || 'recount the whole school once per pupil and serialise a 400-row import '
  || 'against its own lock on the subscriptions row');

-- =============================================================================
-- 2. Rule 1 — the count moves on every path
-- =============================================================================
-- (a) enrolling pupils, in ONE statement
do $enrol$
declare v_s uuid := (select id from public.schools where name = 'Count School');
        v_sess uuid := (select id from public.academic_sessions where school_id = v_s);
        v_cl uuid := (select id from public.classes where school_id = v_s);
begin
  with ins as (
    insert into public.students (school_id, full_name, father_name, status)
    select v_s, 'Child ' || g, 'Father ' || g, 'active' from generate_series(1, 120) g
    returning id, full_name
  )
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
  select v_s, ins.id, v_sess, v_cl, ins.full_name, 'active' from ins;
end;
$enrol$;

select pg_temp.ok(
  pg_temp.stored() = 120 and pg_temp.real_count() = 120,
  '3. enrolling 120 children in one statement updates the stored count to 120 — '
  || 'it stayed at 0 before, until somebody clicked a button in the operator '
  || 'console');

-- (b) a pupil marked withdrawn — students changes, enrollments does not
update public.students set status = 'withdrawn', left_on = current_date
 where school_id = (select id from public.schools where name = 'Count School')
   and full_name = 'Child 1';

select pg_temp.ok(
  pg_temp.stored() = 119,
  '4. marking ONE pupil withdrawn drops it to 119 — fn_count_students joins '
  || 'students as well as enrollments, so a trigger on enrollments alone would '
  || 'have missed this entirely');

-- (c) an enrolment closed — enrollments changes, students does not
update public.enrollments set status = 'left'
 where school_id = (select id from public.schools where name = 'Count School')
   and roll_no = 'Child 2';

select pg_temp.ok(
  pg_temp.stored() = 118,
  '5. closing ONE enrolment drops it to 118');

-- (d) deletes
delete from public.enrollments
 where school_id = (select id from public.schools where name = 'Count School')
   and roll_no in ('Child 3', 'Child 4');

select pg_temp.ok(
  pg_temp.stored() = 116,
  '6. deleting two enrolments drops it to 116 — the DELETE path needs the OLD '
  || 'transition table, which Postgres refuses to declare on an INSERT trigger, '
  || 'so this verb is easy to leave out');

-- (e) and back up again
update public.students set status = 'active', left_on = null
 where school_id = (select id from public.schools where name = 'Count School')
   and full_name = 'Child 1';

select pg_temp.ok(
  pg_temp.stored() = 117,
  '7. re-activating a pupil puts the count back up — the trigger recounts, it '
  || 'does not increment, so it cannot drift');

select pg_temp.ok(
  pg_temp.stored() = pg_temp.real_count(),
  '8. and the stored number equals a fresh count at every point above. That '
  || 'equality is the whole property; everything else is a way of breaking it');

-- =============================================================================
-- 3. Rule 3 — the flag, not just the number
-- =============================================================================
select pg_temp.ok(
  (select over_limit_flagged_at is not null from public.subscriptions
    where school_id = (select id from public.schools where name = 'Count School')),
  '9. 117 pupils against Starter''s 100 raises over_limit_flagged_at — the count '
  || 'alone tells nobody to act, and this is the field the console reads to say '
  || '"over limit"');

-- As the OPERATOR, because that is who reads this screen.
select set_config('test.uid', '00000000-0000-0000-0000-00000000cc99', false);
select pg_temp.ok(
  (select student_count = 117 and limit_state = 'over' and suggested_plan = 'growth'
     from public.fn_platform_schools()
    where school_name = 'Count School'),
  '10. and the operator console now shows the real figure, the over-limit state '
  || 'and the plan that fits — it showed 0 students for a school with pupils, '
  || 'which is what made this visible at all');
select set_config('test.uid', '00000000-0000-0000-0000-00000000cc01', false);

-- =============================================================================
-- 4. Rule 4 — a counter must never break an import
-- =============================================================================
do $nosub$
declare v_s uuid := (select id from public.schools where name = 'No Sub School');
        v_ok boolean := true;
begin
  -- A school with no subscription row yet. The signup Edge Function creates the
  -- school first and the subscription second, so this window is real.
  perform set_config('test.uid', null, false);
  begin
    insert into public.students (school_id, full_name, father_name, status)
    values (v_s, 'Early Bird', 'Father', 'active');
  exception when others then
    v_ok := false;
    raise notice '  (raised: %)', sqlerrm;
  end;
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000cc01', false);
  perform pg_temp.ok(v_ok,
    '11. a pupil can be created for a school that has no subscription row yet — '
    || 'fn_refresh_student_count raises "No subscription for school %" and an '
    || 'admission must never fail because of a counter');
end;
$nosub$;

-- =============================================================================
-- 5. Cross-school: one school's roll must not move another's count
-- =============================================================================
do $other$
declare v_b uuid := (select id from public.schools where name = 'Other Count School');
        v_sess uuid := (select id from public.academic_sessions where school_id = v_b);
        v_cl uuid := (select id from public.classes where school_id = v_b);
begin
  perform set_config('test.uid', null, false);
  with ins as (
    insert into public.students (school_id, full_name, father_name, status)
    select v_b, 'B Child ' || g, 'F', 'active' from generate_series(1, 7) g
    returning id, full_name)
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
  select v_b, ins.id, v_sess, v_cl, ins.full_name, 'active' from ins;
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000cc01', false);
end;
$other$;

select pg_temp.ok(
  pg_temp.stored() = 117,
  '12. enrolling seven children at another school leaves this one at 117 — the '
  || 'trigger scopes by the school_id on the rows it touched, and a statement '
  || 'trigger with no transition table could not have');

select pg_temp.ok(
  (select student_count from public.subscriptions
    where school_id = (select id from public.schools where name = 'Other Count School')) = 7,
  '13. while the other school is counted correctly in the same breath');

-- A single statement touching BOTH schools must refresh both.
do $both$
declare v_a uuid := (select id from public.schools where name = 'Count School');
        v_b uuid := (select id from public.schools where name = 'Other Count School');
begin
  perform set_config('test.uid', null, false);
  update public.students set status = 'withdrawn', left_on = current_date
   where (school_id = v_a and full_name = 'Child 5')
      or (school_id = v_b and full_name = 'B Child 1');
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000cc01', false);
end;
$both$;

select pg_temp.ok(
  pg_temp.stored() = 116
  and (select student_count from public.subscriptions
        where school_id = (select id from public.schools where name = 'Other Count School')) = 6,
  '14. one statement withdrawing a pupil from EACH school refreshes both — the '
  || 'function loops over every distinct school in the transition table, so a '
  || 'bulk operation spanning tenants cannot leave one behind');

do $$ begin raise notice 'ALL STUDENT COUNT TESTS PASSED'; end $$;

rollback;
