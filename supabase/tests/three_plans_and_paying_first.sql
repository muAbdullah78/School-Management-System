-- =============================================================================
-- Three plans, and access that runs on what is paid (0155).
--
-- The rules this file defends:
--
--   1. The price list is Starter 280 pupils at Rs 2,000 / 5,400 / 20,000,
--      Growth 1,000 at Rs 4,000 / 10,800 / 40,000, and Enterprise priced with
--      each school. Institution and Custom are retired.
--   2. Signup asks how many pupils; the number picks the plan. The trial is
--      fourteen days of access.
--   3. Raising an invoice never moves the licence. Paying it does, in order.
--      Unpaid fourteen days after it is due, the school locks.
--   4. A school that locked and comes back is billed from the day it comes
--      back, not for the weeks it was locked out.
--   5. An Enterprise school is priced by us; unpriced past its trial it is
--      locked, and pricing it gives it the usual fourteen days to pay.
--   6. Plans move only by us, with a suggested pro-rata charge we decide on.
--   7. The limit is the limit. Extra room ends at the next renewal and on any
--      plan change.
--   8. Nothing gives free access for ever, and nothing answers for another
--      school.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/three_plans_and_paying_first.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;
set local timezone = 'Asia/Karachi';

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if coalesce(p_cond, false) then raise notice 'PASS  %', p_label;
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

create or replace function pg_temp.sid(p_name text) returns uuid language sql as $$
  select id from public.schools where name = p_name;
$$;

create or replace function pg_temp.as_op() returns void language sql as $$
  select set_config('test.uid', '00000000-0000-0000-0000-0000000155f0', false);
$$;

create or replace function pg_temp.as_nobody() returns void language sql as $$
  select set_config('test.uid', '', false);
$$;

-- An owner login for a school, made on demand.
create or replace function pg_temp.owner_of(p_school uuid, p_tag text) returns uuid
language plpgsql as $$
declare v uuid := md5('owner-' || p_tag)::uuid;
begin
  insert into auth.users (id, email) values (v, p_tag || '@paidfirst.test')
    on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, active)
  values (v, 'Owner ' || p_tag, 'owner', p_school, true)
  on conflict (id) do update set school_id = excluded.school_id, role = 'owner', active = true;
  alter table public.profiles enable trigger user;
  return v;
end;
$$;

do $seed$
begin
  insert into auth.users (id, email)
  values ('00000000-0000-0000-0000-0000000155f0', 'op@paidfirst.test')
  on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email, note)
  values ('00000000-0000-0000-0000-0000000155f0', 'op@paidfirst.test', 'Founder')
  on conflict (user_id) do nothing;
end $seed$;

-- =============================================================================
-- 1. THE PRICE LIST
-- =============================================================================
do $$
declare v jsonb; s jsonb; g jsonb; e jsonb;
begin
  perform pg_temp.ok((select (student_limit, price_monthly, price_quarterly, price_yearly)
                        = (280, 2000::numeric, 5400::numeric, 20000::numeric)
                        from public.plans where code = 'starter'),
    '1  Starter: 280 pupils, Rs 2,000 a month, Rs 5,400 for three months, Rs 20,000 a year');
  perform pg_temp.ok((select (student_limit, price_monthly, price_quarterly, price_yearly)
                        = (1000, 4000::numeric, 10800::numeric, 40000::numeric)
                        from public.plans where code = 'growth'),
    '2  Growth: 1,000 pupils, Rs 4,000 / 10,800 / 40,000');
  perform pg_temp.ok((select by_arrangement and active and student_limit is null
                             and price_monthly = 0 and min_students = 1001
                        from public.plans where code = 'enterprise'),
    '3  Enterprise: priced by arrangement, no limit, from 1,001 pupils');
  perform pg_temp.ok((select bool_and(not active) from public.plans
                       where code in ('institution', 'custom')),
    '4  Institution and Custom are retired');
  perform pg_temp.ok(round(5400 / 3.0) = 1800 and 2000 * 3 * 0.9 = 5400
                     and 4000 * 3 * 0.9 = 10800 and 2000 * 10 = 20000 and 4000 * 10 = 40000,
    '5  three months is 10% off and a year is two months free, on both plans');

  v := public.fn_signup_plans();
  s := (select x from jsonb_array_elements(v) x where x->>'code' = 'starter');
  g := (select x from jsonb_array_elements(v) x where x->>'code' = 'growth');
  e := (select x from jsonb_array_elements(v) x where x->>'code' = 'enterprise');
  perform pg_temp.ok(jsonb_array_length(v) = 3,
    '6  signup offers exactly three plans');
  perform pg_temp.ok((s->'terms'->1->>'saving')::numeric = 600
                     and (s->'terms'->2->>'saving')::numeric = 4000
                     and (g->'terms'->1->>'saving')::numeric = 1200
                     and (g->'terms'->2->>'saving')::numeric = 8000,
    '7  and says what each term saves');
  perform pg_temp.ok(jsonb_array_length(e->'terms') = 0 and (e->>'by_arrangement')::boolean
                     and e->>'how_priced' like '%10%% off%',
    '8  Enterprise is listed with no price and says how it is priced');

  perform pg_temp.ok(pg_temp.raises(
    $q$update public.plans set price_monthly = 1999.5 where code = 'starter'$q$,
    'plans_price_shape_chk'),
    '9  a price in paisa cannot be put on the list');
  perform pg_temp.ok((select count(*) from public.plan_changes where code = 'starter') >= 1,
    '10 every change to the price list is written down');
