-- =============================================================================
-- A discount is a promise, and every way it can go wrong
--
-- The engine is worth about as much as its edge cases, because the ordinary
-- case (twenty percent off, for a month) is the one anybody would have got
-- right. The ones below are the ones that end up in a billing dispute. Since
-- 0156 every code is counted in BILLED MONTHS, invoices are whole rupees, and
-- the old console's 'once' is one billed month:
--
--   1. A flat discount larger than the price gives a zero invoice, never a
--      negative one, and records the saving that was actually given.
--   2. A hundred percent is allowed and gives zero.
--   3. The terms are FROZEN on redemption: once a school is on a code its money
--      terms cannot be edited, and the invoice reads the school's own copy.
--   4. A one-month code comes off exactly one invoice and then stops.
--   5. 'forever' keeps coming off.
--   6. 'until' is judged against the months being invoiced, not against the
--      day the invoice is raised. A code that could not reach the school's
--      next invoice is refused rather than spent.
--   7. A trial extension moves the trial date, never touches an invoice and
--      never pushes a money discount out.
--   8. A trial extension is refused once the trial is over.
--   9. The same code twice is refused, with the date it was used.
--  10. An expired code says when it could be used. A switched-off code, a
--      code that does not exist and a full code all get ONE sentence, so a
--      guesser cannot tell them apart.
--  11. A code for one plan is refused on another, naming the plan it is for.
--  12. A minimum term is enforced.
--  13. A second code replaces the first only when the school says yes; the
--      old entry point never swaps silently.
--  14. An operator typing an explicit amount is not discounted on top, and the
--      typed price uses the code up.
--  15. A school cannot see, apply or remove another school's discount, a
--      clerk cannot apply one at all, and a school cannot use the console.
--  16. A code nobody has redeemed can be deleted; one that has been is retired
--      instead, and the school's record of it stays.
--  17. The console's code list and usage roster tell the states apart.
--
-- The old console entry points (fn_platform_save_discount, fn_platform_give_
-- discount, fn_my_apply_discount, fn_activate_subscription) are used where
-- they still express the case, because consoles and the web app still call
-- them. discount_codes_keep_their_word.sql covers the new entry points on
-- their own.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/discounts.sql
-- =============================================================================
\set ON_ERROR_STOP on

begin;
-- The billing functions work in Pakistan time. The suite does too, so a date
-- it writes and a date a function reads are the same day near midnight.
set local timezone = 'Asia/Karachi';

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- This suite owns its prices, for the reason operator_billing.sql gives: every
-- figure below is arithmetic about a discount, not a claim about where the
-- commercial bands sit. Every invoice below is one month of Starter.
update public.plans set price_monthly = 2000, price_quarterly = 5700,
       price_yearly = 20000 where code = 'starter';
update public.plans set price_monthly = 3500, price_quarterly = 9975,
       price_yearly = 35000 where code = 'growth';

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

create or replace function pg_temp.op() returns void language sql as $$
  select set_config('test.uid', '00000000-0000-0000-0000-0000000060ff', false);
$$;

create or replace function pg_temp.sid(p_name text) returns uuid language sql as $$
  select id from public.schools where name = p_name;
$$;

-- The one sentence a school reads for a code it may not know about (0156).
create or replace function pg_temp.one_sentence() returns text language sql as $$
  select 'That code is not one we can apply for your school. Check it, or ask us.'::text;
$$;

/* The amount invoiced for a school's next N months, raised the way the console
   raises it. Since 0155 raising an invoice does not move the licence, paying
   it does, and a second invoice cannot be raised while one is unpaid. So the
   invoice is paid in full here: that is what makes the school active and lets
   the next call bill the period after this one. */
