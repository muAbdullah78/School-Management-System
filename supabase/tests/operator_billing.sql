-- =============================================================================
-- The operator's own books.
--
-- Demonstrated on a real database before 0064 was written. Three customer
-- schools; Al-Noor renews twelve months of `growth`:
--
--   what was Al-Noor charged? ......... no table records a charge to a school
--   how much has Al-Noor ever paid? ... no function answers it
--   which schools owe us money? ....... unanswerable
--   what did we invoice this month? ... `plans` holds a price list, nothing else
--   who granted it, and when? ......... nothing; audit_log had 0 rows for it
--
-- The rules this file defends:
--
--   1. GRANTING TIME WRITES THE CHARGE, in the same transaction. The software's
--      promise to a school is that every rupee has a row; the operator's half
--      kept none.
--   2. THE LIST PRICE IS THE DEFAULT, and a charge that differs from it needs a
--      reason, which lands ON the invoice. Zero is a legitimate charge — a free
--      year that leaves no trace is how a business loses track of its gifts.
--   3. OUTSTANDING IS DERIVED. It moves when money arrives, not when time is
--      granted, and never the other way round.
--   4. RENEWING A SCHOOL ONTO A PLAN IT HAS OUTGROWN IS REFUSED, naming the
--      count, the limit and the plan that fits. The console already computed all
--      three and the renewal path ignored them — a silent revenue loss.
--   5. AN EXPIRY DATE IS NOT A DEBT. A school that renewed on trust and never
--      paid must not look identical to one that paid.
--   6. EVERY OPERATOR ACTION IS AUDITED, against the school it concerns.
--   7. A SCHOOL USER — ITS OWNER INCLUDED — CAN READ NONE OF IT, and the
--      operator still cannot read tenant data.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/operator_billing.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

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

create or replace function pg_temp.sch(p_name text) returns uuid language sql as $$
  select id from public.schools where name = p_name;
$$;

-- THIS SUITE'S three schools, by name.
--
-- Every count below is scoped through this rather than taken platform-wide, and
-- that is not tidiness. The first version asserted
-- `count(*) from fn_platform_schools() = 3` and passed on a laptop and failed in
-- CI, because CI's importer smoke-test COMMITS a school into the same database
-- before the suites run. A platform-wide count silently asserts "this database
-- contains nothing else", which is never a safe thing to assume and was not
-- true. Scoped, not loosened to `>= 3`: a threshold would pass over a fixture
-- that had stopped creating one of them.
create or replace function pg_temp.mine() returns setof uuid language sql as $$
  select id from public.schools
   where name in ('Al-Noor Public School', 'City Grammar', 'Iqbal Model School');
$$;

create or replace function pg_temp.be_operator() returns void language sql as $$
  select set_config('test.uid', '00000000-0000-0000-0000-00000000b0d1', false);
$$;

-- Put N actually-enrolled children into a school, in its current session.
-- fn_count_students joins enrollments → students → academic_sessions and wants
-- is_current, e.status = 'active' and s.status = 'active', so anything less than
-- the full chain counts as zero.
create or replace function pg_temp.enrol(p_school uuid, p_n integer)
returns void language plpgsql as $$
declare v_sess uuid; v_class uuid;
begin
  insert into public.academic_sessions (school_id, name, is_current, starts_on, ends_on)
    values (p_school, '2026-27', true, current_date - 60, current_date + 300)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = p_school;
  insert into public.classes (school_id, name, level_order)
    values (p_school, 'Class 1', 1) returning id into v_class;

  with ins as (
    insert into public.students (school_id, full_name, father_name, status)
    select p_school, 'Child ' || g, 'Father ' || g, 'active'
      from generate_series(1, p_n) g
    returning id, full_name
  )
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
  select p_school, ins.id, v_sess, v_class, ins.full_name, 'active' from ins;
end;
$$;

-- --- Fixture -----------------------------------------------------------------
-- The operator, and three schools at three points in the customer lifecycle.
do $seed$
declare
  v_a uuid; v_b uuid; v_c uuid;
  v_op uuid := '00000000-0000-0000-0000-00000000b0d1';
  v_own uuid := '00000000-0000-0000-0000-00000000b0d2';
