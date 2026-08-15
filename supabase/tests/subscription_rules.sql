-- =============================================================================
-- Subscription, trial, grace, lock and student-limit rules.
--
-- The rule this file exists to defend: going over the student limit must NEVER
-- block anything. It is easy to "tighten" that later by adding a check on
-- student insert; this test fails loudly if anyone does.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/subscription_rules.sql
-- =============================================================================

\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- Fixture: one school, one owner, one class, one current session ---------
do $seed$
declare
  v_school uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000c1';
  v_sess uuid; v_class uuid;
begin
  delete from public.schools where name = 'Limit Test School';

  insert into public.schools (name) values ('Limit Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'trialing', current_date + 14);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'c1@limit.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Limit Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school) returning id into v_class;

  create table if not exists public._sub_ids (k text primary key, v uuid);
  delete from public._sub_ids;
  insert into public._sub_ids values
    ('school', v_school), ('owner', v_owner), ('sess', v_sess), ('class', v_class);
end $seed$;

-- --- Plan maths --------------------------------------------------------------
do $$
begin
  if public.plan_margin_limit(200)  <> 220  then raise exception 'FAIL: 200 margin'; end if;
  if public.plan_margin_limit(500)  <> 550  then raise exception 'FAIL: 500 margin'; end if;
  if public.plan_margin_limit(1500) <> 1650 then raise exception 'FAIL: 1500 margin'; end if;
  if public.plan_margin_limit(null) is not null then raise exception 'FAIL: custom margin'; end if;
  raise notice 'ok: plan margins are limit + 10%%';
end $$;

-- --- Counting ---------------------------------------------------------------
-- Only active enrolments of active, non-deleted students in the CURRENT session.
do $$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  v_sess   uuid := (select v from public._sub_ids where k='sess');
  v_class  uuid := (select v from public._sub_ids where k='class');
  v_stu    uuid;
  n integer;
begin
  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);

  for i in 1..10 loop
    insert into public.students (gr_no, full_name, school_id)
      values ('S' || i, 'Student ' || i, v_school) returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, school_id)
      values (v_stu, v_sess, v_class, v_school);
  end loop;

  n := public.fn_count_students(v_school);
  if n <> 10 then raise exception 'FAIL: expected 10 counted, got %', n; end if;

  -- A struck-off student stops counting.
  update public.students set status = 'struck_off'
   where id = (select id from public.students where gr_no = 'S1' and school_id = v_school);
  n := public.fn_count_students(v_school);
  if n <> 9 then raise exception 'FAIL: struck-off student still counted (%)', n; end if;

  -- A soft-deleted student stops counting.
  update public.students set deleted_at = now()
   where id = (select id from public.students where gr_no = 'S2' and school_id = v_school);
  n := public.fn_count_students(v_school);
  if n <> 8 then raise exception 'FAIL: deleted student still counted (%)', n; end if;

  raise notice 'ok: student count follows active enrolments only';
end $$;

-- =============================================================================
-- THE RULE: exceeding the plan limit must never block anything.
-- =============================================================================
do $limits$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  v_sess   uuid := (select v from public._sub_ids where k='sess');
  v_class  uuid := (select v from public._sub_ids where k='class');
  v_stu    uuid;
  lic jsonb;
begin
  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);

  -- Push well past the 200 limit AND past the 220 margin. Every one of these
  -- inserts must succeed: this is the admissions desk, and it never closes.
  for i in 100..340 loop
    insert into public.students (gr_no, full_name, school_id)
      values ('B' || i, 'Bulk ' || i, v_school) returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, school_id)
      values (v_stu, v_sess, v_class, v_school);
  end loop;

  perform public.fn_refresh_student_count(v_school);

  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;

  if (lic->>'student_count')::int <= 220 then
    raise exception 'FAIL: fixture did not exceed the margin (count=%)', lic->>'student_count';
  end if;
  if lic->>'limit_state' <> 'over' then
    raise exception 'FAIL: expected limit_state=over, got %', lic->>'limit_state';
  end if;
  -- Over the limit, but still fully operational. This is the whole point.
  if (lic->>'can_operate')::boolean is not true then
    raise exception 'FAIL: an over-limit school was stopped from operating';
  end if;
  if (lic->>'locked')::boolean is true then
    raise exception 'FAIL: an over-limit school was locked';
  end if;
  if lic->>'limit_notice' is null then
    raise exception 'FAIL: no notice shown to the owner';
  end if;

  -- And one more admission still goes through while over the limit.
  insert into public.students (gr_no, full_name, school_id)
    values ('AFTER-LIMIT', 'Admitted anyway', v_school) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, school_id)
    values (v_stu, v_sess, v_class, v_school);

  -- The platform is told, so the owner gets a phone call rather than a locked door.
  if (select over_limit_flagged_at from public.subscriptions where school_id = v_school) is null then
    raise exception 'FAIL: over-limit school was not flagged to the platform';
  end if;

  raise notice 'ok: over the limit never blocks — school flagged, not stopped';
end $limits$;