create or replace function pg_temp.bill(p_school text, p_months integer default 1)
returns numeric language plpgsql as $$
declare v_id uuid; j jsonb;
begin
  select id into v_id from public.schools where name = p_school;
  perform pg_temp.op();
  j := public.fn_activate_subscription(v_id, 'starter', p_months, null, null, true);
  if (j->>'owed')::numeric > 0 then
    perform public.fn_platform_record_payment(v_id, (j->>'owed')::numeric, current_date,
      'bank', 'T-' || (j->>'doc_no'), (j->>'invoice_id')::uuid, null, 0, null);
  end if;
  return (j->>'amount')::numeric;
end;
$$;

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000060a1';
  v_ca uuid := '00000000-0000-0000-0000-0000000060a2';
  v_ob uuid := '00000000-0000-0000-0000-0000000060b1';
  v_op uuid := '00000000-0000-0000-0000-0000000060ff';
begin
  insert into auth.users (id, email) values (v_op, 'op@disc.test')
    on conflict (id) do nothing;
  insert into public.platform_admins (user_id, email, note)
    values (v_op, 'op@disc.test', 'Founder') on conflict (user_id) do nothing;

  insert into public.schools (name) values ('Disc A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, term_months,
                                    trial_ends_on)
    values (v_a, 'starter', 'trialing', 1, current_date + 14);
  insert into public.schools (name) values ('Disc B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, term_months,
                                    trial_ends_on)
    values (v_b, 'starter', 'trialing', 1, current_date + 14);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'oa@disc.test'), (v_ca, 'ca@disc.test'), (v_ob, 'ob@disc.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Disc Owner',   'owner',       v_a),
    (v_ca, 'Disc Class Teacher',   'class_teacher', v_a),
    (v_ob, 'Disc B Owner', 'owner',       v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;
end
$seed$;

-- --- The codes ---------------------------------------------------------------
-- Codes are six characters or more (0156), and each has a label the school
-- sees and a description that is ours. BIGFLAT is made through the old
-- console's save, which only knows 'once'; the rest through create.
select pg_temp.op();
select public.fn_platform_save_discount('BIGFLAT', 'Rs 5000 off once', 'flat', 5000, 'once');
select public.fn_platform_create_discount(jsonb_build_object('code', 'TWENTY',
  'label', 'Twenty per cent off', 'description', 'Launch offer for the partner list',
  'kind', 'percent', 'value', 20, 'duration', 'forever'));
select public.fn_platform_create_discount(jsonb_build_object('code', 'ALLFREE',
  'label', 'A free month', 'description', '100% off one month',
  'kind', 'percent', 'value', 100, 'duration', 'months', 'duration_months', 1));
select public.fn_platform_create_discount(jsonb_build_object('code', 'ONCE500',
  'label', 'Rs 500 off a month', 'description', 'Rs 500 off one month',
  'kind', 'flat', 'value', 500, 'duration', 'months', 'duration_months', 1));
select public.fn_platform_create_discount(jsonb_build_object('code', 'TILLDATE',
  'label', 'Rs 300 off a month', 'description', 'Rs 300 off until a date',
  'kind', 'flat', 'value', 300, 'duration', 'until', 'duration_until', current_date + 20));
select public.fn_platform_create_discount(jsonb_build_object('code', 'TRIAL30',
  'label', 'Thirty more days', 'description', '30 extra trial days',
  'kind', 'trial_days', 'value', 30));
select public.fn_platform_create_discount(jsonb_build_object('code', 'EXPIRED',
  'label', 'Old offer', 'description', 'expired',
  'kind', 'flat', 'value', 100, 'duration', 'months', 'duration_months', 1,
  'redeem_until', current_date));
select public.fn_platform_create_discount(jsonb_build_object('code', 'OFFAIR',
  'label', 'Old offer', 'description', 'switched off',
  'kind', 'flat', 'value', 100, 'duration', 'months', 'duration_months', 1,
  'active', false));
select public.fn_platform_create_discount(jsonb_build_object('code', 'ONESEAT',
  'label', 'First school', 'description', 'one school only',
  'kind', 'flat', 'value', 100, 'duration', 'months', 'duration_months', 1,
  'max_redemptions', 1));
select public.fn_platform_create_discount(jsonb_build_object('code', 'GROWONLY',
  'label', 'Growth special', 'description', 'growth plan only',
  'kind', 'flat', 'value', 100, 'duration', 'months', 'duration_months', 1,
  'plan_codes', jsonb_build_array('growth')));
select public.fn_platform_create_discount(jsonb_build_object('code', 'YEARONLY',
  'label', 'Pay yearly', 'description', 'yearly only',
  'kind', 'flat', 'value', 100, 'duration', 'months', 'duration_months', 1,
  'min_term_months', 12));

select pg_temp.ok(
  (select duration = 'months' and duration_months = 1 from public.discount_codes
    where code = 'BIGFLAT'),
  '0. the old console''s ''once'' is saved as one billed month');
-- A code cannot be made already past its last day, so the expired one was made
-- for today and is moved back a day here, as time would have moved it.
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_create_discount(jsonb_build_object('code', 'EXPIRED2',
       'label', 'x', 'description', 'y', 'kind', 'flat', 'value', 100,
       'duration', 'months', 'duration_months', 1, 'redeem_until', current_date - 1)) $$,
  'in the past'),
  '0b. a code cannot be made already past the last day it can be used');
