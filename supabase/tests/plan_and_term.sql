-- =============================================================================
-- A school picks its plan and its term, and one column decides what it costs.
--
-- WHAT WAS WRONG. fn_signup_school created every subscription like this:
--
--     insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
--     values (v_id, 'starter', 'trialing', current_date + 14);
--
-- Plan hardcoded, cycle left to the column default of yearly, term_months left
-- to the column default of 12. Nobody was ever asked, and Settings quoted every
-- new school a yearly figure it had not chosen.
--
-- Pulling on that found two more, both about money:
--
--   * `quarterly` was not a value of the billing_cycle enum, although
--     plans.price_quarterly is populated and charged, so a school paying every
--     three months got an invoice that said monthly.
--   * fn_platform_due_soon and fn_platform_renewal_message worked out how many
--     months the next invoice covers as
--     `case when cycle = 'yearly' then 12 else 1 end`, while the invoice itself
--     is priced by fn__renewals_due on `term_months`. Those two diverge the
--     moment a school uses the term chooser in Settings, and the school is then
--     sent a figure its invoice will not match: a third of it on a quarterly
--     term, a twelfth on a yearly one.
--
-- The rules this file defends:
--
--   1. Signup records the plan and the term it was given, and echoes them back.
--   2. Given neither, it still does what it did before: Starter, a year.
--   3. A plan that does not exist, or is no longer sold, is refused BY NAME,
--      and the refusal lists what is on sale.
--   4. A term that is not sold is refused.
--   5. The trial is fourteen days on every plan and every term.
--   6. The first amount quoted is the chosen term's price, not the yearly one.
--   7. A three month term is recorded as quarterly, everywhere.
--   8. Activating a subscription records the term it invoiced.
--   9. The renewals worklist and the renewal message quote the figure the
--      invoice will actually say, whatever the cycle says.
--  10. fn_signup_school is reachable by the service role only.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/plan_and_term.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- THIS SUITE OWNS ITS OWN PRICES, for the reason operator_billing.sql gives
-- at length: every figure below is arithmetic, not a statement about what the
-- business charges, and 0111 broke eleven assertions in that suite by moving
-- the price list. price_quarterly is pinned NON-ZERO here, unlike there,
-- because the quarterly path is the point of this file.
update public.plans set student_limit =  150, price_monthly = 2000,
       price_quarterly =  5700, price_yearly = 20000 where code = 'starter';
update public.plans set student_limit =  350, price_monthly = 3500,
       price_quarterly = 10000, price_yearly = 35000 where code = 'growth';
update public.plans set student_limit =  600, price_monthly = 5500,
       price_quarterly = 15700, price_yearly = 55000 where code = 'institution';

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

create or replace function pg_temp.sub(p_name text) returns record language sql as $$
  select sub.* from public.subscriptions sub
    join public.schools s on s.id = sub.school_id where s.name = p_name;
$$;

-- =============================================================================
-- 1. SIGNUP RECORDS WHAT IT WAS GIVEN
-- =============================================================================
do $$
declare r jsonb; s record;
begin
  r := public.fn_signup_school_on_plan('Term A', 'Lahore', 'Owner A',
                                       '03001111111', 'a@term.test', 'growth', 1);
  perform pg_temp.ok(r->>'plan_code' = 'growth' and (r->>'term_months')::int = 1,
    '1  signup echoes back the plan and the term it recorded');
  perform pg_temp.ok((r->>'first_amount')::numeric = 2000
                     or (r->>'first_amount')::numeric = 3500,
    '2  and the first amount is a real figure');
  perform pg_temp.ok((r->>'first_amount')::numeric = 3500,
    '3  which is the chosen term''s price, not the yearly one');
  perform pg_temp.ok((r->>'student_limit')::int = 350,
    '4  and the limit that comes with the plan');

  select sub.* into s from public.subscriptions sub
    join public.schools sc on sc.id = sub.school_id where sc.name = 'Term A';
  perform pg_temp.ok(s.plan_code = 'growth' and s.term_months = 1,
    '5  the subscription row holds them too');
  perform pg_temp.ok(s.cycle::text = 'monthly',
    '6  and the cycle is set from the term rather than left at the default');
  perform pg_temp.ok(s.status = 'trialing' and s.trial_ends_on = current_date + 14,
    '7  a fourteen day trial, on a monthly plan');
