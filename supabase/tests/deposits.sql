-- =============================================================================
-- Refundable fees: the money that is not the school's.
--
-- Demonstrated on a real database before 0060 was written. One pupil, one
-- invoice: Rs 2,000 tuition + Rs 5,000 REFUNDABLE security deposit, family pays
-- all 7,000.
--
--   fee_income ................................. 7,000   (should be 2,000)
--   profit ..................................... 7,000   (should be 2,000)
--   balance-sheet liability for the deposit .... 0       (should be 5,000)
--   ways to record a refund .................... none
--   functions reading fee_heads.is_refundable .. none
--
-- A school of 200 pupils on a Rs 5,000 deposit showed ONE MILLION RUPEES of
-- profit that was a liability, and a proprietor pays a salary out of that.
--
-- The rules this file defends:
--
--   1. A DEPOSIT IS NOT INCOME AND NOT PROFIT. Asserted on the exact figures,
--      and on the gross receipt figure being reported ALONGSIDE the net one —
--      because a clerk reconciling against the till counted the gross, and
--      silently replacing one number with another is how a school stops
--      trusting a report.
--   2. IT IS A LIABILITY ON THE BALANCE SHEET, and the retained figure has it
--      taken out.
--   3. A REFUNDABLE CHARGE CANNOT SHARE AN INVOICE with an ordinary fee.
--      payment_allocations allocates to an INVOICE, so a mixed invoice makes
--      "how much deposit was paid" unanswerable. Both insert orders are tested,
--      because a check that only looks one way passes on half a bug.
--   4. NETTING ON LEAVING MOVES THE BALANCE AND NOT THE CASH. Asserted on
--      fn_finance_summary explicitly: a payments row would have put money
--      nobody handed over into the day book and the till.
--   5. A REFUND CANNOT EXCEED WHAT IS HELD, and cannot be repeated to drain it.
--   6. ONLY AN OWNER OR PRINCIPAL MAY REFUND.
--   7. DEPOSITS HELD SURVIVE THE PUPIL LEAVING — that is precisely the money
--      still owed, so the liability must not shrink when a child leaves.
--   8. A SCHOOL WITH NO REFUNDABLE HEAD SEES NO CHANGE AT ALL.
--   9. NOTHING CROSSES A SCHOOL BOUNDARY, in both directions.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/deposits.sql
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

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return position(lower(p_needle) in lower(sqlerrm)) > 0;
end;
$$;

create or replace function pg_temp.stu(p_name text) returns uuid language sql as $$
  select id from public.students
   where school_id = public.current_school_id() and full_name = p_name
$$;
create or replace function pg_temp.head(p_name text) returns uuid language sql as $$
  select id from public.fee_heads
   where school_id = public.current_school_id() and name = p_name
$$;
create or replace function pg_temp.fin(p_key text) returns numeric language sql as $$
  select (public.fn_finance_summary(current_date - 7, current_date + 7)->>p_key)::numeric
$$;
create or replace function pg_temp.bs(p_key text) returns numeric language sql as $$
  select (public.fn_report_balance_sheet(current_date)->>p_key)::numeric
$$;

-- Pay a whole invoice, the way the counter does.
create or replace function pg_temp.pay(p_invoice uuid, p_amount numeric) returns void
language plpgsql as $$
declare v_p uuid; v_s uuid; v_school uuid := public.current_school_id();
begin
  select student_id into v_s from public.invoices where id = p_invoice;
  insert into public.payments (school_id, student_id, amount, method, status)
  values (v_school, v_s, p_amount, 'cash', 'verified') returning id into v_p;
  insert into public.payment_allocations (school_id, payment_id, invoice_id, amount)
  values (v_school, v_p, p_invoice, p_amount);
end;
$$;

-- --- Fixture -----------------------------------------------------------------
-- School A: a tuition head and a REFUNDABLE deposit head, one pupil charged
-- both. School B: same shape, different numbers, and NO refundable head at all,
-- which is what makes assertion 8 meaningful.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000d001';
  v_ca uuid := '00000000-0000-0000-0000-00000000d002';
  v_ob uuid := '00000000-0000-0000-0000-00000000d003';
  v_sess uuid; v_cl uuid; v_stu uuid; v_stu2 uuid; v_enr uuid; v_enr2 uuid;
  v_tuition uuid; v_deposit uuid; v_inv uuid;
  v_sess_b uuid; v_cl_b uuid; v_stu_b uuid; v_enr_b uuid; v_tui_b uuid; v_inv_b uuid;
