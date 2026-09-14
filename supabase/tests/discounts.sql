-- =============================================================================
-- A discount is a promise, and every way it can go wrong
--
-- The engine is worth about as much as its edge cases, because the ordinary
-- case (twenty percent off, once) is the one anybody would have got right. The
-- ones below are the ones that end up in a billing dispute:
--
--   1. A flat discount larger than the price gives a zero invoice, never a
--      negative one, and records the saving that was actually given.
--   2. A hundred percent is allowed and gives zero.
--   3. The terms are FROZEN on redemption: editing the code afterwards does not
--      reach a school already on it.
--   4. 'once' comes off exactly one invoice and then stops.
--   5. 'forever' keeps coming off.
--   6. 'until' stops on its date, judged against the period being invoiced and
--      not against the day the invoice is raised.
--   7. A trial extension moves the trial date and never touches an invoice.
--   8. A trial extension is refused once the trial is over.
--   9. The same code twice is refused, by name and with the date.
--  10. An expired code, a switched-off code and a full code are all refused in
--      words a school can act on.
--  11. A code for one plan is refused on another, naming the plan it is for.
--  12. A minimum term is enforced.
--  13. A second code REPLACES the first rather than stacking.
--  14. An operator typing an explicit amount is not discounted on top.
--  15. A school cannot see, apply or remove another school's discount, and a
--      clerk cannot apply one at all.
--  16. A code nobody has redeemed can be deleted; one that has been cannot.
--  17. The renewal run applies the discount, because that is the path that
--      actually bills people.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/discounts.sql
-- =============================================================================
\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- This suite owns its prices, for the reason operator_billing.sql gives: every
-- figure below is arithmetic about a discount, not a claim about where the
-- commercial bands sit.
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

/* The amount actually invoiced when a school is activated for N months. */
create or replace function pg_temp.bill(p_school text, p_months integer default 1)
returns numeric language plpgsql as $$
declare v_id uuid; j jsonb;
begin
  select id into v_id from public.schools where name = p_school;
  perform pg_temp.op();
  j := public.fn_activate_subscription(v_id, 'starter', p_months, null, null, true);
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
select pg_temp.op();
select public.fn_platform_save_discount('TWENTY', '20% off forever', 'percent', 20, 'forever');
select public.fn_platform_save_discount('BIGFLAT', 'Rs 5000 off once', 'flat', 5000, 'once');
select public.fn_platform_save_discount('ALLFREE', '100% off once', 'percent', 100, 'once');
select public.fn_platform_save_discount('ONCE500', 'Rs 500 off once', 'flat', 500, 'once');
select public.fn_platform_save_discount('TILLDATE', 'Rs 300 off until', 'flat', 300,
  'until', null, current_date + 20);
select public.fn_platform_save_discount('TRIAL30', '30 extra trial days', 'trial_days', 30, 'once');
select public.fn_platform_save_discount('GONE', 'expired', 'flat', 100, 'once',
  null, null, null, current_date - 1);
select public.fn_platform_save_discount('OFFAIR', 'switched off', 'flat', 100, 'once',
  null, null, null, null, null, null, null, false);
select public.fn_platform_save_discount('ONESEAT', 'one school only', 'flat', 100, 'once',
  null, null, null, null, 1);
select public.fn_platform_save_discount('GROWONLY', 'growth plan only', 'flat', 100, 'once',
  null, null, null, null, null, array['growth']);
select public.fn_platform_save_discount('YEARONLY', 'yearly only', 'flat', 100, 'once',
  null, null, null, null, null, null, 12);

-- ============================================================================
-- 1 and 2. The floor, which is the edge case the whole thing turns on.
-- ============================================================================
select pg_temp.ok(public.fn__discount_off('flat', 5000, 2000) = 2000,
  '1. a flat 5000 off a 2000 plan takes 2000, not 5000');
select pg_temp.ok(public.fn__discount_off('percent', 100, 2000) = 2000,
  '2. a hundred percent takes the whole price');

select pg_temp.be('Disc Owner');
select public.fn_my_apply_discount('BIGFLAT');
select pg_temp.ok(pg_temp.bill('Disc A', 1) = 0,
  '1b. the invoice is zero, not negative');
