-- =============================================================================
-- A school choosing how it pays, and the plan it may not choose for itself
--
-- 0155 CHANGED WHAT THIS SUITE DEFENDS. Before it a trialing school could pick
-- its own plan, and the rules here were the walls around that choice. Since
-- 0155 a school never changes its own plan: we do, with fn_platform_change_plan,
-- because a move is a limit decision and a price conversation at once, and a
-- school that moved itself could be caught out by either.
--
--   1. A school asking for a different plan is refused, trialing or not, in
--      words that say what to do instead. Nothing changes, nothing is invoiced.
--   2. With its own plan code, or none, the same call changes the TERM only:
--      one month, three months or a year. That still works once it is active,
--      because the term only prices the next invoice.
--   3. Once active it still cannot swap the plan, and the refusal leaves the
--      plan exactly where it was.
--   4. It can never move itself onto Enterprise, the plan priced by
--      arrangement: that plan has no pupil limit.
--   5. OUR path refuses a move the roll does not fit: a plan smaller than the
--      roll is refused with both numbers. There is no margin any more, so one
--      pupil over is enough.
--   6. A clerk may not change the plan or the term at all.
--   7. The region is stored, and one that is not on the list is refused with
--      the list.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/plan_choice.sql
-- =============================================================================
\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- This suite owns its limits: every figure is arithmetic about a threshold.
-- Institution is retired since 0155 and nothing here uses it any more.
update public.plans set student_limit = 3  where code = 'starter';
update public.plans set student_limit = 8  where code = 'growth';

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  if position(lower(p_needle) in lower(sqlerrm)) > 0 then return true; end if;
  raise notice '  (refused, but with the wrong message: %)', sqlerrm;
  return false;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

-- --- Fixture: one school created through the real signup path ----------------
do $seed$
declare
  v_a uuid; v_sess uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000070a1';
  v_ca uuid := '00000000-0000-0000-0000-0000000070a2';
  v_op uuid := '00000000-0000-0000-0000-0000000070af';
begin
  -- The operator. Since 0155 every plan move is ours, so the suite needs us.
  insert into auth.users (id, email) values (v_op, 'op@plan.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email)
    values (v_op, 'op@plan.test') on conflict (user_id) do nothing;

  v_a := (public.fn_signup_school_on_plan_in_region(
            'Plan Choice School', 'Rawalpindi', 'Nasreen Akhtar', '03001234567',
            'owner@planchoice.test', 'starter', 1, 'Punjab')->>'school_id')::uuid;

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'oa@plan.test'), (v_ca, 'ca@plan.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Plan Owner', 'owner',       v_a),
    (v_ca, 'Plan Class Teacher', 'class_teacher', v_a)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id, starts_on, ends_on)
    values ('2026-2027', true, v_a, current_date - 60, current_date + 300)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id) values ('Class 1', 1, v_a);
end
$seed$;

-- --- 7. The region ------------------------------------------------------------
select pg_temp.ok(
  (select region from public.schools where name = 'Plan Choice School') = 'Punjab',
  '7. the region chosen at signup is stored on the school');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_signup_school_on_plan_in_region('Bad Region', null, null, null, null,
       'starter', 1, 'Kashmir') $$, 'no region called'),
  '7b. a region not on the list is refused, with the list');
select pg_temp.ok(
  array_length(public.fn_signup_regions(), 1) = 7,
  '7c. the list the form is given is the four provinces and the three territories');

-- --- 3 (only one copy of the function) ---------------------------------------
-- THREE NAMES, ONE FUNCTION EACH. 0132 added the region under a third name
-- rather than as an eighth parameter on the second, because an overload makes
-- every call to it ambiguous ("is not unique") and takes public signup down on
-- any school that re-pastes the frozen bundle 33.
select pg_temp.ok(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public'
                 and p.proname in ('fn_signup_school', 'fn_signup_school_on_plan',
                                   'fn_signup_school_on_plan_in_region')
               group by p.proname having count(*) > 1),
  '0. no name in the signup chain is overloaded, so no call is ever ambiguous');

-- --- 1. While trialing: the term, never the plan ----------------------------
-- Before 0155 a trialing school could change both here. Now a different plan
-- code is refused, in words that send the school to the request box rather
-- than to a control it does not have.
select pg_temp.be('Plan Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('growth', 12) $$, 'Plans are changed by us'),
  '1. a trialing school asking for another plan is refused, and told to ask us');
select pg_temp.ok(
  (select plan_code from public.subscriptions
    where school_id = public.current_school_id()) = 'starter',
  '1b. and the refusal left the plan where it was');