begin
  insert into public.schools (name) values ('Dep A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Dep B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  insert into auth.users (id, email) values
    (v_oa, 'oa@dep.test'), (v_ca, 'ca@dep.test'), (v_ob, 'ob@dep.test');
  insert into public.profiles (id, school_id, full_name, role, active) values
    (v_oa, v_a, 'Dep Owner A', 'owner', true),
    (v_ca, v_a, 'Dep Clerk A', 'admin_clerk', true),
    (v_ob, v_b, 'Dep Owner B', 'owner', true);

  -- ---- School A ----
  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (school_id, name, is_current)
    values (v_a, '2025-26', true) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (school_id, name, level_order) values (v_a, 'Class 1', 1)
    returning id into v_cl;

  insert into public.fee_heads (school_id, name, type, is_recurring, is_refundable)
    values (v_a, 'Tuition', 'monthly', true, false) returning id into v_tuition;
  insert into public.fee_heads (school_id, name, type, is_recurring, is_refundable)
    values (v_a, 'Security Deposit', 'security_deposit', false, true)
    returning id into v_deposit;

  insert into public.students (school_id, full_name, status)
    values (v_a, 'Deposit Child', 'active') returning id into v_stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    values (v_a, v_stu, v_sess, v_cl, '1', 'active') returning id into v_enr;

  -- A second pupil who pays a deposit and then LEAVES owing money — assertion 7
  -- and the netting assertions run on this one.
  insert into public.students (school_id, full_name, status)
    values (v_a, 'Leaving Child', 'active') returning id into v_stu2;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    values (v_a, v_stu2, v_sess, v_cl, '2', 'active') returning id into v_enr2;

  -- Ordinary tuition of 2,000, paid.
  insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                               period_month, status, due_date, issued_at)
    values (v_a, v_stu, v_enr, v_sess, date_trunc('month', current_date)::date,
            'issued', current_date, now()) returning id into v_inv;
  insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
    values (v_a, v_inv, v_tuition, 'Tuition', 2000);
  perform pg_temp.pay(v_inv, 2000);

  -- ---- School B: NO refundable head anywhere ----
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (school_id, name, is_current)
    values (v_b, '2025-26', true) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (school_id, name, level_order) values (v_b, 'Class 1', 1)
    returning id into v_cl_b;
  insert into public.fee_heads (school_id, name, type, is_recurring, is_refundable)
    values (v_b, 'Tuition', 'monthly', true, false) returning id into v_tui_b;
  insert into public.students (school_id, full_name, status)
    values (v_b, 'Other School Child', 'active') returning id into v_stu_b;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    values (v_b, v_stu_b, v_sess_b, v_cl_b, '1', 'active') returning id into v_enr_b;
  insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                               period_month, status, due_date, issued_at)
    values (v_b, v_stu_b, v_enr_b, v_sess_b, date_trunc('month', current_date)::date,
            'issued', current_date, now()) returning id into v_inv_b;
  insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
    values (v_b, v_inv_b, v_tui_b, 'Tuition', 3333);
  perform pg_temp.pay(v_inv_b, 3333);
end;
$seed$;

-- =============================================================================
-- 1. A refundable charge cannot share an invoice with an ordinary fee
-- =============================================================================
select pg_temp.be('Dep Owner A');

-- Deposit line added to an invoice that already has tuition.
select pg_temp.ok(
  pg_temp.raises(
    format($q$
      do $inner$
      declare v_i uuid;
      begin
        select id into v_i from public.invoices
         where school_id = public.current_school_id()
           and student_id = %L limit 1;
        insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
        values (public.current_school_id(), v_i, %L, 'Sneaky deposit', 5000);
      end $inner$;
    $q$, pg_temp.stu('Deposit Child'), pg_temp.head('Security Deposit')),
    'own challan'),
  '1. a refundable line cannot be added to an invoice that already has tuition');