end $$;

-- =============================================================================
-- 2. THREE MONTHS IS QUARTERLY. This is the value that did not exist.
-- =============================================================================
do $$
declare r jsonb; s record;
begin
  r := public.fn_signup_school_on_plan('Term B', null, 'Owner B', null,
                                       'b@term.test', 'starter', 3);
  select sub.* into s from public.subscriptions sub
    join public.schools sc on sc.id = sub.school_id where sc.name = 'Term B';
  perform pg_temp.ok(s.cycle::text = 'quarterly',
    '8  a three month term is recorded as quarterly, not as monthly');
  perform pg_temp.ok((r->>'first_amount')::numeric = 5700,
    '9  and priced at the quarterly rate');
  perform pg_temp.ok(s.trial_ends_on = current_date + 14,
    '10 fourteen days here too: the trial is the software, not the price');

  -- The rule itself, at every boundary an operator can invoice.
  perform pg_temp.ok(public.fn__cycle_for_months(1)::text  = 'monthly'
                 and public.fn__cycle_for_months(2)::text  = 'monthly'
                 and public.fn__cycle_for_months(3)::text  = 'quarterly'
                 and public.fn__cycle_for_months(6)::text  = 'quarterly'
                 and public.fn__cycle_for_months(11)::text = 'quarterly'
                 and public.fn__cycle_for_months(12)::text = 'yearly'
                 and public.fn__cycle_for_months(24)::text = 'yearly',
    '11 and one function decides the name, at every term an operator can bill');
end $$;

-- =============================================================================
-- 3. THE OLD FIVE-ARGUMENT NAME STILL DOES WHAT IT DID BEFORE
--
-- It survives for two reasons, and the second one is the load-bearing one.
--
-- An Edge Function deployment that predates this migration calls it, and must
-- keep working: that is what makes the two deployable in either order.
--
-- AND 0071 GRANTS EXACTLY THAT SIGNATURE, hardcoded, inside a bundle a school
-- has already pasted. The first version of 0127 dropped it to add two
-- parameters; bundle 7's second paste then failed on the grant and rolled the
-- whole bundle back, and eleven function bodies came out different because
-- later bundles patch functions from their own text. Assertions 33 to 35.
-- =============================================================================
do $$
declare s record;
begin
  perform public.fn_signup_school('Term C', null, 'Owner C', null, 'c@term.test');
  select sub.* into s from public.subscriptions sub
    join public.schools sc on sc.id = sub.school_id where sc.name = 'Term C';
  perform pg_temp.ok(s.plan_code = 'starter' and s.term_months = 12
                 and s.cycle::text = 'yearly',
    '12 the five-argument name still means Starter on a yearly term');
  perform pg_temp.ok(s.trial_ends_on = current_date + 14,
    '12b and a fourteen day trial, so an Edge Function deployment that '
    || 'predates this migration behaves exactly as it did');
end $$;