end $$;

-- =============================================================================
-- 2. THE NUMBER OF PUPILS PICKS THE PLAN
-- =============================================================================
do $$
declare r jsonb; s record;
begin
  r := public.fn_signup_school_for_students('PF One', 'Lahore', 'A', '03001111111',
                                            'one@paidfirst.test', 'Punjab', 1, 1);
  perform pg_temp.ok(r->>'plan_code' = 'starter', '11 one pupil: Starter');
  r := public.fn_signup_school_for_students('PF 280', null, null, null, 'p280@paidfirst.test',
                                            null, 280, 3);
  perform pg_temp.ok(r->>'plan_code' = 'starter' and (r->>'first_amount')::numeric = 5400,
    '12 280 pupils: still Starter, and three months quoted at Rs 5,400');
  r := public.fn_signup_school_for_students('PF 281', null, null, null, 'p281@paidfirst.test',
                                            null, 281, 12);
  perform pg_temp.ok(r->>'plan_code' = 'growth' and (r->>'first_amount')::numeric = 40000,
    '13 281 pupils: Growth, a year at Rs 40,000');
  r := public.fn_signup_school_for_students('PF 1000', null, null, null, 'p1000@paidfirst.test',
                                            null, 1000, 1);
  perform pg_temp.ok(r->>'plan_code' = 'growth', '14 1,000 pupils: Growth');
  r := public.fn_signup_school_for_students('PF Big', null, null, null, 'big@paidfirst.test',
                                            null, 2500, 1);
  perform pg_temp.ok(r->>'plan_code' = 'enterprise' and r->>'first_amount' is null,
    '15 2,500 pupils: Enterprise, and no price until we agree one');

  select * into s from public.subscriptions where school_id = pg_temp.sid('PF Big');
  perform pg_temp.ok(s.declared_students = 2500, '16 the number the school gave is kept');
  perform pg_temp.ok(s.trial_ends_on = current_date + 13 and s.status = 'trialing',
    '17 the trial is fourteen days of access: today and the next thirteen');
  select * into s from public.subscriptions where school_id = pg_temp.sid('PF 281');
  perform pg_temp.ok(s.term_months = 12 and s.cycle = 'yearly',
    '18 the term chosen at signup is kept, with its cycle');

  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_for_students('PF Zero', null, null, null, null, null, 0, 1)$q$,
    'between 1 and 100,000'), '19 no pupils is refused');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_for_students('PF Lots', null, null, null, null, null, 100001, 1)$q$,
    'between 1 and 100,000'), '20 an absurd number is refused');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_for_students('PF Six', null, null, null, null, null, 50, 6)$q$,
    'one month, three months or a year'), '21 a term that is not sold is refused');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_signup_school_on_plan('PF Old', null, null, null, null, 'enterprise', 1)$q$,
    'how many pupils'), '22 the old signup cannot name Enterprise');
  r := public.fn_signup_school_on_plan('PF Old Growth', null, null, null, null, 'growth', null);
  perform pg_temp.ok(r->>'plan_code' = 'growth' and (r->>'term_months')::int = 1
                     and (r->>'trial_ends_on')::date = current_date + 13,
    '23 the old signup still works for a priced plan, a month by default, the same trial');

  perform pg_temp.ok(not has_function_privilege('anon',
      'public.fn_signup_school_for_students(text,text,text,text,text,text,integer,integer)', 'execute')
    and not has_function_privilege('authenticated',
      'public.fn_signup_school_for_students(text,text,text,text,text,text,integer,integer)', 'execute'),
    '24 only the signup function, with the service key, can create a school');
