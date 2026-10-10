-- =============================================================================
-- Discount codes that keep their word (0156).
--
-- Every rule below was broken before 0156, most of them found by trying:
--
--   1. A code is counted in billed months: a one-month code takes its share of
--      one month whatever the invoice length, and reaches exactly one monthly
--      invoice. Flat codes are rupees off each month they cover.
--   2. The plan and term a code is for are checked on every invoice, not only
--      when it was typed in.
--   3. A seat is taken under a lock; a seat dropped before any saving is given
--      back; "Start again" does not free a code to be used twice.
--   4. A voided invoice gives back the months its code used. A price typed by
--      hand uses the code up.
--   5. Replacing a discount needs a yes; a discount we gave is ours to change;
--      a code that would save nothing is not spent.
--   6. Schools see a label, never our description. Unknown, switched-off,
--      used-up and another school's codes get one sentence. Ten refused tries
--      in an hour pause the school. Every event is logged and the log cannot
--      be changed.
--   7. Create never overwrites, edit needs the version it started from, and a
--      used code's money terms are locked.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/discount_codes_keep_their_word.sql
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

create or replace function pg_temp.as_op() returns void language sql as $$
  select set_config('test.uid', '00000000-0000-0000-0000-0000000156f0', false);
$$;

-- A school on a plan and term, in a paid period, with an owner who is signed in
-- when pg_temp.as_owner is called.
create or replace function pg_temp.school(p_name text, p_plan text, p_term integer) returns uuid
language plpgsql as $$
declare v uuid; v_own uuid := md5('dc-owner-' || p_name)::uuid;
begin
  insert into public.schools (name) values (p_name) returning id into v;
  insert into public.subscriptions (school_id, plan_code, status, term_months, cycle,
                                    trial_ends_on, period_start, period_end)
  values (v, p_plan, 'active', p_term, public.fn__cycle_for_months(p_term),
          current_date - 30, current_date - 20, current_date + 5);
  insert into auth.users (id, email) values (v_own, md5(p_name) || '@dc.test')
    on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, active)
  values (v_own, 'Owner ' || p_name, 'owner', v, true)
  on conflict (id) do update set school_id = excluded.school_id;
  alter table public.profiles enable trigger user;
  return v;
end;
$$;

create or replace function pg_temp.as_owner(p_school uuid) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where school_id = p_school and role = 'owner' limit 1), false);
$$;

create or replace function pg_temp.sid(p_name text) returns uuid language sql as $$
  select id from public.schools where name = p_name;
$$;

create or replace function pg_temp.code(p jsonb) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_op();
  return public.fn_platform_create_discount(p);
end;
$$;

-- The next term invoice for a school, raised by us, with its quote.
create or replace function pg_temp.invoice(p_school uuid, p_months integer) returns jsonb
language plpgsql as $$
begin
  perform pg_temp.as_op();
  return public.fn_platform_raise_invoice(p_school, p_months, null, null);
end;
$$;

-- Pay an invoice in full so the next one can be raised.
create or replace function pg_temp.pay(p_school uuid, p_inv jsonb) returns void
language plpgsql as $$
begin
  perform pg_temp.as_op();
  if (p_inv->>'owed')::numeric > 0 then
    perform public.fn_platform_record_payment(p_school, (p_inv->>'owed')::numeric, current_date,
      'bank', 'T-' || (p_inv->>'doc_no'), (p_inv->>'invoice_id')::uuid, null, 0, null);
  end if;
end;
$$;

do $seed$
begin
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000156f0', 'op@dc.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email, note)
  values ('00000000-0000-0000-0000-0000000156f0', 'op@dc.test', 'Founder')
  on conflict (user_id) do nothing;
  perform pg_temp.school('DC Monthly', 'starter', 1);
  perform pg_temp.school('DC Yearly', 'growth', 12);
  perform pg_temp.school('DC Quarter', 'starter', 3);
  perform pg_temp.school('DC Switch', 'growth', 12);
  perform pg_temp.school('DC Seat A', 'starter', 1);
  perform pg_temp.school('DC Seat B', 'starter', 1);
  perform pg_temp.school('DC Guess', 'starter', 1);
  perform pg_temp.school('DC Ours', 'starter', 1);
  perform pg_temp.school('DC Big', 'enterprise', 1);