begin
  insert into auth.users (id, email) values (v_op, 'operator@brndsh.io');
  insert into public.platform_admins (user_id, email, note)
    values (v_op, 'operator@brndsh.io', 'Founder');

  insert into public.schools (name, city, contact_name, contact_phone)
    values ('Al-Noor Public School', 'Lahore', 'Mr Tariq', '03001112222') returning id into v_a;
  insert into public.schools (name, city, contact_name, contact_phone)
    values ('City Grammar', 'Karachi', 'Mrs Naz', '03003334444') returning id into v_b;
  insert into public.schools (name, city, contact_name, contact_phone)
    values ('Iqbal Model School', 'Multan', 'Mr Javed', '03005556666') returning id into v_c;

  -- Al-Noor: paying, and ALREADY OVER the growth limit (420 against 300). This
  -- is the scenario the probe found — the console said 'over' and the renewal
  -- put them back on growth anyway.
  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, student_count)
    values (v_a, 'growth', 'active', 'yearly',
            current_date - 30, current_date + 335, 420);
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on, student_count)
    values (v_b, 'starter', 'trialing', current_date + 5, 60);
  insert into public.subscriptions (school_id, plan_code, status, cycle,
                                    period_start, period_end, grace_ends_on, student_count)
    values (v_c, 'growth', 'active', 'yearly',
            current_date - 400, current_date - 35, current_date - 21, 300);

  -- REAL enrolled children, not a hand-set student_count. The first version of
  -- this fixture set the counter directly and assertion 4 failed: the renewal
  -- re-counts before deciding (a stale count would wave an over-limit renewal
  -- straight through, which is the defect), so it recounted 420 down to 0 and
  -- the refusal never fired. A fixture that fakes the number cannot test a
  -- function whose whole job is to distrust it.
  --
  -- Inserted with no login adopted, so enforce_school_id takes the explicit
  -- school_id and skips the subscription gate — which matters for Iqbal, who is
  -- locked.
  perform pg_temp.enrol(v_a, 420);
  perform pg_temp.enrol(v_b, 60);
  perform pg_temp.enrol(v_c, 300);

  -- A school owner, for the "can a tenant read the operator's books" section.
  -- Created while signed in as nobody, so the cross-tenant provisioning guard
  -- has nothing to object to.
  insert into auth.users (id, email) values (v_own, 'owner@alnoor.test');
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, active)
    values (v_own, v_a, 'Mr Tariq', 'owner', true);
  alter table public.profiles enable trigger user;
end;
$seed$;

select pg_temp.be_operator();

-- The books BEFORE this suite writes anything. fn_platform_revenue is a
-- platform-wide figure by definition — that is what the operator is asking for —
-- so the assertions in section 8 check the DELTA this suite caused. Asserting
-- the absolute figure would be asserting "no other school has ever been
-- invoiced", which is the same mistake as counting all the schools.
select public.fn_platform_revenue(current_date - 1, current_date + 1) as base \gset

-- =============================================================================
-- 1. The state the probe found: an expiry date that is not a debt
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.fn_platform_schools()
    where school_id in (select pg_temp.mine())) = 3,
  '1. the console lists all three of this suite''s schools');

select pg_temp.ok(
  (select outstanding from public.fn_platform_schools()
    where school_name = 'Al-Noor Public School') = 0,
  '2. and nobody owes anything yet — the receivable starts at zero, not at null, '
  || 'because "no invoices" is a number and not an unknown');

select pg_temp.ok(
  (select limit_state from public.fn_platform_schools()
    where school_name = 'Al-Noor Public School') = 'over'
  and (select suggested_plan from public.fn_platform_schools()
        where school_name = 'Al-Noor Public School') = 'institution',
  '3. the console already knows Al-Noor has outgrown growth and names the plan '
  || 'that fits');

