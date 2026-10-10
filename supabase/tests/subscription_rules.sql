-- =============================================================================
-- Subscription, trial, grace, lock and student-limit rules.
--
-- The rule this file exists to defend: going over the student limit must NEVER
-- block anything except the next admission. It is easy to "tighten" that later
-- by adding a check on student insert; this test fails loudly if anyone does.
--
-- 0155 changed four of the rules below, and the blocks say where:
--   * there is no 10% margin: plan_margin_limit(n) is n, limit_state is 'ok'
--     or 'over', and the gate stops at exactly the limit;
--   * grace follows a trial too: a trial that ended yesterday is in grace,
--     and locks fourteen days later, like a paid period;
--   * access runs on what is PAID: fn_activate_subscription raises an invoice
--     and nothing more, and recording the payment is what opens the school;
--   * a school changes plan only through us (fn_platform_change_plan).
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/subscription_rules.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- Wrapped in a transaction that is rolled back at the end, like the ten newer
-- suites. It was not, and the "clean slate" delete below hid why: nothing
-- cascades from public.schools (34 tables reference it with NO ACTION), so on
-- a fresh database that delete matches zero rows and does nothing, while on a
-- second run it fails outright on the profiles foreign key. This suite could
-- therefore only ever be run ONCE per database, and the rows it committed were
-- what made counter.sql pass alone and fail after fee_ops.sql.
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- Fixture: one school, one owner, one class, one current session ---------
do $seed$
declare
  v_school uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000c1';
  v_sess uuid; v_class uuid;
