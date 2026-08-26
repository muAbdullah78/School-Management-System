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

-- Wrapped in a transaction that is rolled back at the end, like the ten newer
-- suites. It was not, and the "clean slate" delete below hid why: nothing
-- cascades from public.schools — 34 tables reference it with NO ACTION — so on
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
  -- (No "clean slate" delete here. Nothing cascades from public.schools —
  -- 34 tables reference it with NO ACTION — so the delete that used to sit
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
  -- transfer clears, not something a school can do for itself — so the tests
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
  v_op_state   text;
  v_op_upgrade boolean;
begin
  perform set_config('test.uid', (select v::text from public._sub_ids where k='owner'), false);

  -- Push well past the plan limit AND past its margin ceiling. Every one of
  -- these inserts must succeed: this is the admissions desk, and it never closes.
  for i in 100..340 loop
    insert into public.students (gr_no, full_name, school_id)
      values ('B' || i, 'Bulk ' || i, v_school) returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, school_id)
      values (v_stu, v_sess, v_class, v_school);
  end loop;

  perform public.fn_refresh_student_count(v_school);

  -- Put the renewal a long way off. The fixture's trial ends in 14 days, which
  -- is inside the 30-day window 0068 introduced — so the old version of this
  -- block asserted "a notice is shown" and would have passed either side of that
  -- change, testing nothing about it. 90 days is squarely mid-term: the school
  -- is over its limit and its renewal is months away.
  update public.subscriptions set trial_ends_on = current_date + 90
   where school_id = v_school;

  set local role authenticated;
  lic := public.fn_my_licence();
  reset role;

  if (lic->>'student_count')::int <= public.plan_margin_limit(
       (select p.student_limit from public.subscriptions s
        join public.plans p on p.code = s.plan_code where s.school_id = v_school)) then
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

  -- 0068. Mid-term, the SCHOOL is told nothing.
  --
  -- 0067 made student_count live, so without this the banner appears the same
  -- afternoon the 101st child is admitted — on the admissions screen, while the
  -- school is earning money. limit_state stays truthful; only the sentence
  -- meant to be rendered is withheld.
  if lic->>'limit_notice' is not null then
    raise exception
      'FAIL: an over-limit school 90 days from renewal was nagged: %',
      lic->>'limit_notice';
  end if;

  -- ...and in the same breath, the OPERATOR is told everything. This pair of
  -- assertions is the whole of 0068: same fact, two audiences, different
  -- timing. If a future change gates the operator's copy too, the growth that
  -- 0067 exists to catch becomes invisible again and this fails.
  --
  -- fn_platform_schools raises 42501 for anyone who is not a platform admin, so
  -- the identity has to change and change back — the assertions after this are
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

  raise notice 'ok: over the limit never blocks — school flagged, not stopped';
end $limits$;

-- Within the margin: no flag, no notice of trouble.
do $$
declare
  v_school uuid := (select v from public._sub_ids where k='school');
  v_limit  integer;
  v_target integer;
  lic jsonb;
begin
  -- Derived from the plan, never hardcoded: repricing the tiers must not
  -- silently turn this assertion into a test of nothing. Land halfway between
  -- the limit and the margin ceiling — over the limit, inside the margin.
  select p.student_limit into v_limit
  from public.subscriptions s join public.plans p on p.code = s.plan_code
  where s.school_id = v_school;

  v_target := v_limit + greatest(1, (public.plan_margin_limit(v_limit) - v_limit) / 2);

  update public.students set deleted_at = now()
   where school_id = v_school and deleted_at is null
     and id in (select id from public.students where school_id = v_school and deleted_at is null
                offset v_target);
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

  -- 0068: 'within_margin' produces no sentence at all, EVEN NOW — the block
  -- above left the renewal 20 days out, so the timing gate is open and the only
  -- thing keeping this silent is the state itself. Its old text read "You are
  -- still inside the allowance — nothing to do today", which is a banner whose
  -- content is that there is nothing to read. Noise like that is how the banner
  -- that will one day matter gets ignored.
  if (lic->>'days_left')::int > 30 then
    -- RAISE takes a literal format string, not an expression, so this stays on
    -- one line rather than being concatenated.
    raise exception 'FAIL: premise broken — this assertion only means something with the renewal inside 30 days, and it is % away', lic->>'days_left';
  end if;
  if lic->>'limit_notice' is not null then
    raise exception 'FAIL: a school inside its margin was shown a banner: %',
      lic->>'limit_notice';
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

  -- Paid for a year -> active. Activation is a PLATFORM action, done by us once
  -- the bank transfer clears — never something the school can do for itself.
  perform public._act_as('ops');
  perform public.fn_activate_subscription(v_school, 'growth', 12);
  perform public._act_as('owner');
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

  -- Paying reopens it. Note this works while the school is LOCKED: the platform
  -- path must stay open in every state, or a locked school could never be
  -- switched back on.
  perform public._act_as('ops');

  -- 0078 refuses an invoice that duplicates a live one exactly — same school,
  -- same plan, same period — because that is the signature of a double-submitted
  -- renewal, which bills a school twice for one year.
  --
  -- This block trips it, and the reason is worth stating rather than working
  -- around silently: the licence was dragged BACKWARDS in time above, by direct
  -- UPDATE, to simulate expiry. No function in this schema moves a period_end
  -- into the past, so in production the second activation would compute a
  -- different period_start and there would be no collision. Here it computes
  -- current_date again and matches the invoice raised at the top of the block.
  --
  -- Voiding that invoice is what an operator would actually do — it covers a
  -- period the school turns out never to have had — so the test does the same
  -- rather than disabling the guard.
  perform public.fn_platform_void_invoice(
    (select id from public.platform_invoices
      where school_id = v_school and voided_at is null
      order by created_at desc limit 1),
    'test: licence was rolled back to simulate expiry');

  perform public.fn_activate_subscription(v_school, 'growth', 12);
  perform public._act_as('owner');
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
  perform public._act_as('ops');
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
