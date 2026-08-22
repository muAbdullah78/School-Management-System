-- =============================================================================
-- The balance sheet: does the position AS AT a date tell the truth?
--
-- Every other money report answers "what happened between two dates". This one
-- answers "what did the school stand at on this day", which is a different and
-- much easier question to get quietly wrong, because the obvious implementation
-- — call student_balance() and sum it — ignores dates entirely and reports
-- today's position under yesterday's heading.
--
-- The rules this file defends:
--
--  1. A DATE BEFORE ANY RECORD IS ALL ZEROS. Not today's numbers with an old
--     date printed on top.
--  2. THE STATEMENT NEVER CONTRADICTS ITSELF. There is no date on which
--     receivable is zero while students_owing is above zero. The first cut of
--     this report failed exactly here: the money was as-at, the headcount was
--     current.
--  3. MONEY PAID EARLY FOR A LATER MONTH IS A LIABILITY, NOT INCOME. A parent
--     paying August in July has not settled an August charge that does not
--     exist yet. Getting this wrong makes a school that collects advance fees
--     look like it owes nobody anything. This is the load-bearing test.
--  4. IT RECONCILES WITH THE STUDENT LEDGER. As at a date after every invoice
--     and payment, receivable equals the sum of student_balance() across every
--     student. A clerk who checks one screen against the other must not find
--     two different numbers.
--  5. ONLY VERIFIED MONEY COUNTS, AND A REVERSAL UNDOES ITSELF.
--  6. A LEAVER'S ARREARS DO NOT VANISH. They stay in receivable and are named
--     in receivable_off_roll, rather than being silently dropped with the
--     student.
--  7. Nothing crosses a school boundary, and the role boundary is the same one
--     fn_finance_summary uses — not a looser one.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/balance_sheet.sql
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

-- Money compared with a tolerance, because these are numeric(12,2) sums and an
-- exact-equality failure on a rounding artefact would be a false alarm.
create or replace function pg_temp.eq(p_a numeric, p_b numeric) returns boolean
language sql immutable as $$ select abs(coalesce(p_a,0) - coalesce(p_b,0)) < 0.005 $$;

create or replace function pg_temp.bs(p_as_at date) returns jsonb
language sql as $$ select public.fn_report_balance_sheet(p_as_at) $$;

create or replace function pg_temp.n(p_as_at date, p_key text) returns numeric
language sql as $$ select (public.fn_report_balance_sheet(p_as_at)->>p_key)::numeric $$;

-- --- Fixture -----------------------------------------------------------------
-- School A, tuition Rs 3,000/month, four children:
--
--   BS Owing    billed this month, nothing paid          -> owes 3,000
--   BS Part     billed this month, paid 1,000            -> owes 2,000
--   BS Advance  billed this month AND next month, paid 6,000 today.
--               Next month's challan is issued next month, so as at today
--               3,000 is settled and 3,000 is an advance.
--   BS Left     billed this month, nothing paid, then withdrawn
--
-- Plus one fine, one adjustment, one pending payment, one reversed payment, one
-- expense, one other income, and one future-dated expense that must not count.
-- School B carries deliberately large numbers so any leak is obvious.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa  uuid := '00000000-0000-0000-0000-00000000b5a1';
  v_cl  uuid := '00000000-0000-0000-0000-00000000b5a2';
  v_ac  uuid := '00000000-0000-0000-0000-00000000b5a3';
  v_ro  uuid := '00000000-0000-0000-0000-00000000b5a4';
  v_ob  uuid := '00000000-0000-0000-0000-00000000b5a5';
  v_sess uuid; v_class uuid; v_head uuid; v_cat uuid;
  v_sess_b uuid; v_class_b uuid; v_head_b uuid;
  v_owing uuid; v_part uuid; v_adv uuid; v_left uuid;
  v_inv_next uuid; v_pay jsonb;
  v_next date := (date_trunc('month', current_date) + interval '1 month')::date;