-- The stored term is read in a statement of its own: a subquery in the same
-- statement as the call reads the row as it was when the statement began.
select pg_temp.ok(
  (public.fn_my_choose_plan('starter', 12)->>'term_months')::int = 12,
  '1c. with its own plan code the same call changes the term, which is all it '
  || 'can change');
select pg_temp.ok(
  (select term_months from public.subscriptions
    where school_id = public.current_school_id()) = 12,
  '1d. and the term is stored');
select pg_temp.ok(
  (public.fn_my_choose_plan(null, 3)->>'term_months')::int = 3,
  '1e. and with no plan code at all, so an older screen that sends only the '
  || 'term still works');
select pg_temp.ok(
  (select term_months from public.subscriptions
    where school_id = public.current_school_id()) = 3,
  '1f. and that term is stored too');
select pg_temp.ok(
  (select count(*) from public.platform_invoices
    where school_id = (select id from public.schools where name='Plan Choice School')) = 0,
  '1g. and nothing was invoiced');

-- --- 6. Not a clerk -----------------------------------------------------------
select pg_temp.be('Plan Class Teacher');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('starter', 1) $$, 'owner or the principal'),
  '6. a clerk cannot change the plan, or the term');

-- --- 4. Never onto a plan priced by arrangement -------------------------------
-- custom was this plan before 0155 and is retired; Enterprise is it now. The
-- refusal is the general one: no plan is self-served, this one least of all.
select pg_temp.be('Plan Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('enterprise', 12) $$, 'Plans are changed by us'),
  '4. the by-arrangement plan cannot be self-served');
select pg_temp.ok(
  (select plan_code from public.subscriptions
    where school_id = (select id from public.schools where name='Plan Choice School'))
  = 'starter',
  '4b. and the school is still on starter');

-- --- 5. Never down into a wall, on our path either ----------------------------
-- The school asked us and we moved it up. A trialing school is moved with no
-- charge: there is no paid period to charge the difference on.
do $$
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000070af', false);
  perform public.fn_platform_change_plan(
    (select id from public.schools where name = 'Plan Choice School'), 'growth',
    'test: the owner rang, expecting a fourth child', null, null);
end $$;
select pg_temp.ok(
  (select plan_code from public.subscriptions
    where school_id = (select id from public.schools where name='Plan Choice School'))
  = 'growth',
  '5. the operator can move a school up, which is the path a school is sent to');

-- FOUR pupils, and four is enough. The first version of this test needed five,
-- because starter's limit here is three and the old plan_margin_limit(3) was 4:
-- four pupils sat inside a tolerance the product granted on purpose. 0155
-- removed the margin, so one pupil over the limit is a roll that does not fit.
--
-- The refusal recounts rather than trusting the stored figure, so these are
-- real children on the roll: that is the number the refusal has to use.
do $$
declare v_sess uuid; v_class uuid;
begin
  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'Plan Owner'), false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes
   where school_id = public.current_school_id() limit 1;
  for i in 1..4 loop
    perform public.fn_admit_student(jsonb_build_object(
      'full_name', 'Pupil ' || i, 'father_name', 'Father ' || i,
      'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  end loop;
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000070af', false);
end $$;
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_change_plan(
       (select id from public.schools where name = 'Plan Choice School'), 'starter',
       'test: the owner asked to pay less', null, null) $$,
  'has 4 pupils on the roll and Starter covers 3'),
  '5b. a plan smaller than the roll is refused, with both numbers, even to us');
select pg_temp.ok(
  (select plan_code from public.subscriptions
    where school_id = (select id from public.schools where name='Plan Choice School'))
  = 'growth',
  '5c. and the refusal left the plan where it was');

-- --- 2 and 3. Once active -----------------------------------------------------
do $$
begin
  update public.subscriptions
     set status = 'active', period_start = current_date - 10,
         period_end = current_date + 80
   where school_id = (select id from public.schools where name = 'Plan Choice School');
end $$;
select pg_temp.be('Plan Owner');
select pg_temp.ok(
  (public.fn_my_choose_plan('growth', 12)->>'term_months')::int = 12,
  '2. an active school may still change how often it pays');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('starter', 12) $$, 'Plans are changed by us'),
  '3. but not swap the plan part way through a paid period');
select pg_temp.ok(
  (select plan_code from public.subscriptions
    where school_id = (select id from public.schools where name='Plan Choice School'))
  = 'growth',
  '3b. and the refusal left the plan exactly where it was');

rollback;