end $seed$;

-- =============================================================================
-- 1. MAKING A CODE
-- =============================================================================
do $$
declare r jsonb;
begin
  r := pg_temp.code('{"code":"half month","label":"Half off a month","description":"Expo stand offer","kind":"percent","value":50,"duration":"months","duration_months":1}');
  perform pg_temp.ok(r->>'code' = 'HALFMONTH', '1  a code typed with a space is the same code, in capitals');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.code('{"code":"HALFMONTH","label":"x","description":"y","kind":"percent","value":10,"duration":"forever"}')$q$,
    'already exists'), '2  creating a code that exists is refused, never an overwrite');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.code('{"code":"AB1","label":"x","description":"y","kind":"percent","value":10,"duration":"forever"}')$q$,
    '6 to 32'), '3  a short code is refused: they get guessed');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.code('{"code":"NOLABEL1","description":"y","kind":"percent","value":10,"duration":"forever"}')$q$,
    'label'), '4  a code needs a label the school sees');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.code('{"code":"TRIAL45D","label":"x","description":"y","kind":"trial_days","value":45}')$q$,
    '1 to 30 days'), '5  a trial is extended by at most 30 days');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.code('{"code":"FREEFOREVER","label":"x","description":"y","kind":"percent","value":100,"duration":"forever"}')$q$,
    'private to one school'), '6  a free-for-ever code cannot be public');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.code('{"code":"SIXMONTHMIN","label":"x","description":"y","kind":"percent","value":10,"duration":"forever","min_term_months":6}')$q$,
    'three months or a year'), '7  a minimum term is a term we sell');
  perform pg_temp.ok(pg_temp.raises(
    $q$select pg_temp.code('{"code":"BADPLANS1","label":"x","description":"y","kind":"percent","value":10,"duration":"forever","plan_codes":["institution"]}')$q$,
    'not a plan on sale'), '8  a code cannot be for a retired plan');

  perform pg_temp.code('{"code":"TWENTYOFF","label":"Twenty off","description":"Partner referral","kind":"percent","value":20,"duration":"forever"}');
  perform pg_temp.code('{"code":"TENFORTHREE","label":"Ten for three","description":"Winter","kind":"percent","value":10,"duration":"months","duration_months":3}');
  perform pg_temp.code('{"code":"FLAT500X3","label":"Rs 500 off","description":"Flat","kind":"flat","value":500,"duration":"months","duration_months":3}');
  perform pg_temp.code('{"code":"GROWTHONLY","label":"Growth special","description":"Growth","kind":"percent","value":25,"duration":"forever","plan_codes":["growth"]}');
  perform pg_temp.code('{"code":"YEARLYONLY","label":"Pay yearly","description":"Yearly","kind":"percent","value":15,"duration":"forever","min_term_months":12}');
  perform pg_temp.code('{"code":"ONESEAT","label":"First school","description":"One school only","kind":"percent","value":30,"duration":"forever","max_redemptions":1}');
  perform pg_temp.code('{"code":"TRIAL10D","label":"Ten more days","description":"Trial","kind":"trial_days","value":10}');
  perform pg_temp.code('{"code":"OLDOFFER1","label":"Old","description":"switched off","kind":"percent","value":10,"duration":"forever","active":false}');
  perform pg_temp.ok((select fn__discount_sentence('percent', 20, 'forever', null, null))
                     = '20% off, for as long as you subscribe',
    '9  twenty per cent reads as 20% off (it used to read 2%)');
end $$;

-- =============================================================================
-- 2. BILLED MONTHS
-- =============================================================================
do $$
declare v_m uuid := pg_temp.sid('DC Monthly'); v_y uuid := pg_temp.sid('DC Yearly');
  v_q uuid := pg_temp.sid('DC Quarter'); r jsonb; i jsonb;
