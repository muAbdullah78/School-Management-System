-- =============================================================================
-- Family billing: allocation, credit and conservation.
--
-- The rules this file exists to defend:
--
--  1. A payment is allocated OLDEST MONTH FIRST across every child in the
--     family. Not per-child-in-turn, not newest-first.
--  2. An overpayment takes each student to zero and parks the remainder as
--     FAMILY CREDIT. It must never drive a student's balance negative, because
--     "how much advance is this parent holding?" has to be answerable.
--  3. Conservation, at every point:
--         family_outstanding = sum(student_balance of members) - family_credit
--  4. Credit is consumed by the next challan, so a family holding money never
--     appears on the defaulter list.
--  5. Reversal puts everything back — including the wallet.
--  6. fn__allocate_payment is NOT reachable by a signed-in user. It writes
--     allocation rows against any invoice id it is handed, so exposing it
--     would let anyone mark invoices paid without a payment.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/family_money.sql
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

-- --- Fixture -----------------------------------------------------------------
-- One school. The Aslam family with three children, the Khan family with one.
-- Tuition Rs 1,000/month, two months billed.
do $seed$
declare
  v_school uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000f1';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid;
  v_fam uuid; v_khan uuid;
  v_stu uuid; v_enr uuid;
  v_names text[] := array['Ahmed Aslam', 'Fatima Aslam', 'Bilal Aslam'];
  v_n text;
