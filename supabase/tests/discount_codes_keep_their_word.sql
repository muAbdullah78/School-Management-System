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
--   8. What an adversarial review found (61 onwards): an old "months" code
--      whose window closed stays spent; a flat code takes no more than its
--      months cost; a price we typed stays used whatever the school does;
--      taking a code off takes it off the unpaid invoice; a discount whose
--      months sit on that invoice is still live; the school is never told an
--      invoice was reissued when it was not; the old console never edits; a
--      restore counts seats; every refused try is logged; a purged school's
--      log is history, not debris; a code free for years is private; a typed
--      price is not booked as the code's saving.
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

-- =============================================================================
-- 10. WHAT AN ADVERSARIAL REVIEW FOUND
-- =============================================================================

-- An old "months" code was a calendar window (0131). Written that way, with no
-- months_left, then counted the 0156 way.
do $$
declare v_never uuid; v_year uuid; v_run uuid;
begin
  perform pg_temp.code('{"code":"WINTER50X","label":"Winter","description":"3 months at half price","kind":"percent","value":50,"duration":"months","duration_months":3}');
  v_never := pg_temp.school('DC Legacy Never', 'starter', 1);
  v_year  := pg_temp.school('DC Legacy Year', 'starter', 12);
  v_run   := pg_temp.school('DC Legacy Running', 'starter', 1);
  insert into public.subscription_discounts
    (school_id, code, kind, value, duration, ends_on, times_applied, total_saved, redeemed_at, months_total)
  values (v_never, 'WINTER50X', 'percent', 50, 'months', current_date - 180, 0, 0, now() - interval '9 months', 3),
         (v_year,  'WINTER50X', 'percent', 50, 'months', current_date - 180, 1, 10000, now() - interval '9 months', 3),
         (v_run,   'WINTER50X', 'percent', 50, 'months', current_date + 40, 0, 0, now() - interval '50 days', 3);
  perform public.fn__discount_months_from_windows();

  perform pg_temp.ok((select months_left = 0 and removed_reason = 'Ran its course'
                        from public.subscription_discounts where school_id = v_never)
                     and exists (select 1 from public.discount_events
                                  where school_id = v_never and event = 'removed' and code = 'WINTER50X')
                     and (public.fn__quote(v_never, 'starter', 1, public.fn__next_period_start(v_never))
                            ->>'discount_amount')::numeric = 0,
    '61 an old months code whose window closed is spent and closed, with a line in the log');
  perform pg_temp.ok((select months_left from public.subscription_discounts where school_id = v_year) = 0
                     and (select id from public.fn__discount_live(v_year, null)) is null,
    '62 one used on a whole year under the old rules does not get two months back');
  perform pg_temp.ok((select months_left from public.subscription_discounts where school_id = v_run) = 2
                     and (select code from public.fn__discount_live(v_run, null)) = 'WINTER50X',
    '63 a window still running keeps only the billed months that start inside it (2, not 3)');
end $$;

-- A flat code takes off at most what the months it covers cost.
do $$
begin
  perform pg_temp.ok(
    (public.fn__discount_calc('FREEMONTH4K', 'flat', 4000, 'months', 1, null, null, null,
                              'starter', 12, current_date, 20000)->>'amount')::numeric = 1667
    and (public.fn__discount_calc('FLAT5000X3', 'flat', 5000, 'months', 3, null, null, null,
                                  'starter', 12, current_date, 20000)->>'amount')::numeric = 5000
    and (public.fn__discount_calc('FLAT5000X3', 'flat', 5000, 'months', 3, null, null, null,
                                  'starter', 1, current_date, 2000)->>'amount')::numeric = 2000,
    '64 Rs 4,000 off one month takes Rs 1,667 off a Starter year, and Rs 5,000 x 3 takes Rs 5,000, not Rs 15,000');
end $$;