begin
  -- (No "clean slate" delete here. Nothing cascades from public.schools:
  -- 34 tables reference it with NO ACTION, so the delete that used to sit
  -- on this line matched zero rows on a fresh database and failed outright
  -- on a re-run. The suite rolls back instead, which actually works.)

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

  -- The platform operator. Activation and renewal are things WE do after a bank
  -- transfer clears, not something a school can do for itself, so the tests
  -- below switch to this identity for those calls, exactly as production will.
  insert into auth.users (id, email)
    values ('00000000-0000-0000-0000-0000000000fa'::uuid, 'ops@platform.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email)
    values ('00000000-0000-0000-0000-0000000000fa'::uuid, 'ops@platform.test')
    on conflict (user_id) do nothing;

  create table if not exists public._sub_ids (k text primary key, v uuid);
  delete from public._sub_ids;
  insert into public._sub_ids values
    ('school', v_school), ('owner', v_owner), ('sess', v_sess), ('class', v_class),
    ('ops', '00000000-0000-0000-0000-0000000000fa'::uuid);
end $seed$;

-- Switch the acting user. Keeps the identity juggling below to one readable line.
create or replace function public._act_as(p_key text) returns void
language plpgsql as $$
begin
  perform set_config('test.uid', (select v::text from public._sub_ids where k = p_key), false);
end;
$$;

-- --- Plan maths --------------------------------------------------------------
-- 0155 took the 10% margin away. plan_margin_limit stays because older
-- functions still call it, and it must now give back the limit it is given:
-- if it ever answered 308 for 280 again, a school would be told it had room
-- the gate does not give it.
do $$
begin
  if public.plan_margin_limit(280)  <> 280  then raise exception 'FAIL: 280 has a margin again'; end if;
  if public.plan_margin_limit(500)  <> 500  then raise exception 'FAIL: 500 has a margin again'; end if;
  if public.plan_margin_limit(1000) <> 1000 then raise exception 'FAIL: 1000 has a margin again'; end if;
  if public.plan_margin_limit(null) is not null then raise exception 'FAIL: no limit grew one'; end if;
  raise notice 'ok: there is no margin, the limit is the limit';
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
  v_op_state   text;
  v_op_upgrade boolean;
  v_limit      integer;
begin
  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);

  -- Push well past the plan limit. There used to be a margin ceiling to clear
  -- as well; 0155 removed it, so "well past" is now simply a hundred over.
  -- The count is derived from the plan, never hardcoded: the old loop stopped
  -- at 249 pupils, which was over the 150 starter limit and is UNDER the 280
  -- one, so repricing the tiers silently made this block test nothing.
  -- Every one of these inserts must succeed: this is the admissions desk, and
  -- the raw insert never closes (the gate is fn_admit_student, see below).
  select p.student_limit into v_limit
    from public.subscriptions s join public.plans p on p.code = s.plan_code
   where s.school_id = v_school;
  for i in 100..(v_limit + 200) loop
    insert into public.students (gr_no, full_name, school_id)
      values ('B' || i, 'Bulk ' || i, v_school) returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, school_id)
      values (v_stu, v_sess, v_class, v_school);
  end loop;

  perform public.fn_refresh_student_count(v_school);

  -- Put the renewal a long way off. The fixture's trial ends in 14 days, which
  -- is inside the 30-day window 0068 introduced, so the old version of this
  -- block asserted "a notice is shown" and would have passed either side of that
  -- change, testing nothing about it. 90 days is squarely mid-term: the school
  -- is over its limit and its renewal is months away.
  update public.subscriptions set trial_ends_on = current_date + 90
   where school_id = v_school;

  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;

  if (lic->>'student_count')::int <= v_limit then
    raise exception 'FAIL: fixture did not exceed the limit (count=%, limit=%)',
      lic->>'student_count', v_limit;
  end if;
  -- The banner still carries margin_limit for older screens. With no margin
  -- it must say the limit itself, or an older screen would show room that
  -- the gate does not give.
  if (lic->>'margin_limit')::int is distinct from (lic->>'student_limit')::int then
    raise exception 'FAIL: margin_limit % is not the limit %',
      lic->>'margin_limit', lic->>'student_limit';
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

  -- 0068 SAID: mid-term, the SCHOOL is told nothing. 0128 CHANGED THAT, and
  -- deliberately.
  --
  -- 0067 made student_count live, and 0068's worry was that the banner would
  -- appear the same afternoon the 101st child was admitted, on the admissions
  -- screen, while the school was earning money. That was the right worry while
  -- the limit was advisory: the notice ended "Nothing stops working", so it was
  -- a nag and nothing more.
  --
  -- 0128 makes it a limit. An admission past it is refused. A warning withheld
  -- until a renewal is thirty days away then arrives AFTER the first refusal,
  -- which is the one thing worse than a nag. So the notice now appears from 90%
  -- of the limit whatever the renewal date, and this school is a hundred over.
  --
  -- Still nothing below 90%: a banner a school sees every day is a banner it
  -- stops reading. That half is asserted in supabase/tests/student_limit.sql
  -- assertion 26.
  if lic->>'limit_notice' is null then
    raise exception
      'FAIL: an over-limit school was told nothing, 90 days from renewal or '
      'not. Since 0128 the admission is refused, so a warning that waits for '
      'the renewal conversation arrives after the refusal.';
  end if;
  if lic->>'limit_notice' not like '%admissions are paused%' then
    raise exception
      'FAIL: the notice does not say that admissions are paused, which is the '
      'thing that is actually true now: %', lic->>'limit_notice';
  end if;
  if lic->>'limit_notice' like '%Nothing stops working%' then
    raise exception
      'FAIL: the notice still promises that nothing stops working, which 0128 '
      'made false: %', lic->>'limit_notice';
  end if;

  -- ...and in the same breath, the OPERATOR is told everything. This pair of
  -- assertions is the whole of 0068: same fact, two audiences, different
  -- timing. If a future change gates the operator's copy too, the growth that
  -- 0067 exists to catch becomes invisible again and this fails.
  --
  -- fn_platform_schools raises 42501 for anyone who is not a platform admin, so
  -- the identity has to change and change back: the assertions after this are
  -- about the school again.
  perform public._act_as('ops');
  select ps.limit_state, ps.needs_upgrade into v_op_state, v_op_upgrade
    from public.fn_platform_schools() ps where ps.school_id = v_school;
  perform public._act_as('owner');

  if v_op_state <> 'over' then
    raise exception 'FAIL: the operator console lost sight of an over-limit school (%)',
      coalesce(v_op_state, '<no row>');
  end if;
  if v_op_upgrade is not true then
    raise exception 'FAIL: the operator was not told this school needs a bigger plan';
  end if;

  -- Bring the renewal inside 30 days: now the conversation is live, and the
  -- number is a fact about a decision being taken this week.
  update public.subscriptions set trial_ends_on = current_date + 20
   where school_id = v_school;
  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;
  if lic->>'limit_notice' is null then
    raise exception 'FAIL: no notice with the renewal 20 days away';
  end if;
  if lic->>'limit_notice' not like '%' || (lic->>'student_count') || '%' then
    raise exception 'FAIL: the notice does not name the real count (%): %',
      lic->>'student_count', lic->>'limit_notice';
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

  raise notice 'ok: over the limit is flagged to the operator, warned to the '
    'school, and blocks only the next ADMISSION (0128). This block''s raw '
    'insert above bypasses fn_admit_student on purpose: it is asserting that '
    'nothing else about an over-limit school changes, and the gate itself is '
    'asserted in supabase/tests/student_limit.sql.';