end $$;

-- =============================================================================
-- 3. RAISING AN INVOICE DOES NOT OPEN ANYTHING; PAYING IT DOES
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF One'); r jsonb; p jsonb; s record; v_inv uuid;
begin
  perform pg_temp.as_op();
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'trialing', '25 a new school is in its trial');

  r := public.fn_platform_raise_invoice(v_s, 1, null, null);
  v_inv := (r->>'invoice_id')::uuid;
  perform pg_temp.ok((r->>'period_start')::date = current_date + 14
                     and (r->>'amount')::numeric = 2000
                     and (r->>'due_on')::date = current_date + 14,
    '26 the first invoice starts the day after the trial, due that day, Rs 2,000');
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.period_end is null and s.status = 'trialing',
    '27 raising it moves nothing: still trialing, nothing paid through');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_raise_invoice(%L, 1, null, null)$q$, v_s), 'already has'),
    '28 a second invoice for the same period is refused while the first is owed');

  p := public.fn_platform_record_payment(v_s, 1500, current_date, 'bank', 'PART-1', null, null, 0, null);
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.period_end is null and public.fn__invoice_owed(v_inv) = 500,
    '29 a part payment is allocated and moves nothing: Rs 500 still owed');

  p := public.fn_platform_record_payment(v_s, 500, current_date, 'bank', 'PART-2', null, null, 0, null);
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.period_end = current_date + 14 + interval '1 month' - interval '1 day'
                     and s.status = 'active' and s.oldest_unpaid_due_on is null,
    '30 the rest pays it: active, paid through the end of that month');
  perform pg_temp.ok((select count(*) from public.platform_payment_allocations
                       where invoice_id = v_inv) = 2,
    '31 both payments are recorded against the invoice they paid');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_void_invoice(%L, 'oops')$q$, v_inv), 'has been received'),
    '32 a paid invoice cannot be voided');
  perform pg_temp.ok(pg_temp.raises(
    $q$insert into public.platform_invoices (school_id, plan_code, cycle, months, period_start,
       period_end, amount, list_amount) values (null, 'starter', 'monthly', 1, current_date,
       current_date, 1599.5, 1600)$q$, 'whole rupees'),
    '33 an invoice in paisa is refused');
end $$;

-- =============================================================================
-- 4. UNPAID: GRACE, THEN LOCKED; AND A SCHOOL THAT COMES BACK
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF 280'); r jsonb; p jsonb; s record; v_inv uuid;
begin
  perform pg_temp.as_op();
  -- The trial ended five days ago. A Starter school has its grace.
  update public.subscriptions set trial_ends_on = current_date - 5 where school_id = v_s;
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'grace',
    '34 five days after its trial ends, an unpaid school is in grace');
  update public.subscriptions set trial_ends_on = current_date - 15 where school_id = v_s;
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '35 fifteen days after, it is locked');

  -- It was invoiced from the end of its trial and never paid.
  r := public.fn_platform_raise_invoice(v_s, 3, null, null);
  v_inv := (r->>'invoice_id')::uuid;
  perform pg_temp.ok((r->>'period_start')::date = current_date,
    '36 a locked school is billed from today, not from when its trial ended');
  update public.platform_invoices set period_start = current_date - 14,
         period_end = current_date - 14 + 89, due_on = current_date - 14
   where id = v_inv;
  perform public.fn__recompute_licence(v_s);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '37 an invoice owed fourteen days past its due date keeps the school locked');

  -- It comes back weeks later and pays without naming an invoice.
  p := public.fn_platform_record_payment(v_s, 5400, current_date, 'bank', 'BACK-1', null, null, 0, null);
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_inv),
    '38 the invoice that lapsed unpaid is voided, with nothing on it');
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.period_start = current_date
                     and s.period_end = (current_date + interval '3 months')::date - 1
                     and public.fn_effective_status(v_s) = 'active',
    '39 and the payment opens a fresh three months from today');
  perform pg_temp.ok((p->>'status') = 'active' and p->'raised' is not null,
    '40 the answer says the school is back and which invoice was raised');