begin
  -- One month at half price on a yearly Growth invoice: half of one month.
  perform pg_temp.as_owner(v_y);
  r := public.fn_my_redeem_code('halfmonth', false);
  perform pg_temp.ok((r->>'ok')::boolean, '10 a school redeems a one-month code');
  i := pg_temp.invoice(v_y, 12);
  perform pg_temp.ok((i->>'amount')::numeric = 40000 - round(40000 / 12.0 * 0.5),
    '11 on a year it takes half of ONE month (Rs 1,667), not half the year');
  perform pg_temp.ok((select months_left from public.subscription_discounts
                       where school_id = v_y and code = 'HALFMONTH') = 0,
    '12 and the month is used');

  -- Ten per cent for three months on a monthly Starter: three invoices, not four.
  perform pg_temp.as_owner(v_m);
  perform public.fn_my_redeem_code('TENFORTHREE', false);
  i := pg_temp.invoice(v_m, 1);
  perform pg_temp.ok((i->>'amount')::numeric = 1800, '13 first month: Rs 1,800');
  perform pg_temp.pay(v_m, i);
  i := pg_temp.invoice(v_m, 1); perform pg_temp.pay(v_m, i);
  i := pg_temp.invoice(v_m, 1);
  perform pg_temp.ok((i->>'amount')::numeric = 1800, '14 third month: still Rs 1,800');
  perform pg_temp.pay(v_m, i);
  i := pg_temp.invoice(v_m, 1);
  perform pg_temp.ok((i->>'amount')::numeric = 2000, '15 fourth month: full price, the code is spent');

  -- Rs 500 a month for three months on a quarter: Rs 1,500 off the quarter.
  perform pg_temp.as_owner(v_q);
  perform public.fn_my_redeem_code('FLAT500X3', false);
  i := pg_temp.invoice(v_q, 3);
  perform pg_temp.ok((i->>'amount')::numeric = 5400 - 1500,
    '16 a flat code is rupees off each month it covers: Rs 1,500 off three months');
  perform pg_temp.ok((i->>'amount')::numeric = round((i->>'amount')::numeric),
    '17 and invoices stay in whole rupees');
end $$;

-- =============================================================================
-- 3. THE RULES ARE CHECKED ON EVERY INVOICE
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('DC Switch'); r jsonb; i jsonb;
begin
  perform pg_temp.as_owner(v_s);
  r := public.fn_my_redeem_code('YEARLYONLY', false);
  perform pg_temp.ok((r->>'ok')::boolean, '18 a yearly school redeems a yearly-only code');
  perform public.fn_choose_term(1);
  i := pg_temp.invoice(v_s, 1);
  perform pg_temp.ok((i->>'amount')::numeric = 4000 and coalesce(i->>'discount_code', '') = '',
    '19 switched to monthly, the invoice is full price');
  perform pg_temp.ok((select note from public.platform_invoices where id = (i->>'invoice_id')::uuid)
                       like '%12 months or more%',
    '20 and the invoice says why the code did not apply');
end $$;

do $$
declare v_s uuid := pg_temp.sid('DC Yearly'); r jsonb; q jsonb;
begin
  -- A Growth-only code, then the school is moved to Starter.
  perform pg_temp.as_op();
  update public.subscription_discounts set removed_at = now(), removed_reason = 'test reset'
   where school_id = v_s and removed_at is null;
  perform pg_temp.as_owner(v_s);
  r := public.fn_my_redeem_code('GROWTHONLY', false);
  perform pg_temp.ok((r->>'ok')::boolean, '21 a Growth school redeems a Growth-only code');
  perform pg_temp.as_op();
  update public.subscriptions set plan_code = 'starter' where school_id = v_s;
  q := public.fn__quote(v_s, 'starter', 12, current_date);
  perform pg_temp.ok((q->>'discount_amount')::numeric = 0 and q->>'discount_note' like '%is for Growth%',
    '22 on Starter it does not come off, and the quote says why');
  update public.subscriptions set plan_code = 'growth' where school_id = v_s;