end $limits$;

-- One over the limit, and exactly at it. There used to be a band between the
-- two ('within_margin', up to 10% over) where a school was neither fine nor
-- flagged. 0155 removed it: limit_state is 'ok' or 'over' and nothing else,
-- and the gate stops at exactly the limit.
do $$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  v_limit  integer;
  lic jsonb;
begin
  -- Derived from the plan, never hardcoded: repricing the tiers must not
  -- silently turn these assertions into a test of nothing.
  select p.student_limit into v_limit
  from public.subscriptions s join public.plans p on p.code = s.plan_code
  where s.school_id = v_school;

  -- Keep exactly v_limit + 1 pupils that COUNT. Struck-off and deleted rows
  -- are left out of the choice, or one of them could be among the kept rows
  -- and the school would land one short, which these assertions cannot
  -- afford now that one pupil is the whole difference.
  update public.students set deleted_at = now()
   where id in (select id from public.students
                 where school_id = v_school and deleted_at is null and status = 'active'
                 order by gr_no offset v_limit + 1);
  perform public.fn_refresh_student_count(v_school);

  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);
  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;

  if (lic->>'student_count')::int <> v_limit + 1 then
    raise exception 'FAIL: fixture is at % pupils, wanted % (limit + 1)',
      lic->>'student_count', v_limit + 1;
  end if;

  -- 1. ONE over is over. Under the margin this was 'within_margin' and not
  -- flagged to the operator; with no margin it is both 'over' and flagged,
  -- because there is no allowance left that could make it fine.
  if lic->>'limit_state' <> 'over' then
    raise exception 'FAIL: expected over at % of %, got %',
      lic->>'student_count', lic->>'student_limit', lic->>'limit_state';
  end if;
  if (select over_limit_flagged_at from public.subscriptions where school_id = v_school) is null then
    raise exception 'FAIL: a school one over its limit was not flagged to the operator';
  end if;

  -- 2. EXACTLY at the limit is not over, and is not flagged: the school has
  -- every place it paid for and no more. The flag assertion is the one the
  -- old margin block made ("a school inside its margin was not flagged"),
  -- kept at the only line that is left to draw.
  update public.students set deleted_at = now()
   where id in (select id from public.students
                 where school_id = v_school and deleted_at is null and status = 'active'
                 order by gr_no offset v_limit);
  perform public.fn_refresh_student_count(v_school);

  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;

  if (lic->>'student_count')::int <> v_limit then
    raise exception 'FAIL: fixture is at % pupils, wanted the limit %',
      lic->>'student_count', v_limit;
  end if;
  if lic->>'limit_state' <> 'ok' then
    raise exception 'FAIL: expected ok at exactly the limit (% of %), got %',
      lic->>'student_count', lic->>'student_limit', lic->>'limit_state';
  end if;
  if (select over_limit_flagged_at from public.subscriptions where school_id = v_school) is not null then
    raise exception 'FAIL: a school exactly at its limit is still flagged as over it';
  end if;

  -- 3. ...but it is told, because its next admission will be refused.
  --
  -- 0068 SAID: 'within_margin' produces no sentence at all. Correct while the
  -- limit was advisory. 0128 made the limit a gate, and 0155 put the gate at
  -- exactly the limit: at 280 of 280 this school cannot admit anybody, so
  -- telling it nothing is not restraint, it is withholding the reason its
  -- next admission will be refused.
  --
  -- The silence that IS still asserted is the one that matters: below 90% of
  -- the limit nothing is said at all. supabase/tests/student_limit.sql
  -- assertion 26 covers it, on a school at a third of its limit.
  if lic->>'limit_notice' is null then
    raise exception 'FAIL: a school at its limit was told nothing, when '
      'its next admission will be refused: % of %',
      lic->>'student_count', lic->>'student_limit';
  end if;
  if lic->>'limit_notice' not like '%admissions are paused%' then
    raise exception 'FAIL: the notice does not say what is actually happening '
      'to a school at its limit: %', lic->>'limit_notice';
  end if;
  if (lic->>'at_limit')::boolean is not true then
    raise exception 'FAIL: at_limit is not set at % of %',
      lic->>'student_count', lic->>'student_limit';
  end if;

  raise notice 'ok: one over is over and flagged; exactly at the limit is ok, '
    'unflagged, and told admissions are paused (limit %)', v_limit;
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
  v_inv jsonb;
