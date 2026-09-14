-- =============================================================================
-- Expenses, profit, and what a reversal is worth.
--
-- The rules this file exists to defend:
--
--  1. Fee income CANNOT be hand-entered. There is no function to do it, and
--     no INSERT policy on the ledgers. The only way fee income exists is that
--     a receipt was issued against a real invoice. If someone ever adds an
--     "adjust income" convenience, this file should stop being green.
--  2. Profit = fee income + other income - expenses, cash basis.
--  3. Non-fee income is reported separately and never merged into fee income.
--  4. Money records are append-only. A reversal nets to zero; nothing is
--     edited or deleted.
--
-- Rules 5 to 7 were about the TILL and went with it in 0136. See the note where
-- sections 8 to 12 used to be.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/finance.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- Wrapped in a transaction that is rolled back at the end, like the ten newer
-- suites. It was not, and the "clean slate" delete below hid why: nothing
-- cascades from public.schools — 34 tables reference it with NO ACTION — so on
-- a fresh database that delete matches zero rows and does nothing, while on a
-- second run it fails outright on the profiles foreign key. This suite could
-- therefore only ever be run ONCE per database, and the rows it committed were
-- what made counter.sql pass alone and fail after fee_ops.sql.
begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

do $seed$
declare
  v_school uuid;
  v_owner  uuid := '00000000-0000-0000-0000-0000000000e1';
  v_clerk  uuid := '00000000-0000-0000-0000-0000000000e2';
  v_teach  uuid := '00000000-0000-0000-0000-0000000000e3';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid; v_fam uuid; v_stu uuid;
begin
  perform set_config('test.uid', '', false);
  -- (No "clean slate" delete here. Nothing cascades from public.schools —
  -- 34 tables reference it with NO ACTION — so the delete that used to sit
  -- on this line matched zero rows on a fresh database and failed outright
  -- on a re-run. The suite rolls back instead, which actually works.)

  insert into public.schools (name) values ('Finance Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'e1@fin.test'), (v_clerk, 'e2@fin.test'), (v_teach, 'e3@fin.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner, 'Fin Owner', 'owner', v_school),
    (v_clerk, 'Fin Office', 'principal', v_school),
    (v_teach, 'Fin Teacher', 'class_teacher', v_school)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 2000, v_school);

  insert into public.families (school_id, head_name) values (v_school, 'Test Payer')
    returning id into v_fam;
  insert into public.students (full_name, status, school_id, family_id)
    values ('Fin Child', 'active', v_school, v_fam) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_stu, v_sess, v_class, v_sec, 'active', v_school);

  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-09-01', date '2025-09-10');
  raise notice 'fixture ok';
end $seed$;

-- =============================================================================
-- 1. There is NO way to hand-enter fee income
-- =============================================================================
do $t$
declare v_n integer;
begin
  -- No function whose name suggests it, other than the derived summary.
  select count(*) into v_n from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and (p.proname ilike '%add_fee_income%' or p.proname ilike '%set_fee_income%'
         or p.proname ilike '%record_fee_income%');
  if v_n > 0 then
    raise exception 'FAIL: a function exists to hand-enter fee income';
  end if;

  -- And the expense/income ledgers have no INSERT policy: writes must go
  -- through the guarded functions so nothing skips the voucher counter.
  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename in ('expenses', 'other_income')
      and cmd in ('INSERT', 'ALL')
  ) then
    raise exception 'FAIL: a direct INSERT policy exists on a money ledger';
  end if;
  raise notice '1. fee income cannot be hand-entered — ok';
end $t$;

-- =============================================================================
-- 2. Expenses: gapless vouchers, categories seeded
-- =============================================================================
do $t$
declare v_cat uuid; j jsonb; v_a bigint; v_b bigint;
begin
  select id into v_cat from public.expense_categories
  where school_id = (select id from public.schools where name = 'Finance Test School')
    and name = 'Salaries';
  if v_cat is null then raise exception 'FAIL: default categories were not seeded'; end if;

  j := public.fn_record_expense(50000, v_cat, current_date, 'August salaries', 'cash', null);
  v_a := (j->>'voucher_no')::bigint;
  j := public.fn_record_expense(3000, v_cat, current_date, 'Overtime', 'cash', null);
  v_b := (j->>'voucher_no')::bigint;

  if v_b <> v_a + 1 then
    raise exception 'FAIL: expense vouchers are not gapless (% then %)', v_a, v_b;
  end if;
  raise notice '2. expenses recorded with gapless vouchers — ok';
end $t$;