end $$;

-- =============================================================================
-- 4. SEATS, AND "START AGAIN"
-- =============================================================================
do $$
declare v_a uuid := pg_temp.sid('DC Seat A'); v_b uuid := pg_temp.sid('DC Seat B'); r jsonb;
  v_t uuid; v_tr jsonb;
begin
  perform pg_temp.as_owner(v_a);
  r := public.fn_my_redeem_code('ONESEAT', false);
  perform pg_temp.ok((r->>'ok')::boolean, '23 the first school takes the one seat');
  perform pg_temp.as_owner(v_b);
  r := public.fn_my_redeem_code('ONESEAT', false);
  perform pg_temp.ok(not (r->>'ok')::boolean
                     and r->>'reason' = 'That code is not one we can apply for your school. Check it, or ask us.',
    '24 the second is refused with the same sentence as an unknown code');
  perform pg_temp.as_owner(v_a);
  perform public.fn_my_remove_discount();
  perform pg_temp.as_owner(v_b);
  r := public.fn_my_redeem_code('ONESEAT', false);
  perform pg_temp.ok((r->>'ok')::boolean,
    '25 dropped before it saved anything, the seat goes back');
  perform pg_temp.as_owner(v_a);
  r := public.fn_my_redeem_code('ONESEAT', false);
  perform pg_temp.ok(not (r->>'ok')::boolean, '26 and the first school cannot take it again');

  -- A trial school extends its trial, starts again, and tries once more.
  perform set_config('test.uid', '', false);
  v_tr := public.fn_signup_school_for_students('DC Trial', null, null, null, null, null, 50, 1);
  v_t := (v_tr->>'school_id')::uuid;
  insert into auth.users (id, email) values (md5('dc-trial')::uuid, 'trial@dc.test') on conflict do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, active)
  values (md5('dc-trial')::uuid, 'Owner DC Trial', 'owner', v_t, true) on conflict (id) do nothing;
  alter table public.profiles enable trigger user;
  perform pg_temp.as_owner(v_t);
  r := public.fn_my_redeem_code('TRIAL10D', false);
  perform pg_temp.ok((r->>'trial_ends_on')::date = current_date + 23,
    '27 a trial code adds its days to the trial');
  perform pg_temp.ok((select count(*) from public.subscription_discounts
                       where school_id = v_t and kind <> 'trial_days' and removed_at is null) = 0,
    '28 and does not take the money-discount slot');
  perform public.fn_reset_school_data('DC Trial');
  r := public.fn_my_redeem_code('TRIAL10D', false);
  perform pg_temp.ok(not (r->>'ok')::boolean and r->>'reason' like '%used that code%',
    '29 after "Start again" the same code is still used: no endless trial');
  perform pg_temp.ok((select trial_ends_on from public.subscriptions where school_id = v_t)
                       = current_date + 23,
    '30 and the trial is where the one code put it');
end $$;

-- =============================================================================
-- 5. A VOID GIVES IT BACK; A TYPED PRICE USES IT UP
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('DC Guess'); r jsonb; i jsonb;
begin
  perform pg_temp.as_op();
  perform pg_temp.code('{"code":"ONEMONTH40","label":"Forty off a month","description":"void test","kind":"percent","value":40,"duration":"months","duration_months":1}');
  perform pg_temp.as_owner(v_s);
  perform public.fn_my_redeem_code('ONEMONTH40', false);
  i := pg_temp.invoice(v_s, 1);
  perform pg_temp.ok((i->>'amount')::numeric = 1200, '31 the month is invoiced at Rs 1,200');
  perform pg_temp.as_op();
  perform public.fn_platform_void_invoice((i->>'invoice_id')::uuid, 'raised by mistake');
  perform pg_temp.ok((select months_left from public.subscription_discounts
                       where school_id = v_s and code = 'ONEMONTH40') = 1,
    '32 voiding it gives the month back');
  perform pg_temp.ok((select reversed_at is not null from public.discount_applications
                       where invoice_id = (i->>'invoice_id')::uuid),
    '33 and the use is marked reversed against that invoice');
  i := public.fn_platform_raise_invoice(v_s, 1, 1500, 'Agreed on the phone');
  perform pg_temp.ok((select months_left from public.subscription_discounts
                       where school_id = v_s and code = 'ONEMONTH40') = 0
                     and (select overridden from public.discount_applications
                           where invoice_id = (i->>'invoice_id')::uuid),
    '34 a price we type by hand uses the code up, so it cannot come off again');