select pg_temp.ok((select total_saved from public.subscription_discounts
                    where school_id = (select id from public.schools where name='Disc A')
                      and code = 'BIGFLAT') = 2000,
  '1c. and the saving recorded is what was given, not what was offered');

-- ============================================================================
-- 3. The terms are frozen on redemption.
-- ============================================================================
select pg_temp.be('Disc B Owner');
select public.fn_my_apply_discount('TWENTY');
select pg_temp.op();
select public.fn_platform_save_discount('TWENTY', 'now only 5%', 'percent', 5, 'forever');
select pg_temp.ok(pg_temp.bill('Disc B', 1) = 1600,
  '3. editing the code to 5% leaves the school on the 20% it was promised');
select pg_temp.ok((select value from public.subscription_discounts
                    where code = 'TWENTY') = 20,
  '3b. the redemption keeps its own copy of the value');

-- ============================================================================
-- 4 and 5. once stops; forever does not.
-- ============================================================================
select pg_temp.ok(pg_temp.bill('Disc B', 1) = 1600, '5. forever applies again');
select pg_temp.ok(pg_temp.bill('Disc A', 1) = 2000,
  '4. a once discount does not come off the second invoice');
select pg_temp.ok((select uses_left from public.subscription_discounts
                    where code = 'BIGFLAT') = 0,
  '4b. and it is recorded as spent');

-- ============================================================================
-- 6. until, judged against the period being invoiced.
-- ============================================================================
do $$
declare v uuid;
begin
  select id into v from public.schools where name = 'Disc A';
  -- Its next period starts well after the code's end date, so it must not come
  -- off even though today is inside the window.
  update public.subscriptions set period_end = current_date + 60 where school_id = v;
end $$;
select pg_temp.be('Disc Owner');
select public.fn_my_apply_discount('TILLDATE');
select pg_temp.ok(pg_temp.bill('Disc A', 1) = 2000,
  '6. a discount that has run out by the period start does not come off it');

-- ============================================================================
-- 7 and 8. The trial extension.
-- ============================================================================
select pg_temp.op();
-- Disc B has been billed twice above, which is what makes it `active`. The
-- trial extension is a trial thing, so put it back on a trial first: the
-- refusal for a school that is NOT trialing is asserted separately at 8.
do $$ begin
  update public.subscriptions
     set status = 'trialing', trial_ends_on = current_date + 14
   where school_id = (select id from public.schools where name = 'Disc B');
end $$;
select public.fn_platform_give_discount(
  (select id from public.schools where name = 'Disc B'), 'TRIAL30');
select pg_temp.ok(
  (select trial_ends_on from public.subscriptions
    where school_id = (select id from public.schools where name='Disc B'))
  = current_date + 44,
  '7. thirty days are added to the fourteen that were left');
select pg_temp.ok((select uses_left from public.subscription_discounts
                    where code = 'TRIAL30') = 0,
  '7b. and it can never also come off an invoice');

select pg_temp.op();
do $$ begin
  update public.subscriptions set status = 'active'
   where school_id = (select id from public.schools where name = 'Disc A');
end $$;
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_give_discount(
       (select id from public.schools where name='Disc A'), 'TRIAL30') $$,
  'trial has already finished'),
  '8. a trial extension is refused once the trial is over');

-- ============================================================================
-- 9 to 12. The refusals a school reads.
-- ============================================================================
select pg_temp.be('Disc B Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('TWENTY') $$, 'already used that code'),
  '9. the same code twice is refused');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('GONE') $$, 'expired on'),
  '10a. an expired code says when it expired');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('OFFAIR') $$, 'no longer being offered'),
  '10b. a switched-off code');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('NOSUCHCODE') $$, 'do not recognise'),
  '10c. a code that does not exist');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('GROWONLY') $$, 'only for the'),
  '11. a code for another plan names the plan it is for');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('YEARONLY') $$, 'at least 12 month'),
  '12. a minimum term is enforced and says the number');

