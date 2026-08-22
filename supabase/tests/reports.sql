-- =============================================================================
-- The reporting area: do the statements agree with the ledger they describe?
--
-- The rules this file defends:
--
--  1. The debit-and-credit statement RECONCILES with fn_finance_summary. Two
--     screens showing different totals for the same month is the single fastest
--     way to lose a school's trust, and there is no reason for it — both derive
--     from the same rows.
--  2. Only VERIFIED money is income. A pending bank transfer in a statement
--     overstates what the school has.
--  3. A reversal appears as its own row rather than being netted away. A
--     statement that quietly hides a cancelled receipt is what a dishonest
--     clerk would want.
--  4. "Unpaid invoices" is per CHALLAN, with a real overdue age, and excludes
--     the paid and the void.
--  5. The discount report names the approver. A discount register without one
--     is just a list of holes in the income.
--  6. Nothing crosses a school boundary, and the money reports follow the same
--     role boundary as fn_finance_summary rather than a looser one.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/reports.sql
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

create or replace function pg_temp.sess() returns uuid language sql as $$
  select id from public.academic_sessions
   where school_id = public.current_school_id() and is_current limit 1
$$;

-- --- Fixture -----------------------------------------------------------------
-- One school with: two students billed Rs 2,000 each, one full payment, one
-- pending payment, one payment that gets reversed, one expense, one other
-- income, and one approved discount. Plus a second school with big numbers.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000ca01';
  v_cl uuid := '00000000-0000-0000-0000-00000000ca02';
  v_ac uuid := '00000000-0000-0000-0000-00000000ca03';
  v_ob uuid := '00000000-0000-0000-0000-00000000ca04';
  v_sess uuid; v_class uuid; v_head uuid; v_cat uuid;
  v_stu uuid; v_stu2 uuid; v_enr uuid; v_pay jsonb;
begin
  insert into public.schools (name) values ('Rep A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Rep B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'rpa@rep.test'), (v_cl, 'rpc@rep.test'),
    (v_ac, 'rpx@rep.test'), (v_ob, 'rpb@rep.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Rep Owner',      'owner',       v_a),
    (v_cl, 'Rep Clerk',      'admin_clerk', v_a),
    (v_ac, 'Rep Accountant', 'accountant',  v_a),
    (v_ob, 'Other Owner',    'owner',       v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Rep Class', 1, v_a) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 2000, v_a);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'RP Paid', 'father_name', 'Paid Father', 'father_cnic', '35201-1010101-1',
    'session_id', v_sess, 'class_id', v_class, 'roll_no', '1', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'RP Owing', 'father_name', 'Owing Father', 'father_cnic', '35201-2020202-2',
    'session_id', v_sess, 'class_id', v_class, 'roll_no', '2', 'links', '[]'::jsonb));

  -- Billed with a due date in the past, so days_overdue is exercised.
  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date - 5);

  select id into v_stu  from public.students where full_name = 'RP Paid';
  select id into v_stu2 from public.students where full_name = 'RP Owing';

  perform public.fn_record_payment(v_stu, 2000, 'cash', 'settled in full', false);
  -- Pending: must not appear as income.
  perform public.fn_record_payment(v_stu2, 500, 'bank_transfer', 'not cleared', true);
  -- Reversed: must appear as its own row, not vanish.
  v_pay := public.fn_record_payment(v_stu2, 300, 'cash', 'taken in error', false);
  perform public.fn_reverse_payment((v_pay->>'payment_id')::uuid, 'wrong student');

  select id into v_cat from public.expense_categories where school_id = v_a limit 1;
  perform public.fn_record_expense(750, v_cat, current_date, 'Stationers', 'cash', 'Registers');
  perform public.fn_record_other_income(400, 'Hall rent', current_date, 'cash');

  -- An approved discount, so the discount report has an approver to show.
  select id into v_enr from public.enrollments where student_id = v_stu2 limit 1;
  insert into public.discounts (enrollment_id, type, amount, is_percent, reason,
                                status, created_by, approved_by, approved_at, school_id)
  values (v_enr, 'sibling', 10, true, 'Second child', 'approved', v_oa, v_oa, now(), v_a);

  -- School B, deliberately larger.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Rep Class', 1, v_b) returning id into v_class;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'RP Foreign', 'father_name', 'Foreign Father',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  select id into v_stu from public.students where full_name = 'RP Foreign';
  perform public.fn_record_payment(v_stu, 99000, 'cash', 'school B money', false);
end $seed$;

-- =============================================================================
-- 1-5: the ledger
-- =============================================================================
do $t$
declare v_debit numeric; v_credit numeric; v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca01', false);

  select sum(debit), sum(credit) into v_debit, v_credit
  from public.fn_report_ledger(current_date - 5, current_date, 'all');

  -- 2000 fee + 400 other income; the 300 reversal contributes +300 and -300 as
  -- two rows, so the debit side is 2000 + 400 + 300 = 2700.
  perform pg_temp.ok(v_debit = 2700,
    '1. money in is the verified receipts plus other income (' || v_debit || ')');
  perform pg_temp.ok(v_credit = 1050,
    '2. money out is the expense plus the reversed receipt (' || v_credit || ')');

  -- The pending Rs 500 must be nowhere.
  perform pg_temp.ok(not exists (
    select 1 from public.fn_report_ledger(current_date - 5, current_date, 'all')
     where particulars = 'not cleared' or debit = 500),
    '3. an uncleared bank transfer is not in the statement at all');

  -- The reversal is visible, not netted.
  perform pg_temp.ok(exists (
    select 1 from public.fn_report_ledger(current_date - 5, current_date, 'all')
     where is_reversal),
    '4. the reversed receipt appears as its own row rather than vanishing');

  select count(*) into v_n from public.fn_report_ledger(current_date - 5, current_date, 'expense');
  perform pg_temp.ok(
    v_n = (select count(*) from public.fn_report_ledger(current_date - 5, current_date, 'all')
            where kind = 'expense'),
    '5. the expense-only filter matches the expense rows of the full statement');