update public.discount_codes set redeem_until = current_date - 1 where code = 'EXPIRED';

-- ============================================================================
-- 1 and 2. The floor, which is the edge case the whole thing turns on.
-- ============================================================================
-- fn__discount_calc is the arithmetic every invoice and preview uses since
-- 0156 (fn__discount_off is kept for old callers and nothing bills with it).
-- Arguments: code, kind, value, duration, months left, until, plans, minimum
-- term, the invoice's plan, its months, its first day, its term price.
select pg_temp.ok((public.fn__discount_calc('BIGFLAT', 'flat', 5000, 'months', 1, null,
                     null, null, 'starter', 1, current_date, 2000)->>'amount')::numeric = 2000,
  '1. a flat 5000 off a 2000 month takes 2000, not 5000');
select pg_temp.ok((public.fn__discount_calc('ALLFREE', 'percent', 100, 'months', 1, null,
                     null, null, 'starter', 1, current_date, 2000)->>'amount')::numeric = 2000,
  '2. a hundred percent takes the whole price');

select pg_temp.be('Disc Owner');
select public.fn_my_apply_discount('BIGFLAT');
select pg_temp.ok(pg_temp.bill('Disc A', 1) = 0,
  '1b. the invoice is zero, not negative');
select pg_temp.ok((select total_saved from public.subscription_discounts
                    where school_id = pg_temp.sid('Disc A') and code = 'BIGFLAT') = 2000,
  '1c. and the saving recorded is what was given, not what was offered');

-- ============================================================================
-- 3. The terms are frozen on redemption.
-- ============================================================================
select pg_temp.be('Disc B Owner');
select public.fn_my_apply_discount('TWENTY');
select pg_temp.op();
-- The old console's save never edits: it cannot know the version the operator
-- was looking at, so an existing code is refused and the operator is sent to
-- the Discounts page, where an edit is checked against what it started from.
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_save_discount('TWENTY', 'now only 5%', 'percent', 5, 'forever') $$,
  'already exists'),
  '3. editing a code a school is on down to 5% is refused, even from the old console');
select pg_temp.ok((select value from public.subscription_discounts
                    where code = 'TWENTY') = 20,
  '3b. the redemption keeps its own copy of the value');
-- The console cannot change the row any more, so change it by hand: the
-- invoice must read the school's copy, not the code.
update public.discount_codes set value = 5 where code = 'TWENTY';
select pg_temp.ok(pg_temp.bill('Disc B', 1) = 1600,
  '3c. even with the code changed in the table, the school is billed the 20% it was promised');