end $$;

-- =============================================================================
-- 5. A DEBT LOCKS EVEN INSIDE A PAID PERIOD
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF 280'); v_inv uuid;
begin
  perform pg_temp.as_op();
  insert into public.platform_invoices
    (school_id, plan_code, cycle, months, period_start, period_end, amount, list_amount,
     due_on, purpose, note)
  values (v_s, 'starter', 'quarterly', 1, current_date - 20, current_date + 50, 700, 700,
          current_date - 20, 'plan_change', 'test top-up')
  returning id into v_inv;
  perform public.fn__recompute_licence(v_s);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '41 an unpaid charge twenty days past due locks a school whose period is paid');
  perform public.fn_platform_record_payment(v_s, 700, current_date, 'bank', 'TOPUP', v_inv, null, 0, null);
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'active',
    '42 paying it opens the school again');
  perform pg_temp.ok((select period_end from public.subscriptions where school_id = v_s)
                       = (current_date + interval '3 months')::date - 1,
    '43 and a charge for a plan change never extends the period');
end $$;

-- =============================================================================
-- 6. NO FREE ACCESS FOR EVER
-- =============================================================================
do $$
declare v_s uuid; r jsonb;
begin
  perform pg_temp.as_op();
  insert into public.schools (name) values ('PF Forever') returning id into v_s;
  insert into public.subscriptions (school_id, plan_code, status) values (v_s, 'starter', 'trialing');
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '44 a trial with no end date is locked, not a trial for ever');
  update public.subscriptions set status = 'active' where school_id = v_s;
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '45 "active" with nothing paid and no dates is locked too');

  update public.subscriptions set status = 'cancelled', trial_ends_on = current_date - 40
   where school_id = v_s;
  r := public.fn_platform_reinstate_subscription(v_s, 'they asked to come back');
  perform pg_temp.ok((select status from public.subscriptions where school_id = v_s) = 'trialing'
                     and public.fn_effective_status(v_s) = 'locked'
                     and not (r->>'back_in')::boolean,
    '46 reinstating an expired, unpaid trial does not open it');
end $$;

-- =============================================================================
-- 7. A SCHOOL REPORTS A PAYMENT AND WE CONFIRM IT
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF 1000'); v_own uuid; c jsonb; v jsonb;
begin
  v_own := pg_temp.owner_of(v_s, 'pf1000');
  update public.subscriptions set trial_ends_on = current_date - 20 where school_id = v_s;

  perform set_config('test.uid', v_own::text, false);
  v := public.fn_my_licence();
  perform pg_temp.ok((v->>'locked')::boolean and v->>'locked_because' = 'expired'
                     and (v->>'pay_now')::numeric = 4000,
    '47 the locked school is told it is locked and what to pay: Rs 4,000');
  c := public.fn_my_report_payment(4000, current_date, 'bank', 'TXN-778', 'HBL', null);
  perform pg_temp.ok(c->>'message' like '%opens again%',
    '48 the reply says the software opens again when we confirm, not that nothing stops');

  perform pg_temp.as_op();
  v := public.fn_platform_confirm_claim((c->>'claim_id')::uuid, null, null, 0, null, null);
  perform pg_temp.ok(v->>'licence_status' = 'active'
                     and (v->>'paid_through')::date = current_date + interval '1 month' - interval '1 day',
    '49 confirming it raises the invoice, pays it and opens the school from today');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_confirm_claim(%L)$q$, c->>'claim_id'), 'already confirmed'),
    '50 a report cannot be confirmed twice');
  perform pg_temp.ok((select count(*) from public.platform_payments where school_id = v_s) = 1,
    '51 one report, one payment');
end $$;

-- =============================================================================
-- 8. CREDIT, AND A SCHOOL THAT PAYS EARLY
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF 281'); r jsonb; s record;
begin
  perform pg_temp.as_op();
  -- A yearly Growth school still in its trial pays Rs 40,500.
  r := public.fn_platform_record_payment(v_s, 40500, current_date, 'bank', 'EARLY', null, null, 0, null);
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.period_start = s.trial_ends_on + 1
                     and s.period_end = s.trial_ends_on + interval '12 months'
                     and public.fn_effective_status(v_s) = 'active',
    '52 paying during the trial keeps the trial and pays the year after it');
  perform pg_temp.ok((r->>'credit')::numeric = 500,
    '53 the Rs 500 over is held as credit');
  r := public.fn_platform_raise_invoice(v_s, 1, null, null);
  perform pg_temp.ok((r->>'owed')::numeric = 3500,
    '54 and comes off the next invoice when it is raised');