-- =============================================================================
-- 3. A reversal nets to zero and nothing is deleted
-- =============================================================================
do $t$
declare v_cat uuid; j jsonb; v_id uuid; v_before numeric; v_after numeric; v_rows integer;
begin
  select id into v_cat from public.expense_categories
  where school_id = (select id from public.schools where name = 'Finance Test School')
    and name = 'Rent';

  select (public.fn_finance_summary(current_date, current_date)->>'expenses')::numeric into v_before;

  j := public.fn_record_expense(10000, v_cat, current_date, 'Rent', 'cash', null);
  v_id := (j->>'expense_id')::uuid;
  perform public.fn_reverse_expense(v_id, 'entered twice');

  select (public.fn_finance_summary(current_date, current_date)->>'expenses')::numeric into v_after;
  if v_after <> v_before then
    raise exception 'FAIL: reversal did not net out (% -> %)', v_before, v_after;
  end if;

  select count(*) into v_rows from public.expenses where id = v_id or reversal_of = v_id;
  if v_rows <> 2 then
    raise exception 'FAIL: expected the original AND its reversal to survive, found %', v_rows;
  end if;

  -- and it cannot be reversed twice
  begin
    perform public.fn_reverse_expense(v_id, 'again');
    raise exception 'FAIL: an expense was reversed twice';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice '3. reversal nets to zero, nothing deleted — ok';
end $t$;

-- =============================================================================
-- 4. A reversal without a reason is refused
-- =============================================================================
do $t$
declare v_cat uuid; j jsonb; v_id uuid;
begin
  select id into v_cat from public.expense_categories
  where school_id = (select id from public.schools where name = 'Finance Test School')
    and name = 'Other';
  j := public.fn_record_expense(500, v_cat, current_date, 'x', 'cash', null);
  v_id := (j->>'expense_id')::uuid;
  begin
    perform public.fn_reverse_expense(v_id, '   ');
    raise exception 'FAIL: reversed an expense with a blank reason';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice '4. reversal requires a reason — ok';
end $t$;

-- =============================================================================
-- 5. Profit arithmetic, and fee income kept separate from other income
-- =============================================================================
do $t$
declare
  v_fam uuid; j jsonb; s jsonb;
  v_fee numeric; v_other numeric; v_exp numeric; v_profit numeric;
begin
  select id into v_fam from public.families where head_name = 'Test Payer';
  perform public.fn_record_family_payment(v_fam, 2000, 'cash', 'fee');
  perform public.fn_record_other_income(1500, 'Canteen rent', current_date, 'cash', null);

  s := public.fn_finance_summary(current_date, current_date);
  v_fee    := (s->>'fee_income')::numeric;
  v_other  := (s->>'other_income')::numeric;
  v_exp    := (s->>'expenses')::numeric;
  v_profit := (s->>'profit')::numeric;

  if v_fee <> 2000 then raise exception 'FAIL: fee income should be 2000, got %', v_fee; end if;
  if v_other <> 1500 then raise exception 'FAIL: other income should be 1500, got %', v_other; end if;
  if (s->>'total_income')::numeric <> v_fee + v_other then
    raise exception 'FAIL: total income does not add up';
  end if;
  if v_profit <> v_fee + v_other - v_exp then
    raise exception 'FAIL: profit % <> % + % - %', v_profit, v_fee, v_other, v_exp;
  end if;
  raise notice '5. profit = fee + other - expenses (profit %) — ok', v_profit;
end $t$;

-- =============================================================================
-- 5b. A reversed OTHER INCOME entry leaves income too
--
-- fn_reverse_other_income shipped in 0030 with ZERO callers: no db.ts wrapper,
-- no button, and no test. So a clerk who typed Rs 50,000 of hall rent instead
-- of Rs 5,000 had no way to correct it — the ledger is append-only by design,
-- so there was no edit path either, and the error sat in the income figure, the
-- profit, the day book and the balance sheet permanently.
--
-- Found by supabase/check-reachable.sh, which now fails CI for any function the
-- app may call that nothing anywhere reaches.
-- =============================================================================
do $t$
declare
  v_before numeric; v_after numeric; v_id uuid; j jsonb;
  v_bs_before numeric; v_bs_after numeric;
begin
  select (public.fn_finance_summary(current_date, current_date)->>'other_income')::numeric
    into v_before;
  v_bs_before := (public.fn_report_balance_sheet(current_date)->>'other_income')::numeric;

  j := public.fn_record_other_income(50000, 'Hall rent (typo)', current_date, 'cash', null);
  v_id := (j->>'income_id')::uuid;

  select (public.fn_finance_summary(current_date, current_date)->>'other_income')::numeric
    into v_after;
  if v_after <> v_before + 50000 then
    raise exception 'FAIL: the typo did not land in income (% -> %)', v_before, v_after;
  end if;

  perform public.fn_reverse_other_income(v_id, 'typed 50,000 instead of 5,000');

  select (public.fn_finance_summary(current_date, current_date)->>'other_income')::numeric
    into v_after;
  if v_after <> v_before then
    raise exception 'FAIL: reversed other income still counted (% -> %)', v_before, v_after;
  end if;

  -- And the correction must reach the balance sheet, not just this one screen.
  v_bs_after := (public.fn_report_balance_sheet(current_date)->>'other_income')::numeric;
  if v_bs_after <> v_bs_before then
    raise exception 'FAIL: balance sheet still carries the reversed income (% -> %)',
      v_bs_before, v_bs_after;
  end if;

  -- Append-only: the mistake and its correction are BOTH on the record.
  if (select count(*) from public.other_income
       where source = 'Hall rent (typo)' or reversal_of = v_id) <> 2 then
    raise exception 'FAIL: a reversal must add a row, not edit or delete one';
  end if;

  -- And it cannot be reversed twice, or the income would go negative.
  begin
    perform public.fn_reverse_other_income(v_id, 'again');
    raise exception 'FAIL: other income was reversed twice';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  raise notice '5b. a mistyped other-income entry can be corrected, once — ok';
