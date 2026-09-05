-- =============================================================================
-- The cash drawer must never accuse the clerk of a shortfall the software made.
--
-- WHY THIS FILE EXISTS
--
-- One ordinary morning at the counter, seeded and run against the code as it
-- stood:
--
--   open the drawer with a Rs 1,000 float
--   take Rs 3,000 in cash for September                  drawer holds 4,000
--   the cheque bounced: reverse it, hand the money back  drawer holds 1,000
--   admit a child, Rs 2,000 admission fee in cash        drawer holds 3,000
--
--   THE TILL EXPECTED Rs 4,000. THE DRAWER HELD Rs 3,000.
--   "The drawer is off by -1000.00. A reason is required to close it."
--
-- The clerk did everything correctly and could not close their till without
-- writing an explanation for money they never touched. The variance was then
-- recorded against them and an owner signed it off. In a school office that is
-- not a rounding complaint, it is an accusation, and it lands on the lowest-paid
-- person in the building.
--
-- 0031 attached cash to the collector's drawer by adding one line to the two
-- payment entry points. Two other functions write to `payments` and neither got
-- it: fn_reverse_payment takes money OUT (drawer short) and fn_admit_student's
-- admission fee, hardcoded 'cash', puts money IN (drawer over). In the run above
-- they partly cancelled, which is worse than either alone: a Rs 3,000 shortfall
-- and a Rs 2,000 surplus presented as a Rs 1,000 mystery.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/till_and_the_clerk.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- Fixture ---------------------------------------------------------------
do $seed$
declare
  v_school uuid; v_clerk uuid := '00000000-0000-0000-0000-0000000000c9';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid; v_stu uuid; v_enr uuid;
begin
  insert into public.schools (name) values ('Till School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_clerk, 'c9@till.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_clerk, 'Till Clerk', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_clerk::text, false);

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_school;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 3000, v_school);
  insert into public.students (full_name, status, school_id)
    values ('Till Pupil', 'active', v_school) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;
  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-09-01', date '2025-09-10');

  raise notice 'fixture ok';
end $seed$;

-- =============================================================================
-- 1. The morning, end to end. The drawer must balance.
-- =============================================================================
do $t$
declare
  v_school uuid; v_sess uuid; v_class uuid; v_sec uuid; v_stu uuid;
  v_pay uuid; j jsonb;
begin
  select id into v_school from public.schools where name = 'Till School';
  select id into v_sess  from public.academic_sessions where school_id = v_school;
  select id into v_class from public.classes where school_id = v_school;
  select id into v_sec   from public.sections where school_id = v_school;
  select id into v_stu   from public.students where full_name = 'Till Pupil';

  perform public.fn_open_till(1000);

  j := public.fn_record_payment(v_stu, 3000, 'cash', 'September fee');
  v_pay := (j ->> 'payment_id')::uuid;

  perform public.fn_reverse_payment(v_pay, 'cheque bounced, cash returned');

  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'New Admission', 'session_id', v_sess, 'class_id', v_class,
    'section_id', v_sec,
    'admission_fee', jsonb_build_object('amount', 2000, 'charged', true)));

  -- Float 1,000 + admission 2,000, the fee taken and given back. Rs 3,000.
  j := public.fn_close_till(3000, null);

  if (j ->> 'variance')::numeric <> 0 then
    raise exception 'FAIL: the clerk counted Rs 3,000 and the till expected Rs %. '
                    'They are short by % for money the software moved without '
                    'telling the drawer.',
      j ->> 'expected_cash', (j ->> 'variance')::numeric;
  end if;

  raise notice '1. an honest morning closes at zero variance — ok';
end $t$;

-- =============================================================================
-- 2. The reversal came out of the drawer the money went into
--
-- Not the drawer of whoever pressed the button. fn_reverse_payment is
-- owner/principal only and a principal usually has no drawer of their own; the
-- cash is handed back from the drawer it went into, and that is the till the
-- contra belongs to.
-- =============================================================================
do $t$
declare
  v_stu uuid; v_pay uuid; v_rev uuid; v_till uuid; v_rev_till uuid; j jsonb;