begin
  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);

  -- In trial: operational.
  if public.fn_effective_status(v_school) <> 'trialing' then
    raise exception 'FAIL: fresh school is not trialing';
  end if;

  -- Trial just ended, nothing paid -> GRACE, still operational. Before 0155 an
  -- unpaid trial locked the next morning. Grace now follows the trial like any
  -- covered period: the school is covered to the later of its trial and its
  -- paid period, and has fourteen days after that. A school that meant to pay
  -- in the last week of its trial is not locked out over a weekend.
  update public.subscriptions set trial_ends_on = current_date - 1 where school_id = v_school;
  st := public.fn_effective_status(v_school);
  if st <> 'grace' then
    raise exception 'FAIL: a trial that ended yesterday should be in grace, got %', st;
  end if;
  insert into public.students (gr_no, full_name, school_id)
    values ('TRIAL-GRACE', 'Admitted the day after the trial', v_school);

  -- Trial over and its grace spent -> locked.
  update public.subscriptions set trial_ends_on = current_date - 15 where school_id = v_school;
  st := public.fn_effective_status(v_school);
  if st <> 'locked' then
    raise exception 'FAIL: a trial past its grace should be locked, got %', st;
  end if;

  -- A paid period, set on the row directly (still supported for fixtures).
  -- It is set by hand and not paid through an invoice ON PURPOSE: the next
  -- two steps drag period_end into the past to simulate expiry, and since
  -- 0155 a paid invoice is the record of what the school has paid through.
  -- Dragging the row back behind a paid invoice would describe a school that
  -- cannot exist, and the invoice could not be voided to make room (money is
  -- allocated to it). The real path, invoice then payment, is walked at the
  -- end of this block and in the early-renewal block below.
  update public.subscriptions
     set status = 'active', period_start = current_date - 335,
         period_end = current_date + 30
   where school_id = v_school;
  if public.fn_effective_status(v_school) <> 'active' then
    raise exception 'FAIL: a school paid through a future date is not active';
  end if;

  -- Period just ended -> grace, still operational. This is the window that
  -- covers a bank transfer sitting in the account, not yet switched on. The
  -- trial ended long ago, so the paid period is what decides it.
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

  -- Paying reopens it. Note this works while the school is LOCKED: the platform
  -- path must stay open in every state, or a locked school could never be
  -- switched back on. Everything here is a PLATFORM action, done by us once
  -- the bank transfer clears, never something the school can do for itself.
  perform public._act_as('ops');

  -- The school is on starter and pays for growth. Before 0155 the activation
  -- moved the plan as well; now a plan moves only through
  -- fn_platform_change_plan, and fn_activate_subscription refuses a plan that
  -- is not the school's own.
  ok := false;
  begin
    perform public.fn_activate_subscription(v_school, 'growth', 12);
  exception when sqlstate '22023' then ok := true;
  end;
  if not ok then
    raise exception 'FAIL: fn_activate_subscription invoiced growth for a school on starter';
  end if;
  perform public.fn_platform_change_plan(v_school, 'growth',
    'test: the owner asked to move up before paying', null, null);

  -- Raising the invoice opens nothing. Access runs on what is paid, so the
  -- school is still locked with the invoice in its hand.
  v_inv := public.fn_activate_subscription(v_school, 'growth', 12);
  if public.fn_effective_status(v_school) <> 'locked' then
    raise exception 'FAIL: raising an invoice reopened the school before it paid (%)',
      public.fn_effective_status(v_school);
  end if;
  -- A school past its grace is billed from the day it comes back, not for the
  -- weeks it was locked out.
  if (v_inv->>'period_start')::date <> current_date then
    raise exception 'FAIL: a locked school was billed from %, not from today',
      v_inv->>'period_start';
  end if;

  -- Recording the payment is what reopens it, paid through a year from today.
  perform public.fn_platform_record_payment(v_school, (v_inv->>'owed')::numeric,
    p_invoice_id => (v_inv->>'invoice_id')::uuid, p_reference => 'TEST-REOPEN');
  perform public._act_as('owner');
  if public.fn_effective_status(v_school) <> 'active' then
    raise exception 'FAIL: paying did not reactivate the school (%)',
      public.fn_effective_status(v_school);
  end if;
  if (select period_end from public.subscriptions where school_id = v_school)
     <> (v_inv->>'period_end')::date then
    raise exception 'FAIL: the school is not paid through the end of the invoice it paid (% vs %)',
      (select period_end from public.subscriptions where school_id = v_school),
      v_inv->>'period_end';
  end if;
  insert into public.students (gr_no, full_name, school_id)
    values ('REACTIVATED', 'After paying', v_school);

  raise notice 'ok: trial -> grace -> locked; paid -> grace -> locked -> '
    'invoiced (still locked) -> paid (reactivated); reads and export never withdrawn';