-- One seat, taken by A, refused to B.
select pg_temp.be('Disc Owner');
select public.fn_my_apply_discount('ONESEAT');
select pg_temp.be('Disc B Owner');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('ONESEAT') $$, 'as many schools as it was meant for'),
  '10d. a code with a redemption cap stops when it is full');

-- ============================================================================
-- 13. A second code replaces the first.
-- ============================================================================
select pg_temp.be('Disc B Owner');
select public.fn_my_apply_discount('ONCE500');
select pg_temp.ok((select count(*) from public.subscription_discounts
                    where school_id = (select id from public.schools where name='Disc B')
                      and removed_at is null) = 1,
  '13. one live discount per school after a second is applied');
select pg_temp.ok((select code from public.subscription_discounts
                    where school_id = (select id from public.schools where name='Disc B')
                      and removed_at is null) = 'ONCE500',
  '13b. and it is the new one');

-- ============================================================================
-- 14. An explicit amount is not discounted on top.
-- ============================================================================
select pg_temp.op();
select pg_temp.ok(
  (public.fn_activate_subscription(
     (select id from public.schools where name='Disc B'), 'starter', 1,
     1234, 'agreed by phone', true)->>'amount')::numeric = 1234,
  '14. a hand-typed amount is charged as typed, with no discount on top');

-- ============================================================================
-- 15. Who may do what.
-- ============================================================================
select pg_temp.be('Disc Class Teacher');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_my_apply_discount('ALLFREE') $$, 'owner or the principal'),
  '15a. a clerk cannot apply a discount');
select pg_temp.be('Disc B Owner');
select pg_temp.ok(
  (public.fn_my_discount()->>'code') is distinct from 'ONESEAT',
  '15b. one school cannot see another school''s discount');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_discounts() $$, 'not permitted'),
  '15c. a school owner cannot read the vendor''s code list');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_give_discount(
       (select id from public.schools where name='Disc A'), 'ALLFREE') $$, 'not permitted'),
  '15d. nor put a code on another school');

-- ============================================================================
-- 16. Delete versus retire.
-- ============================================================================
select pg_temp.op();
select public.fn_platform_delete_discount('ALLFREE');
select pg_temp.ok(not exists (select 1 from public.discount_codes where code='ALLFREE'),
  '16. a code nobody redeemed is deleted outright');
select pg_temp.ok(pg_temp.raises(
  $$ select public.fn_platform_delete_discount('TWENTY') $$, 'cannot be deleted'),
  '16b. a code somebody redeemed cannot be, and the message says what to do');

-- ============================================================================
-- 17. The roster the console shows, and the renewal path.
-- ============================================================================
select pg_temp.ok(
  jsonb_array_length(public.fn_platform_discount_usage()) >= 5,
  '17. the usage roster lists every redemption across every school');
-- Disc A's live code is ONESEAT, a one-time flat 100. Bill it once and the
-- redemption is spent WITHOUT being removed, which is the state that only
-- exists because 'once' counts down rather than deleting itself. The four
-- states are what the roster is for: an operator deciding whether to phone
-- somebody needs to know which of the four ways it stopped.
select pg_temp.ok(pg_temp.bill('Disc A', 1) = 1900,
  '17b. the one-time code comes off exactly once');
select pg_temp.ok(
  (select count(*) from jsonb_array_elements(public.fn_platform_discount_usage()) e
    where e->>'state' = 'spent') >= 1,
  '17c. and the roster then marks it spent rather than active');
select pg_temp.ok(
  (select count(*) from jsonb_array_elements(public.fn_platform_discount_usage()) e
    where e->>'state' = 'removed') >= 1,
  '17d. a replaced one reads as removed, not as spent');
-- ONCE500 is Disc B's live code and has not been spent: test 14 billed that
-- school with a hand-typed amount, which deliberately consumes nothing.
-- TWENTY was redeemed and then replaced, so it counts as taken up but not
-- live, which is the distinction the two columns exist to draw.
select pg_temp.ok(
  (select (e->>'live')::int from jsonb_array_elements(public.fn_platform_discounts()) e
    where e->>'code' = 'ONCE500') = 1,
  '17e. the code list counts how many schools are live on each code');
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