begin
  -- (No "clean slate" delete here. Nothing cascades from public.schools —
  -- 34 tables reference it with NO ACTION — so the delete that used to sit
  -- on this line matched zero rows on a fresh database and failed outright
  -- on a re-run. The suite rolls back instead, which actually works.)

  insert into public.schools (name) values ('Family Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'f1@family.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Family Owner', 'owner', v_school)
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
    values (v_sess, v_class, v_head, 1000, v_school);

  -- The two families
  insert into public.families (school_id, head_name, head_cnic, phone)
    values (v_school, 'Muhammad Aslam', '35201-1111111-1', '03001234567')
    returning id into v_fam;
  insert into public.families (school_id, head_name, head_cnic)
    values (v_school, 'Imran Khan', '35201-2222222-2')
    returning id into v_khan;

  foreach v_n in array v_names loop
    insert into public.students (full_name, status, school_id, family_id)
      values (v_n, 'active', v_school, v_fam) returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
      values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;
  end loop;

  insert into public.students (full_name, status, school_id, family_id)
    values ('Sara Khan', 'active', v_school, v_khan) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;

  -- Two months of challans: 4 students x Rs 1,000 x 2 months
  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-09-01', date '2025-09-10');
  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-10-01', date '2025-10-10');

  raise notice 'fixture ok';
end $seed$;

-- =============================================================================
-- 1. Every student has a family, in the right school
-- =============================================================================
do $t$
declare v_bad integer;
begin
  select count(*) into v_bad
  from public.students s
  join public.families f on f.id = s.family_id
  where s.school_id <> f.school_id;
  if v_bad > 0 then raise exception 'FAIL: % students whose family is in another school', v_bad; end if;

  -- and the auto-family trigger fires for a student created without one
  insert into public.students (full_name, status, school_id)
  values ('Orphan Test', 'active',
          (select id from public.schools where name = 'Family Test School'));
  if exists (select 1 from public.students where full_name = 'Orphan Test' and family_id is null) then
    raise exception 'FAIL: student created without a family';
  end if;
  if exists (
    select 1 from public.students s join public.families f on f.id = s.family_id
    where s.full_name = 'Orphan Test' and f.school_id <> s.school_id
  ) then
    raise exception 'FAIL: auto-created family landed in the wrong school (trigger order?)';
  end if;
  delete from public.students where full_name = 'Orphan Test';
  raise notice '1. every student has a family — ok';
end $t$;

-- =============================================================================
-- 2. Baseline: three children, two months, Rs 1,000 each
-- =============================================================================
do $t$
declare v_fam uuid; v_out numeric; v_cred numeric;
begin
  select id into v_fam from public.families where head_name = 'Muhammad Aslam';
  v_out  := public.family_outstanding(v_fam);
  v_cred := public.family_credit(v_fam);
  if v_out <> 6000 then raise exception 'FAIL: expected 6000 outstanding, got %', v_out; end if;
  if v_cred <> 0 then raise exception 'FAIL: expected no credit, got %', v_cred; end if;
  raise notice '2. baseline 3 children x 2 months = 6000 — ok';
end $t$;

-- =============================================================================
-- 3. FIFO ACROSS SIBLINGS — the core rule
--
-- Pay exactly one month's worth for the whole family (Rs 3,000). Every
-- September invoice must be settled and every October invoice untouched. If
-- allocation walked child-by-child instead of month-by-month, one child would
-- be paid up to October while a sibling still owed September.
-- =============================================================================
do $t$
declare
  v_fam uuid; j jsonb;
  v_sep_unpaid integer; v_oct_paid integer;
begin
  select id into v_fam from public.families where head_name = 'Muhammad Aslam';
  j := public.fn_record_family_payment(v_fam, 3000, 'cash', 'one month, three children');

  if (j->>'allocated')::numeric <> 3000 then
    raise exception 'FAIL: expected 3000 allocated, got %', j;
  end if;
  if (j->>'credit')::numeric <> 0 then
    raise exception 'FAIL: expected no credit, got %', j;
  end if;

  select count(*) into v_sep_unpaid
  from public.invoice_balances b join public.invoices i on i.id = b.invoice_id
  join public.students s on s.id = i.student_id
  where s.family_id = v_fam and i.period_month = date '2025-09-01'
    and b.charge - b.allocated > 0;
  if v_sep_unpaid <> 0 then
    raise exception 'FAIL: % September invoices still unpaid — allocation is not month-first', v_sep_unpaid;
  end if;

  select count(*) into v_oct_paid
  from public.invoice_balances b join public.invoices i on i.id = b.invoice_id
  join public.students s on s.id = i.student_id
  where s.family_id = v_fam and i.period_month = date '2025-10-01' and b.allocated > 0;
  if v_oct_paid <> 0 then
    raise exception 'FAIL: % October invoices touched before September cleared', v_oct_paid;
  end if;

  raise notice '3. FIFO across siblings — ok';
end $t$;

-- =============================================================================
-- 4. One receipt, not three
-- =============================================================================
do $t$
declare v_fam uuid; v_pays integer;
begin
  select id into v_fam from public.families where head_name = 'Muhammad Aslam';
  select count(*) into v_pays from public.payments where family_id = v_fam and status = 'verified';
  if v_pays <> 1 then
    raise exception 'FAIL: expected 1 payment row for 3 children, got %', v_pays;
  end if;
  if exists (select 1 from public.payments where family_id = v_fam and receipt_no is null) then
    raise exception 'FAIL: family payment has no receipt number';
  end if;
  raise notice '4. one payment, one receipt, three children — ok';
end $t$;

-- =============================================================================
-- 5. OVERPAYMENT becomes credit, never a negative student
-- =============================================================================
do $t$
declare
  v_fam uuid; j jsonb; v_cred numeric; v_neg integer; v_sum numeric;
begin
  select id into v_fam from public.families where head_name = 'Muhammad Aslam';
  -- Rs 3,000 owed (October), pay Rs 5,000
  j := public.fn_record_family_payment(v_fam, 5000, 'cash', 'paying ahead');

  if (j->>'allocated')::numeric <> 3000 then
    raise exception 'FAIL: expected 3000 allocated, got %', j;
  end if;
  if (j->>'credit')::numeric <> 2000 then
    raise exception 'FAIL: expected 2000 credit, got %', j;
  end if;

  select count(*) into v_neg
  from public.students s where s.family_id = v_fam and public.student_balance(s.id) < 0;
  if v_neg > 0 then
    raise exception 'FAIL: % students driven negative by an overpayment', v_neg;
  end if;

  select coalesce(sum(public.student_balance(s.id)), 0) into v_sum
  from public.students s where s.family_id = v_fam;
  if v_sum <> 0 then raise exception 'FAIL: expected all students at zero, got %', v_sum; end if;

  v_cred := public.family_credit(v_fam);
  if v_cred <> 2000 then raise exception 'FAIL: expected 2000 family credit, got %', v_cred; end if;

  raise notice '5. overpayment -> family credit, no negative student — ok';
end $t$;

-- =============================================================================
-- 6. CONSERVATION — the invariant that must hold everywhere
-- =============================================================================
do $t$
declare r record; v_sum numeric; v_lhs numeric; v_rhs numeric;
begin
  for r in select id, head_name from public.families
           where school_id = (select id from public.schools where name = 'Family Test School')
  loop
    select coalesce(sum(public.student_balance(s.id)), 0) into v_sum
    from public.students s where s.family_id = r.id;
    v_lhs := public.family_outstanding(r.id);
    v_rhs := v_sum - public.family_credit(r.id);
    if v_lhs <> v_rhs then
      raise exception 'FAIL: conservation broken for % — outstanding % <> students % - credit',
        r.head_name, v_lhs, v_sum;
    end if;
  end loop;
  raise notice '6. conservation holds for every family — ok';
end $t$;

-- =============================================================================
-- 7. Credit is consumed by the next challan
--
-- A family sitting on Rs 2,000 must not appear on the defaulter list when
-- November is billed. Generation applies the credit.
-- =============================================================================
do $t$
declare
  v_fam uuid; v_sess uuid; v_class uuid; v_cred numeric; v_out numeric;
begin
  select id into v_fam from public.families where head_name = 'Muhammad Aslam';
  select id into v_sess from public.academic_sessions
    where school_id = (select id from public.schools where name = 'Family Test School');
  select id into v_class from public.classes
    where school_id = (select id from public.schools where name = 'Family Test School');

  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-11-01', date '2025-11-10');

  -- November: 3 children x 1,000 = 3,000 charged, 2,000 credit applied
  v_cred := public.family_credit(v_fam);
  v_out  := public.family_outstanding(v_fam);
  if v_cred <> 0 then
    raise exception 'FAIL: credit should have been consumed by the new challan, still %', v_cred;
  end if;
  if v_out <> 1000 then
    raise exception 'FAIL: expected 1000 still owed after credit applied, got %', v_out;
  end if;
  raise notice '7. credit consumed by the next challan — ok';
end $t$;

-- =============================================================================
-- 8. Single-student payment is unchanged, and creates no phantom credit
--
-- This is the behaviour-preservation check for rewriting student_balance onto
-- allocations: an exact single-student payment must still land the student on
-- zero, with nothing left floating.
-- =============================================================================
do $t$
declare v_khan uuid; v_sara uuid; j jsonb; v_bal numeric; v_cred numeric;
begin
  select id into v_khan from public.families where head_name = 'Imran Khan';
  select id into v_sara from public.students where full_name = 'Sara Khan';

  v_bal := public.student_balance(v_sara);      -- Sep + Oct + Nov = 3000
  if v_bal <> 3000 then raise exception 'FAIL: expected Sara at 3000, got %', v_bal; end if;

  j := public.fn_record_payment(v_sara, 3000, 'cash', 'exact');
  if (j->>'allocated')::numeric <> 3000 then raise exception 'FAIL: %', j; end if;
  if (j->>'unallocated')::numeric <> 0 then raise exception 'FAIL: %', j; end if;

  v_bal  := public.student_balance(v_sara);
  v_cred := public.family_credit(v_khan);
  if v_bal <> 0 then raise exception 'FAIL: expected Sara at zero, got %', v_bal; end if;
  if v_cred <> 0 then raise exception 'FAIL: phantom credit % created', v_cred; end if;
  raise notice '8. single-student payment unchanged — ok';
end $t$;

-- =============================================================================
-- 9. A single-student payment never touches a sibling
-- =============================================================================
do $t$
declare
  v_ahmed uuid; v_fatima uuid; v_before numeric; v_after numeric; j jsonb;
begin
  select id into v_ahmed  from public.students where full_name = 'Ahmed Aslam';
  select id into v_fatima from public.students where full_name = 'Fatima Aslam';
  v_before := public.student_balance(v_fatima);

  j := public.fn_record_payment(v_ahmed, 500, 'cash', 'ahmed only');

  v_after := public.student_balance(v_fatima);
  if v_after <> v_before then
    raise exception 'FAIL: paying Ahmed moved Fatima from % to %', v_before, v_after;
  end if;
  raise notice '9. single-student payment stays on that student — ok';
end $t$;

-- =============================================================================
-- 10. Reversal restores balances AND the wallet
-- =============================================================================
do $t$
declare
  v_fam uuid; j jsonb; v_pay uuid;
  v_out_before numeric; v_out_after numeric;
  v_cred_before numeric; v_cred_after numeric;
begin
  select id into v_fam from public.families where head_name = 'Muhammad Aslam';
  v_out_before  := public.family_outstanding(v_fam);
  v_cred_before := public.family_credit(v_fam);

  j := public.fn_record_family_payment(v_fam, 4000, 'cash', 'to be reversed');
  v_pay := (j->>'payment_id')::uuid;

  perform public.fn_reverse_payment(v_pay, 'test reversal');

  v_out_after  := public.family_outstanding(v_fam);
  v_cred_after := public.family_credit(v_fam);
  if v_out_after <> v_out_before then
    raise exception 'FAIL: outstanding % before, % after reversal', v_out_before, v_out_after;
  end if;
  if v_cred_after <> v_cred_before then
    raise exception 'FAIL: credit % before, % after reversal', v_cred_before, v_cred_after;
  end if;
  raise notice '10. reversal restores balances and wallet — ok';
end $t$;

-- =============================================================================
-- 11. Credit is never negative
-- =============================================================================
do $t$
declare v_bad integer;
begin
  select count(*) into v_bad from public.families f where public.family_credit(f.id) < 0;
  if v_bad > 0 then raise exception 'FAIL: % families with negative credit', v_bad; end if;
  raise notice '11. credit never negative — ok';
end $t$;

-- =============================================================================
-- 12. The internal allocator is NOT reachable by a signed-in user
--
-- It writes allocation rows against any invoice id handed to it. If
-- `authenticated` could execute it, anyone could mark invoices paid without a
-- payment ever existing.
-- =============================================================================
do $t$
begin
  if has_function_privilege('authenticated',
       'public.fn__allocate_payment(uuid, uuid[], numeric)', 'execute') then
    raise exception 'FAIL: fn__allocate_payment is executable by authenticated';
  end if;
  if has_function_privilege('anon',
       'public.fn__allocate_payment(uuid, uuid[], numeric)', 'execute') then
    raise exception 'FAIL: fn__allocate_payment is executable by anon';
  end if;
  raise notice '12. internal allocator not exposed — ok';
end $t$;

-- =============================================================================
-- 13. Cross-tenant: another school's family is unreachable
-- =============================================================================
do $t$
declare
  v_other uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000f2';
  v_fam uuid; v_ok boolean;
begin
  -- Provisioning a school is a service-role act, not something a school owner
  -- may do. Drop the caller identity first, or the AFTER INSERT provisioning
  -- trigger is (correctly) refused as a cross-tenant write.
  perform set_config('test.uid', '', false);

  -- (No "clean slate" delete here. Nothing cascades from public.schools —
  -- 34 tables reference it with NO ACTION — so the delete that used to sit
  -- on this line matched zero rows on a fresh database and failed outright
  -- on a re-run. The suite rolls back instead, which actually works.)
  insert into public.schools (name) values ('Other Family School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'f2@family.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Other Owner', 'owner', v_other)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  select id into v_fam from public.families where head_name = 'Muhammad Aslam';

  -- Act as the OTHER school's owner
  perform set_config('test.uid', v_owner::text, false);

  v_ok := false;
  begin
    perform public.fn_family_sheet(v_fam);
    v_ok := true;
  exception when others then null;
  end;
  if v_ok then raise exception 'FAIL: read another school''s family sheet'; end if;

  v_ok := false;
  begin
    perform public.fn_record_family_payment(v_fam, 100, 'cash', 'break-in');
    v_ok := true;
  exception when others then null;
  end;
  if v_ok then raise exception 'FAIL: recorded a payment against another school''s family'; end if;

  if exists (select 1 from public.fn_find_family('Muhammad Aslam')) then
    raise exception 'FAIL: found another school''s family by search';
  end if;
  if exists (select 1 from public.fn_find_family('35201-1111111-1')) then
    raise exception 'FAIL: found another school''s family by CNIC';
  end if;

  -- restore identity for anything after this
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000f1', false);
  raise notice '13. cross-tenant family access refused — ok';
end $t$;

-- =============================================================================
-- 14. The same CNIC may exist in two different schools
--     (uniqueness is per school, not global — two schools have no relationship)
-- =============================================================================
do $t$
declare v_other uuid;
begin
  perform set_config('test.uid', '', false);
  select id into v_other from public.schools where name = 'Other Family School';
  insert into public.families (school_id, head_name, head_cnic)
  values (v_other, 'Muhammad Aslam', '35201-1111111-1');
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000000f1', false);
  raise notice '14. CNIC unique per school, not globally — ok';
exception when unique_violation then
  raise exception 'FAIL: CNIC uniqueness is global — two schools cannot both have this parent';
end $t$;

-- =============================================================================
-- 15. Family sheet reports the same numbers as the functions
-- =============================================================================
do $t$
declare v_fam uuid; j jsonb;
begin
  select id into v_fam from public.families where head_name = 'Muhammad Aslam';
  j := public.fn_family_sheet(v_fam);
  if (j->>'outstanding')::numeric <> public.family_outstanding(v_fam) then
    raise exception 'FAIL: sheet outstanding % <> function %',
      j->>'outstanding', public.family_outstanding(v_fam);
  end if;
  if (j->>'credit')::numeric <> public.family_credit(v_fam) then
    raise exception 'FAIL: sheet credit disagrees with function';
  end if;
  if jsonb_array_length(j->'children') <> 3 then
    raise exception 'FAIL: expected 3 children on the sheet, got %',
      jsonb_array_length(j->'children');
  end if;
  raise notice '15. family sheet agrees with the balance functions — ok';
end $t$;

do $$ begin raise notice 'ALL FAMILY MONEY TESTS PASSED'; end $$;

rollback;