-- A price we typed by hand used the code up. Nothing the school does gives it back.
do $$
declare v uuid; v_l uuid; i jsonb; r jsonb;
begin
  perform pg_temp.as_op();
  v := pg_temp.school('DC Hand', 'starter', 1);
  perform pg_temp.as_owner(v);
  perform public.fn_my_redeem_code('ONEMONTH40', false);
  perform pg_temp.as_op();
  i := public.fn_platform_raise_invoice(v, 1, 2000, 'Full price this month: code held back by agreement');
  perform pg_temp.as_owner(v);
  perform public.fn_choose_term(3);
  perform public.fn_choose_term(1);
  perform pg_temp.ok((select months_left from public.subscription_discounts
                       where school_id = v and code = 'ONEMONTH40') = 0
                     and not exists (select 1 from public.platform_invoices
                                      where school_id = v and voided_at is null and discount_amount > 0),
    '65 a school switching term and back does not get back a code our typed price used up');

  perform pg_temp.as_op();
  v_l := pg_temp.school('DC Hand Lapse', 'starter', 1);
  perform pg_temp.as_owner(v_l);
  perform public.fn_my_redeem_code('ONEMONTH40', false);
  perform pg_temp.as_op();
  i := public.fn_platform_raise_invoice(v_l, 1, 2000, 'Full price this month: code held back by agreement');
  -- Its due date and grace pass unpaid: it lapses.
  update public.platform_invoices set due_on = current_date - 30 where id = (i->>'invoice_id')::uuid;
  perform pg_temp.as_owner(v_l);
  r := public.fn_my_request_invoice();
  perform pg_temp.ok(coalesce((r->>'discount_amount')::numeric, 0) = 0
                     and (select voided_at is not null from public.platform_invoices
                           where id = (i->>'invoice_id')::uuid)
                     and (select months_left from public.subscription_discounts
                           where school_id = v_l and code = 'ONEMONTH40') = 0,
    '66 nor does one that lets our typed-price invoice lapse and comes back');
end $$;

-- Taking a code off takes it off the unpaid invoice too.
do $$
declare v uuid; i jsonb; r jsonb;
begin
  perform pg_temp.code('{"code":"HALFYEARX","label":"Half off","description":"expo offer","kind":"percent","value":50,"duration":"forever"}');
  v := pg_temp.school('DC Remove', 'starter', 12);
  perform public.fn_platform_grant_discount(v, 'HALFYEARX', 'Promised at the expo', false);
  i := pg_temp.invoice(v, 12);
  perform pg_temp.ok((i->>'amount')::numeric = 10000, '67 the year is invoiced at half price');
  r := public.fn_platform_remove_discount(v, 'Given to the wrong school by mistake');
  perform pg_temp.ok((select amount from public.platform_invoices
                       where school_id = v and voided_at is null and kind = 'invoice') = 20000
                     and (select reversed_at is not null from public.discount_applications
                           where invoice_id = (i->>'invoice_id')::uuid)
                     and r->>'invoice_note' like '%reissued%without the code%',
    '68 removing it reissues the unpaid invoice at full price and says so');
end $$;

-- A discount still has value while its months sit on the unpaid invoice, or
-- its end date is on or after the next month the school would be billed for.
do $$
declare v uuid; v_u uuid; v_priv jsonb; i jsonb; r jsonb;
begin
  perform pg_temp.as_op();
  v := pg_temp.school('DC Outage', 'starter', 12);
  v_priv := public.fn_platform_create_discount(jsonb_build_object(
    'code', 'OUTAGE3MX', 'label', 'Loyalty', 'description', '3 months at half price after the outage',
    'kind', 'percent', 'value', 50, 'duration', 'months', 'duration_months', 3,
    'private', true, 'school_id', v));
  perform public.fn_platform_grant_discount(v, 'OUTAGE3MX', 'Outage compensation agreed by phone', false);
  i := pg_temp.invoice(v, 12);
  perform pg_temp.as_owner(v);
  r := public.fn_my_discount();
  perform pg_temp.ok(r->>'code' = 'OUTAGE3MX' and r->>'summary' like '%3 months%',
    '69 a discount whose months all sit on the unpaid invoice is still shown to the school, as 3 months');
  r := public.fn_my_redeem_code('TWENTYOFF', false);
  perform pg_temp.ok(not (r->>'ok')::boolean and r->>'reason' like '%arranged with us%'
                     and (select removed_at is null from public.subscription_discounts
                           where school_id = v and code = 'OUTAGE3MX')
                     and (select amount from public.platform_invoices
                           where id = (i->>'invoice_id')::uuid and voided_at is null) = 17500,
    '70 and it stays ours: the school cannot replace it, and the invoice keeps it');

  perform pg_temp.as_op();
  perform pg_temp.code(format('{"code":"WINTERFREEX","label":"Free until mid-term","description":"x","kind":"percent","value":100,"duration":"until","duration_until":"%s"}',
                              current_date + 10)::jsonb);
  v_u := pg_temp.school('DC Until', 'starter', 1);
  perform public.fn_platform_grant_discount(v_u, 'WINTERFREEX', 'Compensation for the outage', false);
  -- Twelve days pass: the school is in grace, its end date is behind it, and
  -- its next month still starts before the code's end.
  update public.subscriptions set period_start = period_start - 12, period_end = period_end - 12,
         trial_ends_on = trial_ends_on - 12 where school_id = v_u;
  update public.subscription_discounts set ends_on = ends_on - 12 where school_id = v_u;
  perform pg_temp.as_owner(v_u);
  perform pg_temp.ok(public.fn_my_discount()->>'code' = 'WINTERFREEX',
    '71 a dated discount still due on the next month is shown to the school');
  perform pg_temp.as_op();
  perform pg_temp.ok((public.fn_platform_remove_discount(v_u, 'Changed our mind')->>'removed')::boolean,
    '72 and we can take it off');