end $$;

-- =============================================================================
-- 9. ENTERPRISE: PRICED BY US
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF Big'); v_own uuid; r jsonb; v jsonb;
begin
  perform pg_temp.as_op();
  perform pg_temp.ok(public.fn__student_limit(v_s) is null,
    '55 Enterprise has no pupil limit, in its trial too');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_raise_invoice(%L, 1, null, null)$q$, v_s),
    'no price has been agreed'),
    '56 an unpriced Enterprise school cannot be invoiced, so never for Rs 0');

  update public.subscriptions set trial_ends_on = current_date - 30 where school_id = v_s;
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'locked',
    '57 past its trial with no price agreed, it is locked: no grace');
  v_own := pg_temp.owner_of(v_s, 'pfbig');
  perform set_config('test.uid', v_own::text, false);
  v := public.fn_my_licence();
  perform pg_temp.ok(v->>'locked_because' = 'needs_price' and (v->>'pay_now')::numeric = 0,
    '58 and it is told it is waiting for its price, with nothing to pay yet');

  perform pg_temp.as_op();
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_set_price(%L, 6000, 18001, null, 'agreed on a call')$q$, v_s),
    'no more than three times'),
    '59 three months cannot cost more than three single months');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_set_price(%L, 6000, null, null, null)$q$, v_s),
    'say how this price was agreed'),
    '60 a price needs to say how it was agreed');
  r := public.fn_platform_set_price(v_s, 6000, null, null, 'Agreed with the principal on 9 Oct for 2,500 pupils');
  perform pg_temp.ok((r->>'monthly')::numeric = 6000 and (r->>'quarterly')::numeric = 16200
                     and (r->>'yearly')::numeric = 60000,
    '61 Rs 6,000 a month: Rs 16,200 for three months, Rs 60,000 a year');
  perform pg_temp.ok(public.fn_effective_status(v_s) = 'grace',
    '62 pricing it gives it the usual fourteen days to pay');
  r := public.fn_platform_set_price(v_s, 6000, 16000, 58000, 'Yearly figure agreed separately');
  perform pg_temp.ok((r->>'quarterly')::numeric = 16000 and (r->>'yearly')::numeric = 58000,
    '63 we can agree its own three-month and yearly figures');
  r := public.fn_platform_raise_invoice(v_s, 12, null, null);
  perform pg_temp.ok((r->>'amount')::numeric = 58000 and r->>'plan_code' = 'enterprise',
    '64 and the invoice charges what was agreed');
  r := public.fn_platform_set_price(v_s, 5000, null, null, 'Revised after their board meeting');
  perform pg_temp.ok(r->'invoice'->>'voided' is not null
                     and (r->'invoice'->'raised'->>'amount')::numeric = 50000,
    '65 a new price reissues an invoice nothing has been paid on');

  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_set_price(%L, 3000, null, null, 'a special price')$q$,
           pg_temp.sid('PF One')),
    'has a fixed price'),
    '66 Starter and Growth have fixed prices: no special price for one school');
end $$;

-- =============================================================================
-- 10. PLANS MOVE ONLY BY US
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF One'); v_own uuid; q jsonb; r jsonb; s record;
begin
  v_own := pg_temp.owner_of(v_s, 'pfone');
  perform set_config('test.uid', v_own::text, false);
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_my_choose_plan('growth', 1)$q$, 'plans are changed by us'),
    '67 a school cannot move itself to another plan');

  perform pg_temp.as_op();
  -- Paid during its trial for the month after it: none of that month is used,
  -- so the whole difference for the month is suggested.
  q := public.fn_platform_plan_change_quote(v_s, 'growth', null);
  perform pg_temp.ok((q->>'suggested_charge')::numeric = 2000
                     and (q->>'days_left')::int = (q->>'days_in_period')::int,
    '68 the suggested charge is the difference, pro rata for the days left');

  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_change_plan(%L, 'growth', 'ok')$q$, v_s),
    'say why the school is moving'),
    '69 a move needs a reason');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_change_plan(%L, 'enterprise', 'They have grown a lot')$q$, v_s),
    'agree a monthly price'),
    '70 moving to Enterprise needs a price');

  update public.subscriptions set student_limit_override = 300, student_limit_override_until = current_date + 14,
         student_limit_override_reason = 'admissions season' where school_id = v_s;
  r := public.fn_platform_change_plan(v_s, 'growth', 'They asked to move up', 1000, null);
  select * into s from public.subscriptions where school_id = v_s;
  perform pg_temp.ok(s.plan_code = 'growth' and s.student_limit_override is null
                     and public.fn__student_limit(v_s) = 1000,
    '71 moved to Growth now: 1,000 pupils, and the extra room on Starter ends');
  perform pg_temp.ok((select purpose = 'plan_change' and amount = 1000 and due_on = current_date
                             and period_end = s.period_end
                        from public.platform_invoices where id = (r->>'invoice_id')::uuid),
    '72 the charge we chose is invoiced for the rest of the period, due today');
  perform pg_temp.ok(s.period_end = (current_date + 14 + interval '1 month')::date - 1,
    '73 and the paid period is not touched');