-- And the other way round. A check that only looks one way passes on half a bug:
-- the trigger counts both kinds, so both orders must be exercised.
select pg_temp.ok(
  pg_temp.raises(
    format($q$
      do $inner$
      declare v_i uuid; v_e uuid; v_s uuid := %L;
      begin
        select id into v_e from public.enrollments
         where school_id = public.current_school_id() and student_id = v_s limit 1;
        insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                                     status, due_date, issued_at)
        values (public.current_school_id(), v_s, v_e,
                (select current_session_id from public.school_settings
                  where school_id = public.current_school_id()),
                'issued', current_date, now())
        returning id into v_i;
        insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
        values (public.current_school_id(), v_i, %L, 'Deposit', 5000);
        insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
        values (public.current_school_id(), v_i, %L, 'Tuition', 2000);
      end $inner$;
    $q$, pg_temp.stu('Deposit Child'), pg_temp.head('Security Deposit'),
         pg_temp.head('Tuition')),
    'own challan'),
  '2. nor an ordinary line to an invoice that already has a deposit — both orders, '
  || 'because a one-way check passes on half a bug');

-- =============================================================================
-- 2. Charging a deposit, on its own invoice by construction
-- =============================================================================
select public.fn_charge_deposit(pg_temp.stu('Deposit Child'),
                                pg_temp.head('Security Deposit'), 5000) as ch \gset

select pg_temp.ok(
  (:'ch'::jsonb->>'amount')::numeric = 5000,
  '3. a deposit can be charged');

select pg_temp.ok(
  (select period_month is null from public.invoices
    where id = (:'ch'::jsonb->>'invoice_id')::uuid),
  '4. the deposit invoice has NO period_month — a once-ever charge must never be '
  || 'picked up by a monthly run or counted as a month the family owes');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_charge_deposit(%L, %L, 5000)',
           pg_temp.stu('Deposit Child'), pg_temp.head('Tuition')),
    'not marked refundable'),
  '5. an ordinary fee head cannot be charged through the deposit path');

select pg_temp.ok(
  public.fn_deposit_held(pg_temp.stu('Deposit Child')) = 0,
  '6. nothing is HELD until the deposit is actually paid — billing is not holding');

-- =============================================================================
-- 3. A deposit is not income and not profit
-- =============================================================================
select pg_temp.ok(pg_temp.fin('fee_income') = 2000,
  '7. before the deposit is paid, income is the 2,000 tuition');

select pg_temp.pay((:'ch'::jsonb->>'invoice_id')::uuid, 5000);

select pg_temp.ok(
  public.fn_deposit_held(pg_temp.stu('Deposit Child')) = 5000,
  '8. once paid, 5,000 is held');

select pg_temp.ok(pg_temp.fin('fee_income') = 2000,
  '9. THE DEFECT: income is STILL 2,000 after a 5,000 deposit lands. It used to '
  || 'become 7,000');

select pg_temp.ok(pg_temp.fin('profit') = 2000,
  '10. and profit is 2,000, not 7,000 — the figure a proprietor pays a salary out of');

select pg_temp.ok(
  pg_temp.fin('fee_receipts_gross') = 7000 and pg_temp.fin('deposits_collected') = 5000,
  '11. BOTH halves are still reported: the 7,000 a clerk counted in the till and '
  || 'the 5,000 excluded from income. Silently replacing one number with another '
  || 'is how a school stops trusting a report');

-- =============================================================================
-- 4. It is a liability on the balance sheet
-- =============================================================================
select pg_temp.ok(pg_temp.bs('deposits_held') = 5000,
  '12. the balance sheet shows 5,000 held — it showed nothing at all before');

select pg_temp.ok(pg_temp.bs('cash_position') = 7000,
  '13. cash is still 7,000. Cash is cash; the deposit does not vanish from the drawer');

select pg_temp.ok(pg_temp.bs('retained') = 2000,
  '14. but RETAINED is 2,000 — cash position minus the money that must go back');

-- =============================================================================
-- 5. Netting on leaving moves the BALANCE and not the CASH
-- =============================================================================
-- Leaving Child: 5,000 deposit paid, then billed 3,000 tuition and never pays it.
select public.fn_charge_deposit(pg_temp.stu('Leaving Child'),
                                pg_temp.head('Security Deposit'), 5000) as ch2 \gset
select pg_temp.pay((:'ch2'::jsonb->>'invoice_id')::uuid, 5000);