begin
  select id into v_stu from public.students where full_name = 'Till Pupil';

  perform public.fn_open_till(0);
  select id into v_till from public.till_sessions where status = 'open';

  j := public.fn_record_payment(v_stu, 500, 'cash', 'part payment');
  v_pay := (j ->> 'payment_id')::uuid;
  v_rev := public.fn_reverse_payment(v_pay, 'wrong child');

  select till_session_id into v_rev_till from public.payments where id = v_rev;
  if v_rev_till is distinct from v_till then
    raise exception 'FAIL: the contra receipt belongs to till %, the money came '
                    'out of till %', v_rev_till, v_till;
  end if;

  perform public.fn_close_till(0, null);
  raise notice '2. a reversal comes out of the drawer the money went into — ok';
end $t$;

-- =============================================================================
-- 3. A reversal with no drawer open invents nothing
--
-- Reversing last month's receipt belongs to no drawer. Opening one in somebody's
-- name that they never opened, and then asking them to count it, is worse than
-- leaving the contra unattributed.
-- =============================================================================
do $t$
declare v_stu uuid; v_pay uuid; v_rev uuid; v_before int; v_after int; j jsonb;
begin
  select id into v_stu from public.students where full_name = 'Till Pupil';

  -- Take the money in one till, close it, then reverse with nothing open.
  perform public.fn_open_till(0);
  j := public.fn_record_payment(v_stu, 700, 'cash', 'to be reversed later');
  v_pay := (j ->> 'payment_id')::uuid;
  perform public.fn_close_till(700, null);

  select count(*) into v_before from public.till_sessions;
  v_rev := public.fn_reverse_payment(v_pay, 'reversed after the till was closed');
  select count(*) into v_after from public.till_sessions;

  if v_after <> v_before then
    raise exception 'FAIL: reversing with no drawer open created % till session(s). '
                    'Somebody now has a till they never opened, holding a '
                    'negative balance, and will be asked to count it.',
      v_after - v_before;
  end if;
  if (select till_session_id from public.payments where id = v_rev) is not null then
    raise exception 'FAIL: the contra was attributed to a drawer that was already '
                    'closed and counted, which changes a till after it was signed off';
  end if;

  raise notice '3. a reversal with no drawer open invents no drawer — ok';
end $t$;

-- =============================================================================
-- 4. A bank transfer reversal touches no drawer at all
--
-- Nothing moves on the counter, so attributing it to a till would make that
-- till wrong in the other direction.
-- =============================================================================
do $t$
declare v_stu uuid; v_pay uuid; v_rev uuid; j jsonb;
begin
  select id into v_stu from public.students where full_name = 'Till Pupil';

  perform public.fn_open_till(0);
  j := public.fn_record_payment(v_stu, 900, 'bank_transfer', 'online');
  v_pay := (j ->> 'payment_id')::uuid;
  v_rev := public.fn_reverse_payment(v_pay, 'sent to the wrong account');

  if (select till_session_id from public.payments where id = v_rev) is not null then
    raise exception 'FAIL: reversing a bank transfer was charged to a cash drawer';
  end if;

  j := public.fn_close_till(0, null);
  if (j ->> 'variance')::numeric <> 0 then
    raise exception 'FAIL: a bank transfer and its reversal moved the cash drawer by %',
      j ->> 'variance';
  end if;

  raise notice '4. a bank reversal leaves the drawer alone — ok';
end $t$;

-- =============================================================================
-- 5. Every function that writes cash says which drawer
--
-- By catalogue, because the defect was a function nobody remembered when 0031
-- added the rule. A fifth writer added next year fails here.
--
-- fn_admit_student is included: its admission fee is hardcoded 'cash', so it is
-- a cash writer whether or not it looks like one.
-- =============================================================================
do $t$
declare v_bad text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosrc like '%insert into public.payments%'
    and p.prosrc not like '%till_session_id%';

  if v_bad is not null then
    raise exception 'FAIL: these write payments without saying which drawer the '
                    'cash came from or went into: %. A drawer that does not know '
                    'about money it holds accuses whoever is counting it.', v_bad;
  end if;

  raise notice '5. every payment writer names the drawer — ok';
end $t$;

rollback;
\echo 'TILL AND THE CLERK: ALL TESTS PASSED'