end $$;

-- =============================================================================
-- 11. EXTRA ROOM ENDS AT THE NEXT RENEWAL
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF Old Growth'); r jsonb;
begin
  perform pg_temp.as_op();
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_grant_student_limit(%L, 900, 'a big intake')$q$, v_s),
    'more than the 1000'),
    '74 extra room is more than the plan covers');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_grant_student_limit(%L, 1100, null)$q$, v_s),
    'say why'),
    '75 and says why');
  r := public.fn_platform_grant_student_limit(v_s, 1100, 'Merging with a branch in October');
  perform pg_temp.ok((r->>'until')::date = current_date + 13 and public.fn__student_limit(v_s) = 1100,
    '76 granted until the end of what covers the school today');
  update public.subscriptions set student_limit_override_until = current_date - 1 where school_id = v_s;
  perform pg_temp.ok(public.fn__student_limit(v_s) = 1000,
    '77 the day after, the plan''s own limit applies again');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_grant_student_limit(%L, 3000, 'they are big')$q$,
           pg_temp.sid('PF Big')),
    'no pupil limit'),
    '78 Enterprise has no limit to add room to');
  perform pg_temp.ok(public.plan_margin_limit(280) = 280,
    '79 there is no margin: the limit is the limit');
end $$;

-- =============================================================================
-- 12. THE SCHOOL CHOOSES HOW OFTEN IT PAYS
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('PF Six Term'); v_own uuid; r jsonb; v_inv uuid;
begin
  r := public.fn_signup_school_for_students('PF Six Term', null, null, null, null, null, 120, 1);
  v_s := (r->>'school_id')::uuid;
  v_own := pg_temp.owner_of(v_s, 'pfterm');
  perform set_config('test.uid', v_own::text, false);
  r := public.fn_my_request_invoice();
  v_inv := (r->>'invoice_id')::uuid;
  perform pg_temp.ok(not (r->>'already')::boolean,
    '80 a school in a fourteen-day trial is within thirty days, so it may ask for its invoice');
  perform pg_temp.ok((r->>'amount')::numeric = 2000, '81 it gets its first invoice, a month at Rs 2,000');
  r := public.fn_choose_term(12);
  perform pg_temp.ok((select voided_at is not null from public.platform_invoices where id = v_inv)
                     and (r->'invoice'->'raised'->>'amount')::numeric = 20000,
    '82 choosing a year reissues the unpaid invoice for the year');
  r := public.fn_my_request_invoice();
  perform pg_temp.ok((r->>'already')::boolean, '83 asking again returns the invoice already open');
end $$;