end $t$;

-- =============================================================================
-- 6. A reversed FEE payment leaves income automatically
-- =============================================================================
do $t$
declare v_fam uuid; j jsonb; v_before numeric; v_after numeric;
begin
  select id into v_fam from public.families where head_name = 'Test Payer';
  select (public.fn_finance_summary(current_date, current_date)->>'fee_income')::numeric into v_before;
  j := public.fn_record_family_payment(v_fam, 700, 'cash', 'oops');
  perform public.fn_reverse_payment((j->>'payment_id')::uuid, 'wrong family');
  select (public.fn_finance_summary(current_date, current_date)->>'fee_income')::numeric into v_after;
  if v_after <> v_before then
    raise exception 'FAIL: reversed payment still counted as income (% -> %)', v_before, v_after;
  end if;
  raise notice '6. reversed payment leaves income — ok';
end $t$;

-- =============================================================================
-- 7. A teacher cannot read the school's cost base
-- =============================================================================
do $t$
declare v_n bigint; v_ok boolean := false;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000e3', false);
  set local role authenticated;
  select count(*) into v_n from public.expenses;
  reset role;
  if v_n > 0 then
    raise exception 'FAIL: a class teacher can read % expense rows', v_n;
  end if;

  begin
    perform public.fn_finance_summary(current_date, current_date);
    v_ok := true;
  exception when others then null;
  end;
  if v_ok then raise exception 'FAIL: a class teacher can read the profit summary'; end if;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000e1', false);
  raise notice '7. teachers cannot see costs or profit — ok';
end $t$;

-- =============================================================================
-- 8-12 WERE THE TILL, AND 0136 REMOVED IT
--
-- They asserted that taking money was never blocked by till bookkeeping, that a
-- drawer which did not balance could not be closed without a reason in either
-- direction, that a closed drawer's variance was frozen, that only an owner or
-- principal signed one off, and that one person had one open drawer.
--
-- All five were properties of a second bookkeeping layer sitting on top of
-- `payments`, and the vendor judged it to have no use in a school whose whole
-- office is one person: for them the count at the end of the day IS the list of
-- receipts, so reconciling one against the other is checking their own
-- arithmetic against itself.
--
-- WHAT SURVIVES THE REMOVAL, and is asserted above and below rather than here:
-- rules 1 to 4 at the top of this file. Fee income still cannot be hand
-- entered, profit is still fee income plus other income minus expenses, other
-- income is still reported separately, and money records are still append only
-- with a reversal netting to zero. None of those ever depended on the till.

-- =============================================================================
-- 13. Cross-tenant: no reading another school's money
-- =============================================================================
do $t$
declare
  v_other uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000e9';
  v_n bigint; s jsonb;
begin
  perform set_config('test.uid', '', false);
  -- (No "clean slate" delete here. Nothing cascades from public.schools —
  -- 34 tables reference it with NO ACTION — so the delete that used to sit
  -- on this line matched zero rows on a fresh database and failed outright
  -- on a re-run. The suite rolls back instead, which actually works.)
  insert into public.schools (name) values ('Other Finance School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'e9@fin.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Other Fin Owner', 'owner', v_other)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  set local role authenticated;
  select count(*) into v_n from public.expenses;
  reset role;
  if v_n > 0 then raise exception 'FAIL: read % expense rows from another school', v_n; end if;

  s := public.fn_finance_summary(current_date, current_date);
  if (s->>'fee_income')::numeric <> 0 or (s->>'expenses')::numeric <> 0 then
    raise exception 'FAIL: another school''s figures leaked into the summary: %', s;
  end if;

  -- The till report was the third cross-tenant read checked here and 0136
  -- removed it. The two above are the ones that matter: the expense rows and
  -- the finance summary are what another school's money actually is.

  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000e1', false);
  raise notice '13. cross-tenant money access refused — ok';
end $t$;

do $$ begin raise notice 'ALL FINANCE TESTS PASSED'; end $$;

rollback;