-- =============================================================================
-- 2. Rule 4 — the renewal refuses to repeat the revenue leak
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_activate_subscription(%L, ''growth'', 12)', pg_temp.sch('Al-Noor Public School')),
    '420 students'),
  '4. renewing Al-Noor onto growth is refused, and the message states the count');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_activate_subscription(%L, ''growth'', 12)', pg_temp.sch('Al-Noor Public School')),
    'institution'),
  '5. and names the plan that fits, so the fix is one word and not an investigation');

select pg_temp.ok(
  (select count(*) from public.platform_invoices
    where school_id in (select pg_temp.mine())) = 0,
  '6. and the refusal wrote no invoice — a refused renewal must not leave a '
  || 'charge behind');

select pg_temp.ok(
  (select period_end from public.subscriptions where school_id = pg_temp.sch('Al-Noor Public School'))
    = current_date + 335,
  '7. nor moved the period. Both halves of the transaction are refused together');

-- =============================================================================
-- 3. Rules 1 and 2 — granting time writes the charge, at the list price
-- =============================================================================
select public.fn_activate_subscription(
  pg_temp.sch('Al-Noor Public School'), 'institution', 12) as act \gset

select pg_temp.ok(
  (:'act'::jsonb->>'invoice_id') is not null
  and (:'act'::jsonb->>'amount')::numeric = 35000,
  '8. putting them on institution goes through and charges the list price of '
  || '35,000 without anybody typing an amount');

select pg_temp.ok(
  (select amount = 35000 and list_amount = 35000 and months = 12
      and cycle::text = 'yearly' and note is null
     from public.platform_invoices
    where school_id = pg_temp.sch('Al-Noor Public School')),
  '9. the invoice records the amount, the list price, the term and the cycle');

select pg_temp.ok(
  (select period_start = current_date + 336 from public.platform_invoices
    where school_id = pg_temp.sch('Al-Noor Public School')),
  '10. and the period it bought starts the day the current one ends — a school '
  || 'that renews early must not lose the days it has already paid for');

select pg_temp.ok(
  public.fn_platform_outstanding(pg_temp.sch('Al-Noor Public School')) = 35000,
  '11. they now owe 35,000');

select pg_temp.ok(
  (select outstanding from public.fn_platform_schools()
    where school_name = 'Al-Noor Public School') = 35000,
  '12. and the console shows it — which is what makes an expiry date and a debt '
  || 'two different things');

-- =============================================================================
-- 4. Rule 2 — a price that is not the list price needs a reason
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_activate_subscription(%L, ''starter'', 12, 5000)',
           pg_temp.sch('City Grammar')),
    'needs a reason'),
  '13. charging 5,000 where the list says 9,500 is refused without a reason');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_activate_subscription(%L, ''starter'', 12, 0)',
           pg_temp.sch('City Grammar')),
    'needs a reason'),
  '14. and so is a free year — a gift with no trace is how a business loses '
  || 'track of what it has given away');

select public.fn_activate_subscription(
  pg_temp.sch('City Grammar'), 'starter', 12, 0, 'Pilot school, first year free') as free \gset

select pg_temp.ok(
  (select amount = 0 and list_amount = 9500
      and note = 'Pilot school, first year free'
     from public.platform_invoices where school_id = pg_temp.sch('City Grammar')),
  '15. with a reason it goes through, and the invoice keeps BOTH numbers — a '
  || 'discount only reads as a discount next to the list price');

select pg_temp.ok(
  public.fn_platform_outstanding(pg_temp.sch('City Grammar')) = 0,
  '16. a free year leaves nothing owing');

select pg_temp.ok(
  (select status::text from public.subscriptions where school_id = pg_temp.sch('City Grammar')) = 'active',
  '17. and still activates them — a zero charge is a charge, not a refusal');

-- =============================================================================
-- 5. Rule 3 — outstanding moves on money, not on time
-- =============================================================================
select public.fn_platform_record_payment(
  pg_temp.sch('Al-Noor Public School'), 20000, current_date, 'bank', 'HBL-77123') as pay \gset

select pg_temp.ok(
  (:'pay'::jsonb->>'outstanding')::numeric = 15000
  and public.fn_platform_outstanding(pg_temp.sch('Al-Noor Public School')) = 15000,
  '18. a part-payment of 20,000 against 35,000 leaves 15,000 — a school paying '
  || 'half is normal and must not need a workaround');