begin
  insert into public.schools (name) values ('BS A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('BS B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'bsa@bs.test'), (v_cl, 'bsc@bs.test'), (v_ac, 'bsx@bs.test'),
    (v_ro, 'bsr@bs.test'), (v_ob, 'bsb@bs.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'BS Owner',      'owner',       v_a),
    (v_cl, 'BS Clerk',      'admin_clerk', v_a),
    (v_ac, 'BS Accountant', 'accountant',  v_a),
    (v_ro, 'BS Readonly',   'readonly',    v_a),
    (v_ob, 'BS Other',      'owner',       v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  -- ---------------- School A ----------------
  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('BS Class', 1, v_a) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 3000, v_a);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BS Owing', 'father_name', 'F1', 'father_cnic', '35201-1000001-1',
    'session_id', v_sess, 'class_id', v_class, 'roll_no', '1', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BS Part', 'father_name', 'F2', 'father_cnic', '35201-1000002-2',
    'session_id', v_sess, 'class_id', v_class, 'roll_no', '2', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BS Advance', 'father_name', 'F3', 'father_cnic', '35201-1000003-3',
    'session_id', v_sess, 'class_id', v_class, 'roll_no', '3', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'BS Left', 'father_name', 'F4', 'father_cnic', '35201-1000004-4',
    'session_id', v_sess, 'class_id', v_class, 'roll_no', '4', 'links', '[]'::jsonb));

  select id into v_owing from public.students where full_name = 'BS Owing';
  select id into v_part  from public.students where full_name = 'BS Part';
  select id into v_adv   from public.students where full_name = 'BS Advance';
  select id into v_left  from public.students where full_name = 'BS Left';

  -- This month's challans, issued today.
  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);

  -- Next month's challans. fn_generate_class_invoices stamps issued_at = now(),
  -- so the fixture backdates it to the 1st of next month: that is when a real
  -- school issues them, and it is the whole point of the advance test.
  perform public.fn_generate_class_invoices(v_sess, v_class, v_next, v_next + 10);
  update public.invoices set issued_at = v_next::timestamptz
   where school_id = v_a and period_month = v_next;

  -- Paid in full for both months, today. As at today only this month's charge
  -- exists, so half of it is an advance.
  perform public.fn_record_payment(v_adv, 6000, 'cash', 'two months up front', false);
  perform public.fn_record_payment(v_part, 1000, 'cash', 'part payment', false);

  -- Neither of these is money the school has: pending has not cleared, and the
  -- reversal cancels itself out.
  perform public.fn_record_payment(v_owing, 500, 'bank_transfer', 'not cleared', true);
  v_pay := public.fn_record_payment(v_owing, 700, 'cash', 'taken in error', false);
  perform public.fn_reverse_payment((v_pay->>'payment_id')::uuid, 'wrong child');

  -- A fine and an adjustment, so both legs of the charge side are exercised.
  update public.invoices set fine = 100
   where student_id = v_owing and period_month = date_trunc('month', current_date)::date;
  insert into public.adjustments (student_id, amount, reason, created_by, school_id)
    values (v_part, 50, 'late slip', v_oa, v_a);

  select id into v_cat from public.expense_categories where school_id = v_a limit 1;
  perform public.fn_record_expense(250, v_cat, current_date, 'Shop', 'cash', 'Chalk');
  perform public.fn_record_other_income(500, 'Canteen', current_date, 'cash');
  -- Dated after every as-at date this file asks about: must never be counted.
  perform public.fn_record_expense(99999, v_cat, current_date + 60, 'Later', 'cash', 'Future');

  -- BS Left leaves owing 3,000. The arrears must survive the withdrawal.
  update public.students set status = 'withdrawn' where id = v_left;

  -- ---------------- School B, big numbers ----------------
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B Class', 1, v_b) returning id into v_class_b;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_b) returning id into v_head_b;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess_b, v_class_b, v_head_b, 500000, v_b);
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'B Rich', 'father_name', 'FB', 'father_cnic', '35201-2000001-1',
    'session_id', v_sess_b, 'class_id', v_class_b, 'roll_no', '1', 'links', '[]'::jsonb));
  perform public.fn_generate_class_invoices(v_sess_b, v_class_b,
    date_trunc('month', current_date)::date, current_date + 10);
  perform public.fn_record_other_income(777777, 'B donation', current_date, 'cash');

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. A date before the school existed
-- =============================================================================
do $$
declare r jsonb := pg_temp.bs(current_date - 400);
begin
  perform pg_temp.ok(pg_temp.eq((r->>'receivable')::numeric, 0)
                 and pg_temp.eq((r->>'cash_in')::numeric, 0)
                 and pg_temp.eq((r->>'cash_out')::numeric, 0)
                 and pg_temp.eq((r->>'advance_held')::numeric, 0)
                 and (r->>'students_on_roll')::int = 0
                 and (r->>'students_owing')::int = 0,
    '1  a date before any record is all zeros, not today under an old heading');
  perform pg_temp.ok((r->>'as_at') = (current_date - 400)::text,
    '2  the as-at date is echoed back, so a printed sheet cannot be misread');