-- Within the margin: no flag, no notice of trouble.
do $$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  lic jsonb;
begin
  -- Trim back to 210 active: over 200, inside the 220 margin.
  update public.students set deleted_at = now()
   where school_id = v_school and deleted_at is null
     and id in (select id from public.students where school_id = v_school and deleted_at is null
                offset 210);
  perform public.fn_refresh_student_count(v_school);

  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);
  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;

  if lic->>'limit_state' <> 'within_margin' then
    raise exception 'FAIL: expected within_margin at % students, got %',
      lic->>'student_count', lic->>'limit_state';
  end if;
  if (select over_limit_flagged_at from public.subscriptions where school_id = v_school) is not null then
    raise exception 'FAIL: a school inside its margin was flagged';
  end if;
  raise notice 'ok: inside the margin is silent (% students)', lic->>'student_count';
end $$;

-- =============================================================================
-- Trial -> grace -> locked, and what a locked school can still do.
-- =============================================================================
do $lifecycle$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  v_sess   uuid := (select v from public._sub_ids where k='sess');
  v_class  uuid := (select v from public._sub_ids where k='class');
  v_stu    uuid;
  st  public.subscription_status;
  lic jsonb;
  ok  boolean;
  n   bigint;
begin
  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);

  -- In trial: operational.
  if public.fn_effective_status(v_school) <> 'trialing' then
    raise exception 'FAIL: fresh school is not trialing';
  end if;

  -- Trial expired, nothing paid -> locked (no grace on an unpaid trial).
  update public.subscriptions set trial_ends_on = current_date - 1 where school_id = v_school;
  if public.fn_effective_status(v_school) <> 'locked' then
    raise exception 'FAIL: expired trial is not locked';
  end if;

  -- Paid for a year -> active.
  perform public.fn_activate_subscription(v_school, 'growth', 12);
  if public.fn_effective_status(v_school) <> 'active' then
    raise exception 'FAIL: activated school is not active';
  end if;

  -- Period just ended -> grace, still operational. This is the window that
  -- covers a bank transfer sitting in the account, not yet switched on.
  update public.subscriptions set period_end = current_date - 1 where school_id = v_school;
  st := public.fn_effective_status(v_school);
  if st <> 'grace' then raise exception 'FAIL: expected grace, got %', st; end if;

  insert into public.students (gr_no, full_name, school_id)
    values ('GRACE-1', 'During grace', v_school) returning id into v_stu;

  -- Past grace -> locked.
  update public.subscriptions set period_end = current_date - 15 where school_id = v_school;
  st := public.fn_effective_status(v_school);
  if st <> 'locked' then raise exception 'FAIL: expected locked, got %', st; end if;

  -- Locked: writes refused...
  ok := false;
  begin
    insert into public.students (gr_no, full_name, school_id)
      values ('LOCKED-1', 'Should not save', v_school);
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL: a locked school could still write'; end if;

  -- ...but reads and export still work. A school is never held away from its
  -- own records, whatever it owes.
  set local role authenticated;
  select count(*) into n from public.students;
  lic := public.fn_my_licence();
  reset role;

  if n = 0 then raise exception 'FAIL: a locked school cannot read its own students'; end if;
  if (lic->>'can_export')::boolean is not true then
    raise exception 'FAIL: export withdrawn from a locked school';
  end if;
  if (lic->>'can_operate')::boolean is not false then
    raise exception 'FAIL: locked school reports it can operate';
  end if;

  -- Paying reopens it.
  perform public.fn_activate_subscription(v_school, 'growth', 12);
  if public.fn_effective_status(v_school) <> 'active' then
    raise exception 'FAIL: paying did not reactivate the school';
  end if;
  insert into public.students (gr_no, full_name, school_id)
    values ('REACTIVATED', 'After paying', v_school);

  raise notice 'ok: trial -> grace -> locked -> reactivated; reads and export never withdrawn';
end $lifecycle$;

-- Renewing early extends from the existing end date, not from today.
do $$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  v_end_before date; v_end_after date;
begin
  select period_end into v_end_before from public.subscriptions where school_id = v_school;
  perform public.fn_activate_subscription(v_school, 'growth', 12);
  select period_end into v_end_after from public.subscriptions where school_id = v_school;
  if v_end_after <= v_end_before then
    raise exception 'FAIL: early renewal lost time (% -> %)', v_end_before, v_end_after;
  end if;
  raise notice 'ok: early renewal extends (% -> %)', v_end_before, v_end_after;
end $$;

-- The platform worklist suggests the plan that matches the real headcount.
do $$
declare r record;
begin
  perform public.fn_refresh_student_count((select v from public._sub_ids where k='school'));
  select * into r from public.fn_platform_schools()
   where school_name = 'Limit Test School';
  if r.suggested_plan is null then raise exception 'FAIL: no suggested plan'; end if;
  if r.student_count > 200 and r.suggested_plan = 'starter' then
    raise exception 'FAIL: suggested starter for % students', r.student_count;
  end if;
  raise notice 'ok: platform worklist suggests % for % students', r.suggested_plan, r.student_count;
end $$;

drop table if exists public._sub_ids;
select 'SUBSCRIPTION RULES: ALL TESTS PASSED' as result;