select pg_temp.ok(
  (select count(*) from public.fn_platform_ledger(pg_temp.sch('Al-Noor Public School'))) = 2,
  '19. the ledger shows both the invoice and the payment');

select pg_temp.ok(
  (select reference from public.fn_platform_ledger(pg_temp.sch('Al-Noor Public School'))
    where kind = 'payment') = 'HBL-77123',
  '20. keeping the bank reference, which is the only way to tie a row to a '
  || 'statement when a school says it paid');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_platform_record_payment(%L, 0)', pg_temp.sch('Al-Noor Public School')),
    'more than zero'),
  '21. a zero payment is refused — it records nothing and hides a mistake');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_platform_record_payment(%L, 1000, null, ''bank'', null, %L)',
           pg_temp.sch('City Grammar'),
           (select id from public.platform_invoices
             where school_id = pg_temp.sch('Al-Noor Public School'))),
    'does not belong to this school'),
  '22. and a payment cannot be attached to another school''s invoice, which '
  || 'would silently move that school''s balance');

-- =============================================================================
-- 6. Rule 4 again — the override, and where it is recorded
-- =============================================================================
select public.fn_activate_subscription(
  pg_temp.sch('Iqbal Model School'), 'starter', 6, null,
  'Downgrading at their request', true) as over \gset

select pg_temp.ok(
  (select cycle::text = 'monthly' and months = 6 and amount = 5700
     from public.platform_invoices where school_id = pg_temp.sch('Iqbal Model School')),
  '23. six months on starter is charged monthly — 6 × 950 — not a pro-rated year');

select pg_temp.ok(
  (select note like '%Downgrading at their request%'
      and note like '%300 students against a limit of 100%'
     from public.platform_invoices where school_id = pg_temp.sch('Iqbal Model School')),
  '24. an over-limit renewal keeps the operator''s reason AND states the breach '
  || 'on the invoice, rather than in a log nobody opens');

select pg_temp.ok(
  (select period_start from public.platform_invoices
    where school_id = pg_temp.sch('Iqbal Model School')) = current_date,
  '25. a school whose period already expired renews from TODAY, not from the '
  || 'date it lapsed — otherwise they pay for months they were locked out of');

-- =============================================================================
-- 7. Rule 6 — the audit trail
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.audit_log
    where entity = 'subscriptions' and action = 'subscription_activated'
      and school_id in (select pg_temp.mine())) = 3,
  '26. every activation is audited — it was zero before');

select pg_temp.ok(
  (select actor from public.audit_log
    where entity = 'subscriptions' and school_id = pg_temp.sch('City Grammar'))
    = '00000000-0000-0000-0000-00000000b0d1',
  '27. naming the operator who granted it, so a partner or an assistant can be '
  || 'told apart');

select pg_temp.ok(
  (select actor_role is null from public.audit_log
    where entity = 'subscriptions' and school_id = pg_temp.sch('City Grammar')),
  '28. with a null role — the operator has no profile, and inventing a school '
  || 'role for them would put a non-school identity into a school-scoped enum');

select pg_temp.ok(
  (select (after->>'amount')::numeric = 0 and reason = 'Pilot school, first year free'
     from public.audit_log
    where entity = 'subscriptions' and school_id = pg_temp.sch('City Grammar')),
  '29. and the free year is on the record with its reason');

select pg_temp.ok(
  (select count(*) from public.audit_log where action = 'platform_payment_recorded'
    and school_id in (select pg_temp.mine())) = 1,
  '30. payments are audited too');

-- =============================================================================
-- 8. Rule 5 — the revenue answer
-- =============================================================================
select public.fn_platform_revenue(current_date - 1, current_date + 1) as rev \gset

select pg_temp.ok(
  (:'rev'::jsonb->>'invoiced')::numeric - (:'base'::jsonb->>'invoiced')::numeric = 40700,
  '31. invoiced this period: 35,000 + 0 + 5,700');