end $$;

-- =============================================================================
-- 2. Today's position
--
-- Charges this month: 4 x 3,000 = 12,000, plus a 100 fine and a 50 adjustment
-- = 12,150. Allocated against this month: 3,000 (Advance) + 1,000 (Part)
-- = 4,000. The pending 500 allocates nothing; the reversed 700 nets out.
-- Receivable = 12,150 - 4,000 = 8,150.
-- =============================================================================
do $$
declare r jsonb := pg_temp.bs(current_date);
begin
  perform pg_temp.ok(pg_temp.eq((r->>'charges_raised')::numeric, 12150),
    '3  charges raised counts fees, fines and adjustments issued by the date');
  perform pg_temp.ok(pg_temp.eq((r->>'allocated')::numeric, 4000),
    '4  only payments against invoices issued by the date are allocated');
  perform pg_temp.ok(pg_temp.eq((r->>'receivable')::numeric, 8150),
    '5  receivable = charges issued by the date less payments against them');
end $$;

-- =============================================================================
-- 3. THE LOAD-BEARING ONE — advance fees
--
-- BS Advance paid 6,000 today for July and August. As at today, August's
-- challan is not issued, so 3,000 is money the school is HOLDING, not income.
-- Getting this wrong makes a school that collects in advance look like it has
-- no liability at all.
-- =============================================================================
do $$
declare r jsonb := pg_temp.bs(current_date);
begin
  perform pg_temp.ok(pg_temp.eq((r->>'advance_held')::numeric, 3000),
    '6  money paid early for a later month is held as an advance, not income');
  -- The other half of the same rule: it must not have reduced receivable.
  perform pg_temp.ok(pg_temp.eq((r->>'receivable')::numeric, 8150),
    '7  an early payment does not settle a charge that has not been raised');
end $$;

-- Once next month's challans ARE issued, the advance turns into a settlement
-- and the liability disappears. Same rows, later date, opposite answer.
do $$
declare
  r jsonb := pg_temp.bs((date_trunc('month', current_date)
                          + interval '1 month' + interval '5 days')::date);
begin
  perform pg_temp.ok(pg_temp.eq((r->>'advance_held')::numeric, 0),
    '8  once the later challan is issued the advance becomes a settlement');
  -- Next month adds 4 x 3,000; the held 3,000 now settles one of them.
  perform pg_temp.ok(pg_temp.eq((r->>'charges_raised')::numeric, 24150)
                 and pg_temp.eq((r->>'allocated')::numeric, 7000)
                 and pg_temp.eq((r->>'receivable')::numeric, 17150),
    '9  the same rows give a different, larger receivable a month later');
end $$;

-- =============================================================================
-- 4. The statement never contradicts itself
--
-- This is the failure the per-student rewrite exists to prevent: money summed
-- as-at while the headcount came from student_balance(), which is current. It
-- is checked across a range of dates rather than one, because the bug only
-- showed up on dates before billing started.
-- =============================================================================
do $$
declare
  d date;
  r jsonb;
begin
  for d in select generate_series(current_date - 40, current_date + 40, '5 days')::date loop
    r := pg_temp.bs(d);
    if pg_temp.eq((r->>'receivable')::numeric, 0) and (r->>'students_owing')::int > 0 then
      raise exception 'FAIL  10  as at %: receivable 0 but % students owing', d,
        r->>'students_owing';
    end if;
    if (r->>'students_owing')::int > (r->>'students_on_roll')::int then
      raise exception 'FAIL  10  as at %: more students owing than on the roll', d;
    end if;
  end loop;
  raise notice 'PASS  10 no date reports zero receivable while students owe, or more owing than enrolled';