end $$;

-- DC Monthly's three-month code is spent and paid for. Redeeming another
-- closes it, and the closing is logged with what it had left.
do $$
declare v_m uuid; r jsonb;
begin
  v_m := pg_temp.sid('DC Monthly');
  perform pg_temp.as_owner(v_m);
  r := public.fn_my_redeem_code('TWENTYOFF', false);
  perform pg_temp.ok((r->>'ok')::boolean
                     and exists (select 1 from public.discount_events
                                  where school_id = v_m and code = 'TENFORTHREE' and event = 'removed'
                                    and reason = 'Ran its course' and before ? 'months_left'),
    '73 a code that ran its course is closed with a line in the log, months left and all');
end $$;

-- The old console never edits.
do $$
begin
  perform pg_temp.code('{"code":"LAUNCH50X","label":"Launch offer","description":"First school only","kind":"percent","value":50,"duration":"forever","max_redemptions":1}');
  perform public.fn_platform_retire_discount('LAUNCH50X', 'Launch is over');
  perform pg_temp.ok(pg_temp.raises(
      $q$select public.fn_platform_save_discount('LAUNCH50X', 'Launch offer for partners', 'percent', 50, 'forever')$q$,
      'Discounts page')
    and (select not active and max_redemptions = 1 from public.discount_codes where code = 'LAUNCH50X'),
    '74 saving an existing code from the old console is refused: a retired one-seat code stays retired, one seat');
  perform pg_temp.code('{"code":"SUMMER26X","label":"Summer","description":"10% for three months","kind":"percent","value":10,"duration":"months","duration_months":3}');
  perform pg_temp.ok(pg_temp.raises(
      $q$select public.fn_platform_save_discount('SUMMER26X', 'my summer code', 'percent', 60, 'forever')$q$,
      'already exists')
    and (select value = 10 and duration = 'months' from public.discount_codes where code = 'SUMMER26X'),
    '75 and an unused code is not rewritten by a second "New code" form');
end $$;

-- A restore counts seats.
do $$
declare v_a uuid; v_b uuid;
begin
  perform pg_temp.code('{"code":"ONESEATY","label":"First school","description":"one school only","kind":"percent","value":30,"duration":"forever","max_redemptions":1}');
  v_a := pg_temp.school('DC Restore A', 'starter', 1);
  v_b := pg_temp.school('DC Restore B', 'starter', 1);
  perform pg_temp.as_owner(v_a);
  perform public.fn_my_redeem_code('ONESEATY', false);
  perform public.fn_my_remove_discount();
  perform pg_temp.as_owner(v_b);
  perform public.fn_my_redeem_code('ONESEATY', false);
  perform pg_temp.as_op();
  perform pg_temp.ok(pg_temp.raises(
      format($q$select public.fn_platform_grant_discount(%L, 'ONESEATY', 'Restoring what they had before')$q$, v_a),
      'every place on ONESEATY is taken')
    and public.fn__discount_seats_taken('ONESEATY') = 1,
    '76 restoring a code whose seat another school has taken is refused: one seat stays one');
end $$;

-- Every refused try is logged.
do $$
declare v uuid; v_g uuid := pg_temp.sid('DC Guess'); v_last bigint; r jsonb;
begin
  -- DC Guess is paused (section 7). Two more tries while it waits.
  select coalesce(max(id), 0) into v_last from public.discount_events;
  perform pg_temp.as_owner(v_g);
  r := public.fn_my_redeem_code('GUESSWAIT1', false);
  r := public.fn_preview_discount('PEEKWAIT1', null, null);
  perform pg_temp.ok((select count(*) from public.discount_events e
                       where e.id > v_last and e.school_id = v_g and e.event = 'refused'
                         and coalesce((e.after->>'paused')::boolean, false)) = 2
                     and r->>'reason' like 'Too many codes%',
    '77 tries made while paused are logged, marked paused so they do not keep the pause going');

  perform pg_temp.as_op();
  v := pg_temp.school('DC Log', 'starter', 1);
  perform pg_temp.as_owner(v);
  perform public.fn_my_redeem_code('TWENTYOFF', false);
  r := public.fn_my_redeem_code('TENFORTHREE', false);
  perform pg_temp.ok((r->>'needs_replace')::boolean
                     and exists (select 1 from public.discount_events
                                  where school_id = v and event = 'refused' and code = 'TENFORTHREE'
                                    and reason like 'Your subscription already has TWENTYOFF%')
                     and exists (select 1 from public.discount_events
                                  where school_id = pg_temp.sid('DC Outage') and event = 'refused'
                                    and code = 'TWENTYOFF' and reason like '%arranged with us%'),
    '78 a try that needs a yes, and one refused because we arranged the discount, are logged too');