select pg_temp.ok(
  (:'rev'::jsonb->>'collected')::numeric - (:'base'::jsonb->>'collected')::numeric = 20000,
  '32. collected: 20,000. Invoiced and collected are different questions and the '
  || 'answer must not conflate them');

select pg_temp.ok(
  (:'rev'::jsonb->>'discounted')::numeric - (:'base'::jsonb->>'discounted')::numeric = 9500,
  '33. and 9,500 was given away — a figure nothing could produce before');

select pg_temp.ok(
  (:'rev'::jsonb->>'outstanding_total')::numeric
    - (:'base'::jsonb->>'outstanding_total')::numeric = 20700,
  '34. outstanding across all schools is 15,000 + 5,700 — everything ever '
  || 'invoiced minus everything ever paid, because a receivable does not belong '
  || 'to the month it was raised in');

select pg_temp.ok(
  (select count(*) from jsonb_array_elements(:'rev'::jsonb->'schools_owing') e
    where e->>'school_name' in ('Al-Noor Public School', 'Iqbal Model School')) = 2,
  '35. and it names who owes it — the "who do I call this morning" list the '
  || 'expiry dates only looked like they were giving');

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(:'rev'::jsonb->'schools_owing') e
               where e->>'school_name' = 'City Grammar'),
  '36. the pilot school is not on the chasing list. A zero invoice must not read '
  || 'as a debt');

select pg_temp.ok(
  pg_temp.raises('select public.fn_platform_revenue(current_date, current_date - 1)',
                 'not before the start'),
  '37. a backwards date range is refused rather than silently returning zeroes');

-- =============================================================================
-- 9. Rule 7 — a school user can read none of it
--
-- As `authenticated`, not as the table owner: RLS does not apply to the owner,
-- so an owner-side check here would pass with no policy at all.
-- =============================================================================
select set_config('test.uid', '00000000-0000-0000-0000-00000000b0d2', false);
set local role authenticated;

select pg_temp.ok(
  -- Platform-wide ON PURPOSE here: the claim is that this user sees NOTHING in
  -- the table, so scoping it to three schools would weaken exactly the assertion
  -- that matters.
  (select count(*) from public.platform_invoices) = 0,
  '38. the school''s own OWNER sees no operator invoices — not even the ones '
  || 'raised against their own school');

select pg_temp.ok(
  (select count(*) from public.platform_payments) = 0,
  '39. nor any payment');

select pg_temp.ok(
  pg_temp.raises('select public.fn_platform_revenue(current_date - 1, current_date)',
                 'not permitted'),
  '40. and cannot ask for the operator''s revenue');

select pg_temp.ok(
  pg_temp.raises('select public.fn_platform_schools()', 'not permitted'),
  '41. nor for the list of every school on the platform');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_platform_outstanding(%L)', pg_temp.sch('Al-Noor Public School')),
    'not permitted'),
  '42. nor what their own school owes — that is a business relationship handled '
  || 'outside the app, deliberately not a tenant surface');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_activate_subscription(%L, ''institution'', 120)',
           pg_temp.sch('Al-Noor Public School')),
    'not permitted'),
  '43. and above all cannot grant itself ten years of the top plan');

-- The one thing they CAN see, and should: their own licence state.
select pg_temp.ok(
  (public.fn_my_licence()->>'status') is not null,
  '44. what a school user does get is its own licence status — the banner keeps '
  || 'working, so locking the books down did not lock out the tenant');

reset role;

-- =============================================================================
-- 10. And the operator still cannot read tenant data
-- =============================================================================
select pg_temp.be_operator();
set local role authenticated;

select pg_temp.ok(
  (select count(*) from public.students) = 0,
  '45. the operator, with every billing power there is, still reads no student');

select pg_temp.ok(
  (select count(*) from public.invoices) = 0 and (select count(*) from public.payments) = 0,
  '46. and none of a school''s own fee invoices or receipts. Adding the '
  || 'operator''s books must not widen the operator''s reach');

reset role;

do $$ begin raise notice 'ALL OPERATOR BILLING TESTS PASSED'; end $$;

rollback;