-- =============================================================================
-- 13. RENEWALS
-- =============================================================================
do $$
declare r jsonb; v_s uuid := pg_temp.sid('PF 280'); a jsonb;
begin
  perform pg_temp.as_op();
  -- Its paid three months end in three days.
  update public.platform_invoices set period_end = current_date + 3
   where school_id = v_s and purpose = 'term' and voided_at is null;
  perform public.fn__recompute_licence(v_s);
  r := public.fn_platform_run_renewals(true, current_date + 5);
  a := (select x from jsonb_array_elements(r->'attempts') x where x->>'school_id' = v_s::text);
  perform pg_temp.ok(a->>'outcome' = 'would_invoice' and (a->>'amount')::numeric = 5400,
    '84 the dry run quotes what the invoice will say');
  a := (select x from jsonb_array_elements(r->'attempts') x
         where x->>'school_id' = pg_temp.sid('PF 1000')::text);
  perform pg_temp.ok(a is null or a->>'outcome' <> 'invoiced', '85 the dry run raises nothing');

  r := public.fn_platform_run_renewals(false, current_date + 5);
  a := (select x from jsonb_array_elements(r->'attempts') x where x->>'school_id' = v_s::text);
  perform pg_temp.ok(a->>'outcome' = 'invoiced', '86 the live run invoices a paying school that is due');
  a := (select x from jsonb_array_elements(r->'attempts') x
         where x->>'school_id' = pg_temp.sid('PF Six Term')::text);
  perform pg_temp.ok(a is null, '87 a school with an invoice already open is not listed');
  perform pg_temp.ok((select count(*) from public.billing_attempts
                       where outcome = 'invoiced'
                         and school_id in (select school_id from public.subscriptions
                                            where status = 'trialing')) = 0,
    '88 a trial is never invoiced by the run');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_platform_run_renewals(false, current_date + 200)$q$, 'at most a month ahead'),
    '89 invoices are not raised more than a month ahead');
end $$;

-- =============================================================================
-- 14. NOTHING ANSWERS FOR ANOTHER SCHOOL; A LOCKED SCHOOL IS READ-ONLY
-- =============================================================================
do $$
declare v_s uuid; v_own uuid; v_class uuid; v_teacher uuid := md5('pf-teacher')::uuid; v_n integer;
begin
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.fn_count_students(uuid)', 'execute')
                 and not has_function_privilege('authenticated', 'public.fn_effective_status(uuid)', 'execute')
                 and not has_function_privilege('authenticated', 'public.fn_refresh_student_count(uuid)', 'execute')
                 and not has_function_privilege('authenticated', 'public.fn_refresh_all_student_counts()', 'execute'),
    '90 the four helpers that answered for any school are closed to signed-in users');
  perform pg_temp.ok(not has_table_privilege('authenticated', 'public.audit_log', 'truncate')
                 and not has_table_privilege('authenticated', 'public.operator_actions', 'delete'),
    '91 the logs cannot be emptied from the API');

  v_s := pg_temp.sid('PF 1000');
  insert into auth.users (id, email) values (v_teacher, 'teacher@paidfirst.test') on conflict do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, active)
  values (v_teacher, 'PF Teacher', 'class_teacher', v_s, true) on conflict (id) do nothing;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_teacher::text, false);
  set local role authenticated;
  select count(*) into v_n from public.subscriptions;
  reset role;
  perform pg_temp.ok(v_n = 0,
    '92 a teacher cannot read the school''s subscription, which holds its price');
  perform pg_temp.ok(pg_temp.raises($q$select public.fn_my_next_payment()$q$, 'owner or principal'),
    '93 nor its next payment');

  -- Locked: no new rows, and no deleting either.
  v_s := pg_temp.sid('PF Old Growth');
  v_own := pg_temp.owner_of(v_s, 'pfoldg');
  perform set_config('test.uid', v_own::text, false);
  insert into public.classes (name, level_order, school_id) values ('PF Class', 1, v_s)
    returning id into v_class;
  update public.subscriptions set trial_ends_on = current_date - 40 where school_id = v_s;
  perform pg_temp.ok(pg_temp.raises(
    $q$insert into public.classes (name, level_order) values ('PF Class 2', 2)$q$, 'subscription has ended'),
    '94 a locked school cannot add anything');
  perform pg_temp.ok(pg_temp.raises(
    format($q$delete from public.classes where id = %L$q$, v_class), 'subscription has ended'),
    '95 nor delete anything');
  perform pg_temp.ok(exists (select 1 from pg_trigger g join pg_class c on c.oid = g.tgrelid
                              where c.relname = 'attendance_subject'
                                and g.tgname = 'trg_attendance_subject_school'),
    '96 subject attendance is behind the same gate as the daily register');
  perform pg_temp.as_nobody();
end $$;

-- =============================================================================
-- 15. WHAT THE CONSOLE READS BESIDE ITS FIXED COLUMNS, AND THE ROLL AT RENEWAL
-- =============================================================================
do $$
declare v_big uuid; v_small uuid; v_own uuid; v_sess uuid; v_class uuid;
        r jsonb; x jsonb; v_inv uuid; v_s record; v_next date;