end $t$;

-- =============================================================================
-- 6: THE RECONCILIATION — the statement must agree with the summary screen
-- =============================================================================
do $t$
declare v_net numeric; v_sum jsonb; v_sum_net numeric;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca01', false);

  select sum(debit) - sum(credit) into v_net
  from public.fn_report_ledger(date_trunc('month', current_date)::date, current_date, 'all');

  v_sum := public.fn_finance_summary(date_trunc('month', current_date)::date, current_date);
  v_sum_net := (v_sum->>'profit')::numeric;

  perform pg_temp.ok(v_net = v_sum_net,
    '6. the statement nets to the same profit the Accounts screen shows ('
      || v_net || ' vs ' || v_sum_net || ')');
end $t$;

-- =============================================================================
-- 7-10: unpaid invoices
-- =============================================================================
do $t$
declare r record; v_n int; v_inv uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca01', false);

  select count(*) into v_n from public.fn_report_unpaid_invoices(pg_temp.sess());
  perform pg_temp.ok(v_n = 1,
    '7. one unpaid challan — the settled one is out (' || v_n || ')');

  select * into r from public.fn_report_unpaid_invoices(pg_temp.sess()) limit 1;
  perform pg_temp.ok(r.student_name = 'RP Owing', '8. and it is the right child');
  perform pg_temp.ok(r.days_overdue = 5,
    '9. with a real overdue age, not a flag (' || r.days_overdue || ' days)');
  perform pg_temp.ok(r.voucher_code is not null,
    '10. and the voucher code, so the slip can be reprinted from the report');

  -- A void challan must not be chased.
  select invoice_id into v_inv from public.fn_report_unpaid_invoices(pg_temp.sess()) limit 1;
  update public.invoices set status = 'void' where id = v_inv;
  select count(*) into v_n from public.fn_report_unpaid_invoices(pg_temp.sess());
  perform pg_temp.ok(v_n = 0, '11. a voided challan drops out of the list');
  update public.invoices set status = 'issued' where id = v_inv;
end $t$;

-- =============================================================================
-- 12-13: discounts and admissions
-- =============================================================================
do $t$
declare r record; v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca01', false);

  select * into r from public.fn_report_discounts(null, null) limit 1;
  perform pg_temp.ok(r.approved_by = 'Rep Owner' and r.reason_type = 'sibling',
    '12. the discount report names the approver and the reason type');

  select count(*) into v_n from public.fn_report_admissions(null, null);
  perform pg_temp.ok(v_n = 2, '13. both admissions are listed (' || v_n || ')');
end $t$;

-- =============================================================================
-- 14-16: cross-tenant
-- =============================================================================
do $t$
declare v_debit numeric; v_n int; v_foreign_sess uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca01', false);

  select coalesce(sum(debit), 0) into v_debit
  from public.fn_report_ledger(current_date - 5, current_date, 'all');
  perform pg_temp.ok(v_debit = 2700,
    '14. school B''s Rs 99,000 is not in A''s statement (' || v_debit || ')');

  perform pg_temp.ok(not exists (
    select 1 from public.fn_report_admissions(null, null) where student_name = 'RP Foreign'),
    '15. nor is B''s student in A''s admission report');

  select id into v_foreign_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Rep B') limit 1;
  begin
    perform count(*) from public.fn_report_unpaid_invoices(v_foreign_sess);
    raise exception 'FAIL  16. read another school''s unpaid invoices';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  16. a foreign session id is refused (%)', sqlerrm;
  end;
end $t$;

-- =============================================================================
-- 17-20: who may read the money
-- =============================================================================
do $t$
begin
  -- An accountant is exactly who this is for.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca03', false);
  perform pg_temp.ok(
    (select count(*) from public.fn_report_ledger(current_date - 5, current_date, 'all')) > 0,
    '17. an accountant can read the statement');

  -- A clerk collects money; they do not audit it. Same boundary as
  -- fn_finance_summary, deliberately not a looser one.
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca02', false);
  begin
    perform count(*) from public.fn_report_ledger(current_date - 5, current_date, 'all');
    raise exception 'FAIL  18. a clerk read the debit and credit statement';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  18. a clerk cannot read the statement (%)', sqlerrm;
  end;

  begin
    perform count(*) from public.fn_report_discounts(null, null);
    raise exception 'FAIL  19. a clerk read the discount report';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  19. nor the discount report (%)', sqlerrm;
  end;

  -- But a clerk SHOULD see which challans are unpaid — that is their job.
  perform pg_temp.ok(
    (select count(*) from public.fn_report_unpaid_invoices(pg_temp.sess())) >= 0,
    '20. a clerk can still see which challans are unpaid');
end $t$;

-- =============================================================================
-- 21-22: the date range is validated rather than silently wrong
-- =============================================================================
do $t$
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000ca01', false);
  begin
    perform count(*) from public.fn_report_ledger(current_date, current_date - 10, 'all');
    raise exception 'FAIL  21. a backwards date range was accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  21. a backwards date range is refused (%)', sqlerrm;
  end;

  begin
    perform count(*) from public.fn_report_ledger(null, current_date, 'all');
    raise exception 'FAIL  22. a missing start date was accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  22. a missing date is refused rather than defaulted (%)', sqlerrm;
  end;
end $t$;

do $$ begin raise notice '--- reports.sql: all assertions passed'; end $$;

rollback;