select pg_temp.be('Disc B Owner');
select pg_temp.ok(public.fn_my_discount()->>'label' = 'Twenty per cent off'
                  and public.fn_my_discount()::text not like '%partner list%',
  '3d. the school reads the label, never our description');

-- ============================================================================
-- 4 and 5. A one-month code stops; forever does not.
-- ============================================================================
select pg_temp.ok(pg_temp.bill('Disc B', 1) = 1600, '5. forever applies again');
select pg_temp.ok(pg_temp.bill('Disc A', 1) = 2000,
  '4. a one-month discount does not come off the second invoice');
select pg_temp.ok((select months_left from public.subscription_discounts
                    where code = 'BIGFLAT') = 0,
  '4b. and its one month is recorded as used');

-- ============================================================================
-- 6. until, judged against the months being invoiced.
-- ============================================================================
-- Disc A has paid two months, so its next period starts well after TILLDATE's
-- end date even though today is inside it. A code that would save nothing on
-- the next invoice is refused, so it is not burned for nothing.
select pg_temp.ok(current_date <= current_date + 20
                  and public.fn__next_period_start(pg_temp.sid('Disc A')) > current_date + 20,
  '6pre. today is inside TILLDATE''s window, and Disc A''s next period starts after it');
select pg_temp.be('Disc Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('TILLDATE') $$, 'would save nothing'),
  '6. a code that has run out by the next period start is refused, not spent');
select pg_temp.ok(not exists (select 1 from public.subscription_discounts
                               where school_id = pg_temp.sid('Disc A') and code = 'TILLDATE'),
  '6b. and the school does not hold it');
-- On a three-month invoice starting on day 15, a code ending on day 20 covers
-- the first month (it starts before the end date) and not the other two.
select pg_temp.ok(
  (select (j->>'covered')::int = 1 and (j->>'amount')::numeric = 300
     from (select public.fn__discount_calc('TILLDATE', 'flat', 300, 'until', null,
             current_date + 20, null, null, 'starter', 3, current_date + 15, 5700) j) x),
  '6c. on a quarter it covers only the months that start by its date: Rs 300, not Rs 900');

-- ============================================================================
-- 7 and 8. The trial extension.
-- ============================================================================
select pg_temp.op();
-- Disc B has been billed and has paid twice above, which is what makes it
-- `active`. The trial extension is a trial thing, so put it back on a trial
-- first: the refusal for a school that is NOT trialing is asserted at 8.
do $$ begin
  update public.subscriptions
     set status = 'trialing', trial_ends_on = current_date + 14
   where school_id = (select id from public.schools where name = 'Disc B');
end $$;
select public.fn_platform_give_discount(pg_temp.sid('Disc B'), 'TRIAL30');
select pg_temp.ok(
  (select trial_ends_on from public.subscriptions
    where school_id = pg_temp.sid('Disc B'))
  = current_date + 44,
  '7. thirty days are added to the fourteen that were left');
select pg_temp.ok((select uses_left from public.subscription_discounts
                    where code = 'TRIAL30') = 0,
  '7b. and it can never also come off an invoice');
select pg_temp.ok((select code from public.fn__discount_live(pg_temp.sid('Disc B'), null)) = 'TWENTY',
  '7c. nor push the school''s money discount out: TWENTY is still live');

-- Disc A paid for its invoices above, which made it active; nobody has to
-- set that by hand any more.
select pg_temp.op();
select pg_temp.ok(public.fn_effective_status(pg_temp.sid('Disc A')) = 'active'
  and pg_temp.raises(
  $$ select public.fn_platform_give_discount(pg_temp.sid('Disc A'), 'TRIAL30') $$,
  'not in a running trial'),
  '8. a trial extension is refused once the trial is over');