-- =============================================================================
-- 4. WHAT IT REFUSES, AND WHETHER THE REFUSAL HELPS
-- =============================================================================
do $$
begin
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_on_plan('Term D', null, null, null,
                                              'd@term.test', 'platinum', 12)$q$,
    'there is no plan called'),
    '13 a plan that does not exist is refused');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_on_plan('Term D', null, null, null,
                                              'd@term.test', 'platinum', 12)$q$,
    'starter'),
    '14 and the refusal lists the plans that ARE on sale');

  -- A plan withdrawn from sale stays in the table because old invoices point
  -- at it. A new school must not be able to land on one.
  update public.plans set active = false where code = 'institution';
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_on_plan('Term D', null, null, null,
                                              'd@term.test', 'institution', 12)$q$,
    'there is no plan called'),
    '15 a plan no longer sold is refused as well');
  update public.plans set active = true where code = 'institution';

  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_on_plan('Term D', null, null, null,
                                              'd@term.test', 'starter', 6)$q$,
    'one month, three months or a year'),
    '16 a term that is not sold is refused, naming the three that are');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school('', null, null, null, 'd@term.test')$q$,
    'school name is required'),
    '17 and a school with no name still cannot be created');

  perform pg_temp.ok(not exists (select 1 from public.schools where name = 'Term D'),
    '18 and none of those four refusals left a school behind');
end $$;

-- =============================================================================
-- 5. THE SENTENCE THE SCHOOL READS ON DAY ONE
--
-- fn_my_next_payment owns the wording, and it prices on term_months. This is
-- the assertion that would have caught the original fault from the school's
-- side: a school that agreed Rs 2,000 a month was shown Rs 20,000.
-- =============================================================================
do $$
declare v_school uuid; v_own uuid := '00000000-0000-0000-0000-00000000e0d1'; n jsonb;
begin
  select id into v_school from public.schools where name = 'Term A';
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_own, 'owner@term.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_own, 'Term Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_own::text, false);

  n := public.fn_my_next_payment();
  perform pg_temp.ok((n->>'term_months')::int = 1,
    '19 the school''s own screen shows the term it chose');
  perform pg_temp.ok((n->>'next_charge_amount')::numeric = 3500,
    '20 and the amount for that term, not for a year');
  perform pg_temp.ok(n->>'sentence' like '%3,500%',
    '21 and the sentence it reads says the same figure');
  perform pg_temp.ok(n->>'sentence' like '%free trial%',
    '22 while making clear nothing is charged today');
  perform set_config('test.uid', '', false);
end $$;

-- =============================================================================
-- 6. ACTIVATING RECORDS THE TERM IT INVOICED
-- =============================================================================
do $$
declare
  v_school uuid; v_op uuid := '00000000-0000-0000-0000-00000000e0d2';
  s record; v_inv record;
begin
  select id into v_school from public.schools where name = 'Term B';
  insert into auth.users (id, email) values (v_op, 'op@term.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email, note)
    values (v_op, 'op@term.test', 'Founder') on conflict (user_id) do nothing;
  perform set_config('test.uid', v_op::text, false);

  perform public.fn_activate_subscription(v_school, 'starter', 3);

  select sub.* into s from public.subscriptions sub where sub.school_id = v_school;
  perform pg_temp.ok(s.term_months = 3,
    '23 activating three months records a three month term');
  perform pg_temp.ok(s.cycle::text = 'quarterly',
    '24 and calls it quarterly, which the enum could not say before');

  select * into v_inv from public.platform_invoices
   where school_id = v_school order by created_at desc limit 1;
  perform pg_temp.ok(v_inv.months = 3 and v_inv.cycle::text = 'quarterly'
                 and v_inv.amount = 5700,
    '25 and the invoice says three months, quarterly, at the quarterly rate');
end $$;

-- =============================================================================
-- 7. THE FIGURE IN THE REMINDER IS THE FIGURE ON THE INVOICE
--
-- The divergence, staged exactly as a real school produces it: the operator
-- invoices a quarter, then the school uses the term chooser in Settings to
-- switch to monthly. fn__renewals_due will invoice one month. Before this
-- migration the worklist and the WhatsApp message both quoted twelve months,
-- because the cycle still said yearly, or one month while the invoice said
-- three. Neither reads the cycle now.
-- =============================================================================
do $$
declare
  v_school uuid; v_own uuid := '00000000-0000-0000-0000-00000000e0d3';
  v_op uuid := '00000000-0000-0000-0000-00000000e0d2';
  v_amount numeric; v_msg jsonb; v_due numeric;
begin
  select id into v_school from public.schools where name = 'Term C';

  perform set_config('test.uid', v_op::text, false);
  perform public.fn_activate_subscription(v_school, 'starter', 12);
  -- Bring the period end inside the worklist's window.
  update public.subscriptions set period_end = current_date + 5,
         grace_ends_on = current_date + 5 + public.grace_days()
   where school_id = v_school;

  -- The school changes its mind: monthly from now on.
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_own, 'ownerc@term.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_own, 'Term C Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_own::text, false);
  perform public.fn_choose_term(1);

  -- What the invoice will be. fn__renewals_due is what actually builds it.
  select amount into v_due from public.fn__renewals_due(current_date + 30)
   where school_id = v_school;
  perform pg_temp.ok(v_due = 2000,
    '26 the next invoice will be one month, because that is what they chose');

  perform set_config('test.uid', v_op::text, false);
  select renewal_amount into v_amount from public.fn_platform_due_soon(45)
   where school_id = v_school;
  perform pg_temp.ok(v_amount = v_due,
    '27 and the renewals worklist quotes exactly that, not a year of it');

  v_msg := public.fn_platform_renewal_message(v_school, 'due');
  perform pg_temp.ok(v_msg->>'text' like '%2,000%',
    '28 and so does the message that goes to the school');
  perform pg_temp.ok(v_msg->>'text' not like '%20,000%',
    '29 and it does not also contain the yearly figure it used to send');
  perform set_config('test.uid', '', false);