end $$;

-- =============================================================================
-- 5. Reconciliation with the student ledger
--
-- As at a date after every invoice and payment, this report and the per-student
-- ledger must agree. Summed over EVERY student, including the withdrawn one:
-- their arrears are still owed.
-- =============================================================================
do $$
declare
  v_as_at date := (date_trunc('month', current_date) + interval '2 months')::date;
  v_ledger numeric;
  v_sheet  numeric := pg_temp.n(v_as_at, 'receivable');
begin
  select coalesce(sum(public.student_balance(s.id)), 0) into v_ledger
  from public.students s where s.school_id = public.current_school_id();
  perform pg_temp.ok(pg_temp.eq(v_sheet, v_ledger),
    format('11 receivable (%s) equals the sum of every student ledger (%s)',
           v_sheet, v_ledger));
end $$;

-- =============================================================================
-- 6. Cash
-- =============================================================================
do $$
declare r jsonb := pg_temp.bs(current_date);
begin
  -- Fee receipts: 6,000 + 1,000 = 7,000. Pending 500 is not money in hand;
  -- the 700 and its reversal cancel.
  perform pg_temp.ok(pg_temp.eq((r->>'fee_receipts')::numeric, 7000),
    '12 only verified receipts are cash; pending is not, and a reversal cancels');
  perform pg_temp.ok(pg_temp.eq((r->>'other_income')::numeric, 500),
    '13 other income is counted by the day it was received');
  perform pg_temp.ok(pg_temp.eq((r->>'cash_in')::numeric, 7500)
                 and pg_temp.eq((r->>'cash_out')::numeric, 250),
    '14 cash in is fees plus other income; the future-dated expense is excluded');
  perform pg_temp.ok(pg_temp.eq((r->>'cash_position')::numeric, 7250),
    '15 cash position is in less out, and the arithmetic is internally consistent');
end $$;

-- The advance is a real claim on that cash: it must be smaller than the cash
-- the school is sitting on, or the report is telling the principal they hold
-- money they have already spent without saying so.
do $$
declare r jsonb := pg_temp.bs(current_date);
begin
  perform pg_temp.ok((r->>'advance_held')::numeric <= (r->>'fee_receipts')::numeric,
    '16 an advance can never exceed the fee money actually taken');
  perform pg_temp.ok((r->>'advance_held')::numeric >= 0,
    '17 advance held is never negative — a negative liability is unreadable');
end $$;

-- =============================================================================
-- 7. A leaver's arrears do not vanish with the student
-- =============================================================================
do $$
declare r jsonb := pg_temp.bs(current_date);
begin
  -- BS Left owes 3,000 and is withdrawn: off the roll, still owed.
  perform pg_temp.ok(pg_temp.eq((r->>'receivable_off_roll')::numeric, 3000),
    '18 a withdrawn child''s arrears are named, not silently dropped');
  perform pg_temp.ok((r->>'students_on_roll')::int = 3,
    '19 the withdrawn child is off the roll count');
  perform pg_temp.ok((r->>'students_owing')::int = 2,
    '20 students owing counts on-roll debtors only (Owing and Part, not Left)');
end $$;

-- A student re-enrolled into a second session while the first enrollment is
-- still active must be ONE debtor, not two. A balance sheet spans every
-- session, so counting enrollment rows would double him.
do $$
declare
  v_school uuid := public.current_school_id();
  v_stu    uuid;
  v_class  uuid;
  v_sess2  uuid;
  v_before int := (pg_temp.bs(current_date)->>'students_owing')::int;
  v_after  int;
begin
  select id into v_stu   from public.students where full_name = 'BS Owing';
  select id into v_class from public.classes  where name = 'BS Class';
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2026-2027', false, v_school) returning id into v_sess2;
  insert into public.enrollments (student_id, session_id, class_id, roll_no, status, school_id)
    values (v_stu, v_sess2, v_class, '1', 'active', v_school);

  v_after := (pg_temp.bs(current_date)->>'students_owing')::int;
  perform pg_temp.ok(v_after = v_before,
    '21 a student active in two sessions is counted once, not twice');