-- ============================================================================
-- 9 to 12. The refusals a school reads.
-- ============================================================================
-- fn_my_apply_discount is the old entry point: it raises the refusal that
-- fn_my_redeem_code returns. 0156 closes it to signed-in users (a raise rolls
-- back the log of the refused try); it is called here as the database owner to
-- check the sentences, which are fn_my_redeem_code's.
select pg_temp.be('Disc B Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('TWENTY') $$,
  'used that code on ' || to_char(current_date, 'DD Mon YYYY')),
  '9. the same code twice is refused, with the day it was used');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('EXPIRED') $$,
  'could be used until ' || to_char(current_date - 1, 'DD Mon YYYY')),
  '10a. an expired code says when it could be used');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('OFFAIR') $$, pg_temp.one_sentence()),
  '10b. a switched-off code gets the one sentence');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('NOSUCHCODE') $$, pg_temp.one_sentence()),
  '10c. a code that does not exist gets the same sentence');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('GROWONLY') $$, 'That code is for Growth'),
  '11. a code for another plan names the plan it is for');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('YEARONLY') $$, '12 months or more'),
  '12. a minimum term is enforced and says the number');

-- One seat, taken by A, refused to B.
select pg_temp.be('Disc Owner');
select public.fn_my_apply_discount('ONESEAT');
select pg_temp.be('Disc B Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('ONESEAT') $$, pg_temp.one_sentence()),
  '10d. a full code gets the same sentence too, so it does not show it exists');

-- ============================================================================
-- 13. A second code replaces the first, when the school says yes.
-- ============================================================================
select pg_temp.be('Disc B Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('ONCE500') $$, 'already has TWENTY'),
  '13. the old entry point no longer swaps a live discount out silently');
select pg_temp.ok((public.fn_my_redeem_code('ONCE500', true)->>'ok')::boolean,
  '13a. with a yes, the second code goes on');
-- Trial days are not a money discount and do not count against the one slot.
select pg_temp.ok((select count(*) from public.subscription_discounts
                    where school_id = pg_temp.sid('Disc B')
                      and removed_at is null and kind <> 'trial_days') = 1,
  '13b. one live money discount per school after a second is applied');
select pg_temp.ok((select code from public.subscription_discounts
                    where school_id = pg_temp.sid('Disc B')
                      and removed_at is null and kind <> 'trial_days') = 'ONCE500',
  '13c. and it is the new one');
select pg_temp.op();
select pg_temp.ok(
  (select (e->>'live')::int from jsonb_array_elements(public.fn_platform_discounts()) e
    where e->>'code' = 'ONCE500') = 1,
  '13d. the code list counts how many schools are live on each code');

-- ============================================================================
-- 14. An explicit amount is not discounted on top.
-- ============================================================================
select pg_temp.op();
do $$
declare j jsonb;
begin
  j := public.fn_activate_subscription(pg_temp.sid('Disc B'), 'starter', 1,
         1234, 'agreed by phone', true);
  perform pg_temp.ok((j->>'amount')::numeric = 1234,
    '14. a hand-typed amount is charged as typed, with no discount on top');
  -- 0156: a typed price with a code that would have applied uses the code up,
  -- so the school cannot also have it off the next invoice.
  perform pg_temp.ok((select note from public.platform_invoices
                       where id = (j->>'invoice_id')::uuid) like '%code ONCE500 is used up%',
    '14b. and the invoice says the typed price used the code up');
end $$;

-- ============================================================================
-- 15. Who may do what.
-- ============================================================================
select pg_temp.be('Disc Class Teacher');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('ALLFREE') $$, 'owner or the principal'),
  '15a. a clerk cannot apply a discount');
select pg_temp.be('Disc B Owner');
select pg_temp.ok(public.fn_my_discount()::text not like '%ONESEAT%',
  '15b. one school cannot see another school''s discount');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_discounts() $$, 'not permitted'),
  '15c. a school owner cannot read the vendor''s code list');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_give_discount(pg_temp.sid('Disc A'), 'ALLFREE') $$, 'not permitted'),
  '15d. nor put a code on another school');