end $$;

-- =============================================================================
-- 6. REPLACING, AND WHAT IS OURS
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('DC Ours'); r jsonb; v_priv jsonb;
begin
  perform pg_temp.as_owner(v_s);
  perform public.fn_my_redeem_code('TWENTYOFF', false);
  r := public.fn_my_redeem_code('TENFORTHREE', false);
  perform pg_temp.ok(not (r->>'ok')::boolean and (r->>'needs_replace')::boolean,
    '35 a second code needs a yes before it replaces the first');
  perform pg_temp.ok(r->'preview'->'replaces'->>'code' = 'TWENTYOFF',
    '36 and the answer shows what it would replace');

  perform pg_temp.as_op();
  v_priv := public.fn_platform_create_discount(jsonb_build_object(
    'label', 'Loyalty', 'description', 'Matched a rival quote after a call',
    'kind', 'percent', 'value', 35, 'duration', 'forever',
    'private', true, 'school_id', v_s));
  perform pg_temp.ok(length(v_priv->>'code') = 10, '37 a private code is made up for us, ten characters');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_grant_discount(%L, %L, 'x')$q$, v_s, v_priv->>'code'),
    'say why'), '38 giving a code needs a reason');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_grant_discount(%L, %L, 'Matched their quote')$q$, v_s, v_priv->>'code'),
    'replace it on purpose'), '39 and replacing a live one needs a yes from us too');
  r := public.fn_platform_grant_discount(v_s, v_priv->>'code', 'Matched their quote', true);
  perform pg_temp.ok((select granted_by_kind from public.subscription_discounts
                       where id = (r->>'redemption_id')::uuid) = 'platform',
    '40 given by us');

  perform pg_temp.as_owner(v_s);
  r := public.fn_my_redeem_code('TENFORTHREE', true);
  perform pg_temp.ok(not (r->>'ok')::boolean and r->>'reason' like '%arranged with us%',
    '41 the school cannot replace a discount we gave');
  perform pg_temp.ok(pg_temp.raises($q$select public.fn_my_remove_discount()$q$, 'arranged with us'),
    '42 nor take it off');
  r := public.fn_my_discount();
  perform pg_temp.ok(r->>'label' = 'Loyalty' and r::text not like '%rival quote%',
    '43 the school sees the label, never our description');
  r := public.fn_preview_discount(v_priv->>'code', null, null);
  perform pg_temp.ok(not (r->>'ok')::boolean and (r->>'already_yours')::boolean,
    '44 previewing its own code says it is already on');

  perform pg_temp.as_owner(pg_temp.sid('DC Seat A'));
  r := public.fn_preview_discount(v_priv->>'code', null, null);
  perform pg_temp.ok(r->>'reason' = 'That code is not one we can apply for your school. Check it, or ask us.',
    '45 another school typing it learns nothing');
  r := public.fn_preview_discount('OLDOFFER1', null, null);
  perform pg_temp.ok(r->>'reason' = 'That code is not one we can apply for your school. Check it, or ask us.',
    '46 nor does typing a switched-off one');

  perform pg_temp.as_op();
  perform public.fn_platform_remove_discount(v_s, 'They moved to annual pricing');
  r := public.fn_platform_grant_discount(v_s, v_priv->>'code', 'Back on after the review', false);
  perform pg_temp.ok((r->>'restored')::boolean, '47 a discount we took off can be restored');