end $$;

-- =============================================================================
-- 8. Tenant isolation
-- =============================================================================
do $$
declare
  ra jsonb := pg_temp.bs(current_date);
  rb jsonb;
begin
  perform pg_temp.ok((ra->>'receivable')::numeric < 100000
                 and (ra->>'other_income')::numeric < 100000,
    '22 school B''s half-million charges and 777,777 donation are invisible in A');

  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Other'), false);
  rb := pg_temp.bs(current_date);
  perform pg_temp.ok(pg_temp.eq((rb->>'other_income')::numeric, 777777)
                 and pg_temp.eq((rb->>'charges_raised')::numeric, 500000),
    '23 school B sees its own figures and only its own');
  perform pg_temp.ok((rb->>'students_on_roll')::int = 1,
    '24 the roll count is per school');
  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Owner'), false);
end $$;

-- =============================================================================
-- 9. Role boundary — the same one fn_finance_summary enforces
--
-- Deliberately not looser. An admin_clerk may take a payment but may not read
-- the school's financial position, and readonly may read the school but not
-- its accounts.
-- =============================================================================
do $$
begin
  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Accountant'), false);
  perform pg_temp.bs(current_date);
  raise notice 'PASS  25 an accountant may read the balance sheet';

  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Clerk'), false);
  begin
    perform pg_temp.bs(current_date);
    raise exception 'FAIL  26 an admin_clerk read the balance sheet';
  exception when insufficient_privilege then
    raise notice 'PASS  26 an admin_clerk is refused, matching fn_finance_summary';
  end;

  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Readonly'), false);
  begin
    perform pg_temp.bs(current_date);
    raise exception 'FAIL  27 a readonly user read the balance sheet';
  exception when insufficient_privilege then
    raise notice 'PASS  27 a readonly user is refused';
  end;

  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Owner'), false);
end $$;

-- A deactivated owner is not an owner. profiles.active is enforced at
-- current_school_id(), so this must fail rather than silently report another
-- school's numbers or the whole platform's.
do $$
declare v_owner uuid;
begin
  select id into v_owner from public.profiles where full_name = 'BS Accountant';
  update public.profiles set active = false where id = v_owner;
  perform set_config('test.uid', v_owner::text, false);
  begin
    perform pg_temp.bs(current_date);
    raise exception 'FAIL  28 a deactivated accountant read the balance sheet';
  exception when insufficient_privilege then
    raise notice 'PASS  28 a deactivated staff account cannot read the accounts';
  end;
  update public.profiles set active = true where id = v_owner;
  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Owner'), false);
end $$;

-- =============================================================================
-- 10. Defaults and edges
-- =============================================================================
do $$
begin
  perform pg_temp.ok((public.fn_report_balance_sheet(null)->>'as_at') = current_date::text,
    '29 a null date means today rather than an error or an empty sheet');
  perform pg_temp.ok(length(public.fn_report_balance_sheet(current_date)->>'basis') > 100,
    '30 the payload states its own basis, so raw JSON cannot be misread');
end $$;

-- A school with nothing in it must produce a sheet, not an exception. This is
-- the first thing a new school sees.
do $$
declare
  v_c uuid; v_oc uuid := '00000000-0000-0000-0000-00000000b5a9';
  r jsonb;
begin
  -- Unset the caller first. Creating a school seeds its default expense
  -- categories, and enforce_school_id() rightly refuses rows addressed to a
  -- school the current user does not belong to.
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('BS Empty') returning id into v_c;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_c, 'growth', 'active', current_date + 30);
  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_oc, 'bse@bs.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_oc, 'BS Empty Owner', 'owner', v_c)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_oc::text, false);
  r := pg_temp.bs(current_date);
  perform pg_temp.ok(pg_temp.eq((r->>'receivable')::numeric, 0)
                 and pg_temp.eq((r->>'cash_position')::numeric, 0)
                 and (r->>'students_on_roll')::int = 0,
    '31 a brand-new school gets a sheet of zeros, not an exception');
  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = 'BS Owner'), false);
end $$;

rollback;