begin
  perform pg_temp.as_nobody();
  perform public.fn_signup_school_for_students('PF Readers Big', null, null, null, null, null, 1500, 1);
  perform public.fn_signup_school_for_students('PF Readers Small', null, null, null, null, null, 100, 1);
  v_big := pg_temp.sid('PF Readers Big');
  v_small := pg_temp.sid('PF Readers Small');

  perform pg_temp.as_op();
  r := public.fn_platform_school_billing_states();
  x := (select e from jsonb_array_elements(r) e where e->>'school_id' = v_big::text);
  perform pg_temp.ok((x->>'needs_price')::boolean and (x->>'in_trial')::boolean
                     and (x->>'trial_ends_on')::date = current_date + 13,
    '97 the school list marks an Enterprise school with no price, in its trial');
  x := (select e from jsonb_array_elements(r) e where e->>'school_id' = v_small::text);
  perform pg_temp.ok(not (x->>'needs_price')::boolean and (x->>'credit')::numeric = 0,
    '98 and a Starter school as priced, with no credit');

  r := public.fn_platform_raise_invoice(v_small, 1, null, null);
  v_inv := (r->>'invoice_id')::uuid;
  perform public.fn_platform_record_payment(v_small, 500, current_date, 'bank', 'PFR-1', v_inv, null, 0, null);
  x := (select e from jsonb_array_elements(public.fn_platform_invoice_states(v_small)) e
         where e->>'invoice_id' = v_inv::text);
  perform pg_temp.ok(x->>'purpose' = 'term' and (x->>'paid')::numeric = 500
                     and (x->>'owed')::numeric = 1500 and x->>'plan_name' = 'Starter',
    '99 the statement says what each invoice is for and what is still owed on it');

  v_own := pg_temp.owner_of(v_small, 'pfreaders');
  perform set_config('test.uid', v_own::text, false);
  perform pg_temp.ok(pg_temp.raises($q$select public.fn_platform_school_billing_states()$q$, 'not permitted')
                 and pg_temp.raises(format($q$select public.fn_platform_invoice_states(%L)$q$, v_small),
                                    'not permitted'),
    '100 a school owner reads neither');
  perform pg_temp.as_nobody();

  -- 290 enrolled pupils on Starter's 280.
  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_small, '2026', current_date - 60, current_date + 300, true) returning id into v_sess;
  insert into public.classes (school_id, name, level_order) values (v_small, 'One', 1)
    returning id into v_class;
  with ins as (
    insert into public.students (school_id, full_name, father_name, status)
    select v_small, 'PFR Child ' || g, 'F', 'active' from generate_series(1, 290) g
    returning id, full_name
  )
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
  select v_small, ins.id, v_sess, v_class, ins.full_name, 'active' from ins;

  -- Its next period starts the day after its trial ends: nothing is paid in full yet.
  select * into v_s from public.subscriptions where school_id = v_small;
  v_next := coalesce(v_s.period_end, v_s.trial_ends_on) + 1;
  perform pg_temp.ok(public.fn__over_limit_for_period(v_small, v_next)
                       like '%290 pupils and Starter covers 280%Growth%',
    '101 at renewal a roll over the limit is a decision for us, and says which plan fits');
  update public.subscriptions set student_limit_override = 300,
         student_limit_override_reason = 'A branch joining',
         student_limit_override_until = v_next where school_id = v_small;
  perform pg_temp.ok(public.fn__over_limit_for_period(v_small, v_next) is null,
    '102 extra room that reaches the new period counts');
  update public.subscriptions set student_limit_override_until = v_next - 1 where school_id = v_small;
  perform pg_temp.ok(public.fn__over_limit_for_period(v_small, v_next) is not null,
    '103 extra room that ends before it does not');
  perform pg_temp.ok(public.fn__over_limit_for_period(v_big, current_date) is null,
    '104 Enterprise has no limit to be over');
  perform pg_temp.as_op();
  perform public.fn_platform_record_payment(v_small, 1500, current_date, 'bank', 'PFR-2', v_inv, null, 0, null);
  select * into v_s from public.subscriptions where school_id = v_small;
  perform pg_temp.ok(v_s.period_end is not null
                     and v_s.grace_ends_on = greatest(v_s.period_end, v_s.trial_ends_on) + 14,
    '105 the table''s own grace date follows what is paid, so the Supabase editor tells the truth');
  perform pg_temp.as_nobody();
end $$;

rollback;