end $$;

-- =============================================================================
-- 7. GUESSING, AND THE LOG
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('DC Guess'); r jsonb; k integer;
begin
  perform pg_temp.as_owner(v_s);
  for k in 1..10 loop
    r := public.fn_preview_discount('GUESS' || k::text || 'X', null, null);
  end loop;
  r := public.fn_preview_discount('TWENTYOFF', null, null);
  perform pg_temp.ok(not (r->>'ok')::boolean and r->>'reason' like 'Too many codes%',
    '48 ten wrong guesses in an hour and even a good code waits');
  perform pg_temp.ok((select count(*) from public.discount_events
                       where school_id = v_s and event = 'refused') >= 10,
    '49 every refused try is logged');
  perform pg_temp.ok(pg_temp.raises(
    $q$update public.discount_events set reason = 'nothing to see' where true$q$, 'append-only'),
    '50 and the log cannot be changed');
  perform pg_temp.ok(pg_temp.raises(
    $q$delete from public.discount_events$q$, 'append-only'),
    '51 or emptied');
end $$;

-- =============================================================================
-- 8. EDITING A USED CODE
-- =============================================================================
do $$
declare c record; r jsonb;
begin
  perform pg_temp.as_op();
  select * into c from public.discount_codes where code = 'TWENTYOFF';
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_platform_edit_discount('TWENTYOFF', '{"label":"x"}', now() - interval '1 day')$q$,
    'changed'), '52 an edit made from an old copy is refused');
  perform pg_temp.ok(pg_temp.raises(
    format($q$select public.fn_platform_edit_discount('TWENTYOFF', '{"value":50}', %L::timestamptz)$q$, c.updated_at),
    'locked'), '53 a used code''s money terms cannot change');
  r := public.fn_platform_edit_discount('TWENTYOFF', '{"label":"Twenty per cent"}', c.updated_at);
  perform pg_temp.ok(r->>'label' = 'Twenty per cent', '54 its label can');
  perform pg_temp.ok((select before->>'label' = 'Twenty off' and after->>'label' = 'Twenty per cent'
                        from public.discount_events where code = 'TWENTYOFF' and event = 'edited'
                       order by at desc limit 1),
    '55 and the edit is logged with before and after');
  perform pg_temp.ok(pg_temp.raises(
    $q$select public.fn_platform_delete_discount('TWENTYOFF')$q$, 'retire it instead'),
    '56 a used code cannot be deleted');
end $$;

-- =============================================================================
-- 9. ENTERPRISE, AND WHO MAY READ
-- =============================================================================
do $$
declare v_s uuid := pg_temp.sid('DC Big'); i jsonb; v_t uuid := md5('dc-teacher')::uuid;
begin
  perform pg_temp.as_op();
  perform public.fn_platform_set_price(v_s, 10000, null, null, 'Agreed for 3,000 pupils');
  perform pg_temp.as_owner(v_s);
  perform public.fn_my_redeem_code('TWENTYOFF', false);
  i := pg_temp.invoice(v_s, 1);
  perform pg_temp.ok((i->>'amount')::numeric = 8000,
    '57 a code comes off an agreed Enterprise price as off any other');

  insert into auth.users (id, email) values (v_t, 't@dc.test') on conflict do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, active)
  values (v_t, 'DC Teacher', 'class_teacher', v_s, true) on conflict (id) do nothing;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_t::text, false);
  perform pg_temp.ok(pg_temp.raises($q$select public.fn_my_discount()$q$, 'not permitted'),
    '58 a teacher cannot read the school''s discount');
  perform pg_temp.ok(not has_function_privilege('authenticated',
      'public.fn__discount_calc(text,text,numeric,text,integer,date,text[],integer,text,integer,date,numeric)', 'execute'),
    '59 the arithmetic is not callable from a browser');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'public.fn_my_apply_discount(text)', 'execute'),
    '60 nor is the old redeem, whose raised refusal would roll back the log of the guess');
end $$;

rollback;