do $arrears$
declare v_i uuid; v_e uuid; v_s uuid := pg_temp.stu('Leaving Child');
begin
  select id into v_e from public.enrollments
   where school_id = public.current_school_id() and student_id = v_s limit 1;
  insert into public.invoices (school_id, student_id, enrollment_id, session_id,
                               period_month, status, due_date, issued_at)
  values (public.current_school_id(), v_s, v_e,
          (select current_session_id from public.school_settings
            where school_id = public.current_school_id()),
          date_trunc('month', current_date)::date, 'issued', current_date, now())
  returning id into v_i;
  insert into public.invoice_lines (school_id, invoice_id, fee_head_id, description, amount)
  values (public.current_school_id(), v_i, pg_temp.head('Tuition'), 'Tuition', 3000);
end;
$arrears$;

select pg_temp.ok(
  public.student_balance(pg_temp.stu('Leaving Child')) = 3000,
  '15. the leaving pupil owes 3,000');

select pg_temp.fin('fee_income') as income_before \gset
select pg_temp.fin('fee_receipts_gross') as cash_before \gset

select public.fn_refund_deposit(pg_temp.stu('Leaving Child')) as ref \gset

select pg_temp.ok(
  (:'ref'::jsonb->>'amount')::numeric = 5000
  and (:'ref'::jsonb->>'applied_to_dues')::numeric = 3000
  and (:'ref'::jsonb->>'paid_out')::numeric = 2000,
  '16. 5,000 refunded: 3,000 nets the arrears, 2,000 goes back — exactly what a '
  || 'clerk says at the counter');

select pg_temp.ok(
  public.student_balance(pg_temp.stu('Leaving Child')) = 0,
  '17. the pupil now owes nothing');

select pg_temp.ok(
  pg_temp.fin('fee_receipts_gross') = :'cash_before'::numeric,
  '18. AND THE CASH FIGURE DID NOT MOVE. A payments row would have put 3,000 that '
  || 'nobody handed over into the day book and the till, and the drawer would not '
  || 'have balanced. The netting is an adjustment');

select pg_temp.ok(
  public.fn_deposit_held(pg_temp.stu('Leaving Child')) = 0,
  '19. and nothing is held for them any more');

select pg_temp.ok(
  (select applied_to_dues + paid_out = amount from public.deposit_refunds
    where student_id = pg_temp.stu('Leaving Child')),
  '20. the refund row''s two halves sum to the whole — enforced by a constraint, '
  || 'so a refund can never be recorded that does not add up');

-- =============================================================================
-- 6. A refund cannot exceed what is held, or be repeated to drain it
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_refund_deposit(%L, 9999)', pg_temp.stu('Deposit Child')),
    'cannot exceed'),
  '21. a refund larger than the amount held is refused, and the message says how '
  || 'much is held');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_refund_deposit(%L)', pg_temp.stu('Leaving Child')),
    'no refundable deposit'),
  '22. a second full refund is refused — the ledger cannot be drained by repeating');

-- Partial, then the rest, then no more.
select public.fn_refund_deposit(pg_temp.stu('Deposit Child'), 2000, false) as p1 \gset
select pg_temp.ok(
  public.fn_deposit_held(pg_temp.stu('Deposit Child')) = 3000,
  '23. a partial refund of 2,000 leaves 3,000 held');
select public.fn_refund_deposit(pg_temp.stu('Deposit Child'), 3000, false) as p2 \gset
select pg_temp.ok(
  public.fn_deposit_held(pg_temp.stu('Deposit Child')) = 0
  and pg_temp.raises(
    format('select public.fn_refund_deposit(%L, 1)', pg_temp.stu('Deposit Child')),
    'no refundable deposit'),
  '24. and the last rupee out closes it — partial refunds cannot overdraw in total');

select pg_temp.ok(
  (select was_enrolled from public.deposit_refunds
    where student_id = pg_temp.stu('Deposit Child') limit 1),
  '25. refunding a pupil who is STILL ENROLLED is allowed and FLAGGED — refusing '
  || 'outright would push a school into booking it as an expense, where it would '
  || 'vanish from the deposit ledger entirely');

-- =============================================================================
-- 7. Only an owner or principal may refund
-- =============================================================================
select public.fn_charge_deposit(pg_temp.stu('Deposit Child'),
                                pg_temp.head('Security Deposit'), 1000) as ch3 \gset