end $$;

-- A purged school's discount log is history, not something left behind.
do $$
declare v uuid; r jsonb;
begin
  perform pg_temp.as_op();
  v := pg_temp.school('DC Purged', 'starter', 1);
  perform pg_temp.as_owner(v);
  perform public.fn_my_redeem_code('TWENTYOFF', false);
  perform pg_temp.as_op();
  update public.schools set archived_at = now(), archive_reason = 'left us', active = false where id = v;
  insert into public.platform_exports (school_id, school_name, total_rows) values (v, 'DC Purged', 1);
  r := public.fn_platform_purge_school(v, 'DC Purged', true);
  perform pg_temp.ok((r->>'purged')::boolean
                     and exists (select 1 from public.discount_events where school_id = v)
                     and not exists (select 1 from public.fn_platform_orphan_report() o where o.school_id = v)
                     and not exists (select 1 from public.fn__referential_health() h
                                      where h.child_table = 'discount_events'),
    '79 after a purge the discount log keeps the school, and nothing reports it as left behind');
end $$;

-- A public code cannot make invoices free, or all but free, for years.
do $$
begin
  perform pg_temp.ok(
    pg_temp.raises($q$select pg_temp.code('{"code":"FLATFREEFOREVER","label":"x","description":"y","kind":"flat","value":50000,"duration":"forever"}')$q$,
                   'private to one school')
    and pg_temp.raises($q$select pg_temp.code('{"code":"ALMOSTFREE1","label":"x","description":"y","kind":"percent","value":99.98,"duration":"forever"}')$q$,
                       'private to one school')
    and pg_temp.raises($q$select pg_temp.code('{"code":"FREETO2099","label":"x","description":"y","kind":"percent","value":100,"duration":"until","duration_until":"2099-12-31"}')$q$,
                       'private to one school')
    and pg_temp.raises($q$select pg_temp.code('{"code":"FREE24MONTHS","label":"x","description":"y","kind":"percent","value":100,"duration":"months","duration_months":24}')$q$,
                       'private to one school')
    and (pg_temp.code('{"code":"FREEYEAR12","label":"A free year","description":"y","kind":"percent","value":100,"duration":"months","duration_months":12}')->>'code') = 'FREEYEAR12',
    '80 a flat Rs 50,000 for ever, 99.98% for ever, 100% to 2099 or for 24 months must be private; a free year may be public');
end $$;

-- A price typed by hand is not booked as the code's saving.
do $$
declare v uuid; i jsonb;
begin
  perform pg_temp.code('{"code":"TENONEMONTHX","label":"Ten off a month","description":"x","kind":"percent","value":10,"duration":"months","duration_months":1}');
  v := pg_temp.school('DC Hardship', 'starter', 1);
  perform pg_temp.as_owner(v);
  perform public.fn_my_redeem_code('TENONEMONTHX', false);
  perform pg_temp.as_op();
  i := public.fn_platform_raise_invoice(v, 1, 500, 'Hardship: flood damage, agreed by the founder');
  perform pg_temp.ok((select amount_off from public.discount_applications
                       where invoice_id = (i->>'invoice_id')::uuid) = 200
                     and (select total_saved from public.subscription_discounts
                           where school_id = v and code = 'TENONEMONTHX') = 200,
    '81 a hardship price of Rs 500 books the 10% code as saving Rs 200, not Rs 1,500');
end $$;

-- Last, because it stands in for the roll count: a school over its limit that
-- we invoiced on purpose redeems a code. It is never told its invoice was
-- reissued unless one was, and never reads our sentences.
create or replace function public.fn_count_students(p_school_id uuid) returns integer
language sql stable as
  $$ select case when p_school_id = (select id from public.schools where name = 'DC Over') then 300 else 0 end $$;
do $$
declare v uuid; r jsonb;
begin
  perform pg_temp.as_op();
  v := pg_temp.school('DC Over', 'starter', 1);
  perform pg_temp.code('{"code":"FIVEPCOFFX","label":"Five off","description":"x","kind":"percent","value":5,"duration":"forever"}');
  perform public.fn_platform_raise_invoice(v, 1, null, 'Invoiced on Starter while they decide on Growth');
  perform pg_temp.as_owner(v);
  r := public.fn_my_redeem_code('FIVEPCOFFX', false);
  perform pg_temp.ok((r->>'ok')::boolean
                     and (r->>'what_next' not like '%reissued%'
                          or exists (select 1 from public.platform_invoices
                                      where school_id = v and voided_at is null
                                        and discount_code = 'FIVEPCOFFX'))
                     and r::text not like '%Change plan%' and r::text not like '%give a reason%',
    '82 the school is not told its invoice was reissued when none was raised, nor shown our reasons');
end $$;

rollback;