end $lifecycle$;

-- Renewing early extends from the existing end date, not from today.
-- Since 0155 that is two steps: the invoice is raised for the period after the
-- one already paid, and the payment is what moves the end date.
do $$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  v_end_before date; v_end_mid date; v_end_after date; v_inv jsonb;
begin
  select period_end into v_end_before from public.subscriptions where school_id = v_school;
  perform public._act_as('ops');
  v_inv := public.fn_activate_subscription(v_school, 'growth', 12);

  if (v_inv->>'period_start')::date <> v_end_before + 1 then
    raise exception 'FAIL: early renewal invoiced from %, not from the day after the paid period (%)',
      v_inv->>'period_start', v_end_before + 1;
  end if;
  select period_end into v_end_mid from public.subscriptions where school_id = v_school;
  if v_end_mid <> v_end_before then
    raise exception 'FAIL: raising the renewal invoice moved the paid period (% -> %) before any payment',
      v_end_before, v_end_mid;
  end if;

  perform public.fn_platform_record_payment(v_school, (v_inv->>'owed')::numeric,
    p_invoice_id => (v_inv->>'invoice_id')::uuid, p_reference => 'TEST-EARLY');
  select period_end into v_end_after from public.subscriptions where school_id = v_school;
  if v_end_after <= v_end_before then
    raise exception 'FAIL: early renewal lost time (% -> %)', v_end_before, v_end_after;
  end if;
  if v_end_after <> (v_inv->>'period_end')::date then
    raise exception 'FAIL: early renewal paid through %, the invoice it paid ends %',
      v_end_after, v_inv->>'period_end';
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

  -- The suggestion has to actually FIT the roster. Derived from the plans
  -- table so repricing the tiers cannot quietly make this assertion vacuous:
  -- either the suggested plan has room, or it is the unlimited/custom tier.
  if exists (
    select 1 from public.plans p
    where p.code = r.suggested_plan
      and p.student_limit is not null
      and p.student_limit < r.student_count
  ) then
    raise exception 'FAIL: suggested % (limit %) for % students',
      r.suggested_plan,
      (select student_limit from public.plans where code = r.suggested_plan),
      r.student_count;
  end if;
  raise notice 'ok: platform worklist suggests % for % students', r.suggested_plan, r.student_count;
end $$;

drop table if exists public._sub_ids;
select 'SUBSCRIPTION RULES: ALL TESTS PASSED' as result;

rollback;