select pg_temp.pay((:'ch3'::jsonb->>'invoice_id')::uuid, 1000);

select pg_temp.be('Dep Clerk A');
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_refund_deposit(%L, 500)', pg_temp.stu('Deposit Child')),
    'only an owner or principal'),
  '26. a clerk cannot refund — money leaving the school is an approval, not a '
  || 'clerical act');

select pg_temp.ok(
  public.fn_deposit_held(pg_temp.stu('Deposit Child')) = 1000,
  '27. but a clerk CAN see what is held, so they can answer a parent at the counter');

select pg_temp.ok(
  (select count(*) from public.fn_deposits_held()) >= 1,
  '28. and can read the report of what the school is holding');

select pg_temp.be('Dep Owner A');

-- =============================================================================
-- 8. What is held survives the pupil leaving
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.fn_deposits_held()
    where full_name = 'Deposit Child' and held = 1000) = 1,
  '29. the report lists the pupil and the 1,000 still held');

select public.fn_set_student_status(pg_temp.stu('Deposit Child'), 'withdrawn',
                                    'Family moved city', current_date);

select pg_temp.ok(
  (select count(*) from public.fn_deposits_held()
    where full_name = 'Deposit Child' and held = 1000) = 1,
  '30. AND STILL LISTS THEM AFTER THEY LEAVE. That is precisely the money the '
  || 'school still owes; a liability that shrank when a child left would be the '
  || 'same mistake the balance sheet already avoids for arrears');

select pg_temp.ok(pg_temp.bs('deposits_held') = 1000,
  '31. and the balance-sheet liability still carries it');

-- =============================================================================
-- 9. A school with no refundable head sees no change at all
-- =============================================================================
select pg_temp.be('Dep Owner B');

select pg_temp.ok(
  pg_temp.fin('fee_income') = 3333
  and pg_temp.fin('deposits_collected') = 0
  and pg_temp.fin('profit') = 3333,
  '32. school B has no refundable head, so income and profit are exactly what they '
  || 'always were. NOTHING moves until a school deliberately marks a head '
  || 'refundable — the property that makes this safe to ship to a live database');

select pg_temp.ok(
  pg_temp.bs('deposits_held') = 0 and pg_temp.bs('retained') = pg_temp.bs('cash_position'),
  '33. and its retained figure equals its cash position, as before');

-- =============================================================================
-- 10. Nothing crosses a school boundary, in both directions
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.fn_deposits_held()) = 0,
  '34. school B''s deposits report is empty — it cannot see school A''s deposits');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_refund_deposit(%L, 100)',
           (select s.id from public.students s
             where s.full_name = 'Leaving Child')),
    'not found in this school'),
  '35. school B cannot refund school A''s pupil');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_charge_deposit(%L, %L, 100)',
           (select s.id from public.students s where s.full_name = 'Leaving Child'),
           (select h.id from public.fee_heads h where h.name = 'Security Deposit')),
    'not found in this school'),
  '36. nor charge one');

select pg_temp.ok(
  public.fn_deposit_held((select s.id from public.students s
                           where s.full_name = 'Leaving Child')) = 0,
  '37. and asking what school A holds for its own pupil returns nothing to school B');

select pg_temp.be('Dep Owner A');
select pg_temp.ok(
  not exists (select 1 from public.fn_deposits_held() where full_name = 'Other School Child'),
  '38. and the reverse: school A cannot see school B''s pupils — a filter scoped to '
  || 'whichever school was created first passes one way only');

-- As `authenticated`, so RLS is actually in force. The first version of this
-- selected as the table owner, which BYPASSES RLS entirely — it would have
-- passed just as happily with no policy on the table at all, and it counted
-- both schools' rows. A negative assertion needs the role that the policy
-- applies to; that is the same trap this project documented in
-- tenant_isolation.sql and it still caught me here.
set local role authenticated;
select pg_temp.ok(
  (select count(*) from public.deposit_refunds) = 3
  and not exists (select 1 from public.deposit_refunds
                   where school_id <> public.current_school_id()),
  '39. under RLS, school A sees exactly its own three refund rows and none of '
  || 'school B''s — asserted as `authenticated`, because as the table owner RLS '
  || 'does not apply and this would pass with no policy at all');
reset role;

rollback;