end $$;

-- =============================================================================
-- 8. THE DOOR IS STILL SHUT
--
-- fn_signup_school is the unguarded twin of fn_provision_school and the one
-- public unauthenticated path in the product. Dropping and recreating a
-- function drops its grants with it, so this is asserted rather than assumed.
-- =============================================================================
do $$
declare v_sig text :=
  'public.fn_signup_school_on_plan(text,text,text,text,text,text,integer)';
begin
  perform pg_temp.ok(
    not has_function_privilege('authenticated', v_sig::regprocedure, 'EXECUTE')
    and not has_function_privilege('anon', v_sig::regprocedure, 'EXECUTE'),
    '30 no browser role can create a school');
  perform pg_temp.ok(
    has_function_privilege('service_role', v_sig::regprocedure, 'EXECUTE'),
    '31 and the Edge Function''s role still can');
  perform pg_temp.ok(
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'fn_signup_school') = 1,
    '32 and exactly one fn_signup_school, so no five-argument call is ambiguous');

  -- 0071 IS INSIDE A BUNDLE A SCHOOL HAS ALREADY PASTED and it hardcodes
  -- `grant execute on function public.fn_signup_school(text, text, text, text,
  -- text) to service_role`. The first version of 0127 DROPPED that signature to
  -- add two parameters, and bundle 7's second paste then failed on the grant
  -- and rolled the whole bundle back. That is not harmless: later bundles patch
  -- functions from their own text, so with bundle 7's definitions absent from
  -- the replay, ELEVEN function bodies came out different. Pasting a bundle
  -- twice is what a school does when it is not sure the first one took. Caught
  -- by CI; these three are what stop it coming back.
  perform pg_temp.ok(
    to_regprocedure('public.fn_signup_school(text,text,text,text,text)') is not null,
    '33 the five-argument signature bundle 7 grants is still there');
  perform pg_temp.ok(
    has_function_privilege('service_role',
      'public.fn_signup_school(text,text,text,text,text)'::regprocedure, 'EXECUTE'),
    '34 and service_role can still call it, which is what that grant is for');
  perform pg_temp.ok(
    position('fn_signup_school_on_plan' in pg_get_functiondef(
      'public.fn_signup_school(text,text,text,text,text)'::regprocedure)) > 0,
    '35 and it delegates rather than holding a second copy of the rules');
end $$;

rollback;