select pg_temp.ok(
  pg_temp.raises(
    $$ select public.fn_platform_grant_discount(pg_temp.sid('Disc B'), 'ALLFREE', 'We deserve it', false) $$,
    'not permitted')
  and pg_temp.raises(
    $$ select public.fn_platform_create_discount('{"code":"MYOWNCODE","label":"x","description":"y","kind":"percent","value":50,"duration":"forever"}') $$,
    'not permitted')
  and pg_temp.raises(
    $$ select public.fn_platform_edit_discount('ONCE500', '{"value":2000}', now()) $$,
    'not permitted'),
  '15e. nor give itself a code, make one, or change one, through the new console functions');

-- ============================================================================
-- 16. Delete versus retire.
-- ============================================================================
select pg_temp.op();
select public.fn_platform_delete_discount('ALLFREE');
select pg_temp.ok(not exists (select 1 from public.discount_codes where code='ALLFREE'),
  '16. a code nobody redeemed is deleted outright');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_delete_discount('TWENTY') $$, 'retire it instead'),
  '16b. a code somebody redeemed cannot be deleted, and the message says what to do');
-- A separate statement, so the check reads the row after the retire.
select public.fn_platform_retire_discount('TWENTY', 'Replaced by the spring offer');
select pg_temp.ok(
  (select not active from public.discount_codes where code = 'TWENTY')
  and (select count(*) from public.subscription_discounts where code = 'TWENTY') = 1,
  '16c. it is retired instead, and the school''s record of it stays');

-- ============================================================================
-- 17. The code list and the roster the console shows.
-- ============================================================================
select pg_temp.ok(
  jsonb_array_length(public.fn_platform_discount_usage()) >= 5,
  '17. the usage roster lists every redemption across every school');
-- Disc A's live code is ONESEAT, a one-month flat 100. Bill it once and the
-- redemption is spent WITHOUT being removed, which is the state that only
-- exists because a code's months count down rather than it deleting itself.
-- The states are what the roster is for: an operator deciding whether to
-- phone somebody needs to know which way it stopped.
select pg_temp.ok(pg_temp.bill('Disc A', 1) = 1900,
  '17b. the one-month code comes off exactly once');
select pg_temp.ok(
  (select e->>'state' from jsonb_array_elements(public.fn_platform_discount_usage()) e
    where e->>'code' = 'ONESEAT') = 'spent',
  '17c. and the roster then marks it spent rather than active');
select pg_temp.ok(
  (select e->>'state' from jsonb_array_elements(public.fn_platform_discount_usage()) e
    where e->>'code' = 'TWENTY') = 'removed',
  '17d. a replaced one reads as removed, not as spent');
-- ONCE500 was live on Disc B at 13d. Test 14 billed that school with a
-- hand-typed amount, which since 0156 uses the code up: it is taken up, on one
-- invoice, and no longer live.
select pg_temp.ok(
  (select (e->>'redeemed')::int = 1 and (e->>'live')::int = 0 and (e->>'invoices')::int = 1
     from jsonb_array_elements(public.fn_platform_discounts()) e
    where e->>'code' = 'ONCE500'),
  '17e. a code used up by a typed price reads as redeemed, on one invoice, not live');
-- TWENTY was redeemed and then replaced, so it counts as taken up but not
-- live, which is the distinction the two columns exist to draw.
select pg_temp.ok(
  (select (e->>'redeemed')::int from jsonb_array_elements(public.fn_platform_discounts()) e
    where e->>'code' = 'TWENTY') = 1
  and (select (e->>'live')::int from jsonb_array_elements(public.fn_platform_discounts()) e
    where e->>'code' = 'TWENTY') = 0,
  '17f. a code taken up and since replaced reads as redeemed but not live');
select pg_temp.ok(
  (select (e->>'deletable')::boolean from jsonb_array_elements(public.fn_platform_discounts()) e
    where e->>'code' = 'TWENTY') is false,
  '17g. and the console is told it can no longer be deleted');

rollback;
