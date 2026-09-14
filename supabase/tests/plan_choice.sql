-- =============================================================================
-- A school choosing its own plan, and the four things it must not be able to do
--
--   1. While trialing it may change both the plan and the term. Nothing is
--      charged and nothing is invoiced.
--   2. Once active it may change the TERM, because that only prices the next
--      renewal.
--   3. Once active it may NOT swap the plan. Upward that would hand it a bigger
--      student limit for free until renewal; downward it would take away a
--      limit it has already paid for. Both need a pro-rata invoice this product
--      does not raise, so it is refused in words that say what to do.
--   4. It may never move onto a plan priced by arrangement: that plan has no
--      student limit, so it would be unlimited pupils for nothing.
--   5. It may never downgrade into a wall: a plan smaller than the roll it
--      already has is refused with both numbers.
--   6. A clerk may not change the plan at all.
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
update public.plans set student_limit = 3  where code = 'starter';
update public.plans set student_limit = 8  where code = 'growth';
update public.plans set student_limit = 20 where code = 'institution';

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
begin
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

-- --- 1. While trialing, both --------------------------------------------------
select pg_temp.be('Plan Owner');
select pg_temp.ok(
  (public.fn_my_choose_plan('growth', 12)->>'plan_code') = 'growth',
  '1. a trialing school may change its plan');
select pg_temp.ok(
  (select term_months from public.subscriptions
    where school_id = public.current_school_id()) = 12,
  '1b. and its term, in the same call');
select pg_temp.ok(
  (select count(*) from public.platform_invoices
    where school_id = (select id from public.schools where name='Plan Choice School')) = 0,
  '1c. and nothing was invoiced');

-- --- 6. Not a clerk -----------------------------------------------------------
select pg_temp.be('Plan Class Teacher');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('starter', 1) $$, 'owner or the principal'),
  '6. a clerk cannot change the plan');

-- --- 4. Never onto a plan priced by arrangement -------------------------------
select pg_temp.be('Plan Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('custom', 12) $$, 'not one you can move onto yourself'),
  '4. the by-arrangement plan cannot be self-served');

-- --- 5. Never down into a wall ------------------------------------------------
-- FIVE pupils, not four, and the difference is the margin. Starter's limit
-- here is three and plan_margin_limit(3) is 4, so four pupils are inside the
-- tolerance the product grants on purpose and moving there would be allowed.
-- The first version of this test used four, asserted a refusal, and was wrong
-- about the product rather than finding a bug in it.
--
-- fn_my_choose_plan recounts rather than trusting the stored figure, so these
-- are real children on the roll: that is the number the refusal has to use.
do $$
declare v_sess uuid; v_class uuid;
begin
  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'Plan Owner'), false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select id into v_class from public.classes
   where school_id = public.current_school_id() limit 1;
  for i in 1..5 loop
    perform public.fn_admit_student(jsonb_build_object(
      'full_name', 'Pupil ' || i, 'father_name', 'Father ' || i,
      'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  end loop;
end $$;
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('starter', 1) $$, 'stop you admitting'),
  '5. a plan smaller than the roll is refused, with both numbers');

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
  (public.fn_my_choose_plan('growth', 3)->>'term_months')::int = 3,
  '2. an active school may still change how often it pays');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_choose_plan('institution', 3) $$, 'part way through a period'),
  '3. but not swap the plan part way through a paid period');
select pg_temp.ok(
  (select plan_code from public.subscriptions
    where school_id = (select id from public.schools where name='Plan Choice School'))
  = 'growth',
  '3b. and the refusal left the plan exactly where it was');

rollback;
