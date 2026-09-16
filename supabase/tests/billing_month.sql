-- =============================================================================
-- A month is billed whether or not anybody remembers (0138).
--
-- WHAT THIS FILE IS REALLY TESTING is not "does fn_bill_month insert rows". It
-- is that the question a school actually asks, "how many of my pupils have paid
-- this month", has an answer at all. Before 0138 it did not: a fee existed only
-- when somebody pressed Generate Challans for one class, nothing recorded which
-- classes had been done, and a class nobody billed had no unpaid fees rather
-- than unbilled ones. Every total agreed the month had gone well.
--
-- THE TWO ASSERTIONS THAT EARNED THIS FILE ARE 4 AND 9, and both failed when
-- first written:
--
--   4  a class with no fee structure was billed silently at zero, which looks
--      exactly like every pupil in it having paid
--   9  a pupil admitted in September was billed for May, June, July and August
--      as well, because the self-healing pass walks every month of the session
--      and an active enrolment is active in all of them. The parent's first
--      challan would have been five months of fees for a child who had been
--      there a week.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/billing_month.sql
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

-- =============================================================================
-- A school five months into its year, with one class the office forgot to set
-- a fee for. That class is not a contrivance: it is what the first month of a
-- real installation looks like.
-- =============================================================================
do $seed$
declare
  sch uuid := gen_random_uuid(); own uuid := gen_random_uuid();
  ses uuid; c1 uuid; c2 uuid; c3 uuid; fh uuid; fam uuid;
  s1 uuid; s2 uuid; s3 uuid; e1 uuid;
  today date := (now() at time zone 'Asia/Karachi')::date;
  start date := date_trunc('month', today - interval '4 months')::date;
begin
  insert into public.schools(id, name, city) values (sch, 'Billing Test School', 'Multan');
  insert into public.subscriptions(school_id, plan_code, status, trial_ends_on)
    values (sch, 'growth', 'active', today + 90);
  insert into auth.users(id, email) values (own, 'head@billing.test')
    on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles(id, school_id, full_name, role) values (own, sch, 'Head', 'owner');
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', own::text, false);

  insert into public.academic_sessions(school_id, name, starts_on, ends_on, is_current)
    values (sch, '2026-2027', start,
            (start + interval '11 months' + interval '27 days')::date, true)
    returning id into ses;
  update public.school_settings
     set current_session_id = ses, billing_day = 1, due_day = 10
   where school_id = sch;

  insert into public.classes(school_id, name, level_order) values (sch, 'Prep', 1) returning id into c1;
  insert into public.classes(school_id, name, level_order) values (sch, 'Class 1', 2) returning id into c2;
  insert into public.classes(school_id, name, level_order) values (sch, 'Class 2', 3) returning id into c3;

  insert into public.fee_heads(school_id, name, type, is_refundable, is_recurring, sort_order, active)
    values (sch, 'Monthly Fee', 'monthly', false, true, 1, true) returning id into fh;
  -- Class 2 is left with no fee on purpose. See assertion 4.
  insert into public.fee_structures(school_id, session_id, class_id, fee_head_id, amount, effective_from)
    values (sch, ses, c1, fh, 3500, start), (sch, ses, c2, fh, 4000, start);

  insert into public.families(school_id, head_name) values (sch, 'Shahid Anwar') returning id into fam;
  insert into public.students(school_id, gr_no, full_name, family_id, admission_date, status)
    values (sch, 'GR-1', 'Abdullah', fam, start, 'active') returning id into s1;
  insert into public.students(school_id, gr_no, full_name, family_id, admission_date, status)
    values (sch, 'GR-2', 'Ayesha', fam, start, 'active') returning id into s2;
  insert into public.students(school_id, gr_no, full_name, admission_date, status)
    values (sch, 'GR-3', 'Bilal', start, 'active') returning id into s3;

  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s1, ses, c1, '1') returning id into e1;
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s2, ses, c2, '1');
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s3, ses, c3, '1');

  -- Granted to the CHILD with a start month, which is 0138's model. A discount
  -- keyed to the enrolment is the one that vanished at rollover.
  insert into public.discounts(school_id, student_id, enrollment_id, type, amount, is_percent,
                               status, created_by, approved_by, approved_at, starts_on)
    values (sch, s1, e1, 'sibling', 10, true, 'approved', own, own, now(), start);
end $seed$;

-- =============================================================================
-- 1-8. The pass, and what it is allowed to charge
-- =============================================================================
do $run$
declare
  sch uuid; own uuid; ses uuid; res jsonb; n int; v numeric;
  today date := (now() at time zone 'Asia/Karachi')::date;
  start date := date_trunc('month', today - interval '4 months')::date;
  months int := 5;
begin
  select id into sch from public.schools where name = 'Billing Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  perform set_config('test.uid', own::text, false);

  res := public.fn_ensure_billing_current(ses);

  select count(*) into n from public.invoices where session_id = ses and status <> 'void';
  perform pg_temp.ok(n = 3 * months,
    '1. every pupil on the roll has a challan for every month from the year''s start '
    || 'to this one, with nobody having pressed anything (' || n || ')');

  select sum(l.amount) into v
    from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
    join public.students s on s.id = i.student_id
   where s.gr_no = 'GR-1' and i.period_month = date_trunc('month', today)::date
     and not l.is_discount;
  perform pg_temp.ok(v = 3500, '2. the fee charged is the class fee in force for the month billed');

  select sum(l.amount) into v
    from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
    join public.students s on s.id = i.student_id
   where s.gr_no = 'GR-1' and i.period_month = date_trunc('month', today)::date
     and l.is_discount;
  perform pg_temp.ok(v = 350,
    '3. and an approved discount is applied without anybody opening the child''s record');

  -- 4. THE ONE THAT EARNED THIS FILE. A class with no fee set must be NAMED.
  -- Billed silently at zero, it is indistinguishable from a class where
  -- everybody has paid, and that is how a school loses a month of fees.
  perform pg_temp.ok((res->'months'->0->>'classes_with_no_fee')::int = 1
                 and (res->'months'->0->>'classes_with_no_fee_names') = 'Class 2',
    '4. a class with no fee structure is named in the result, not billed zero in silence');

  res := public.fn_ensure_billing_current(ses);
  perform pg_temp.ok((res->>'billed')::int = 0,
    '5. running the pass again bills nobody twice, which is what lets the app call it on every page load');

  select count(*) into n from public.invoices where session_id = ses and status <> 'void';
  perform pg_temp.ok(n = 3 * months, '6. and leaves the challan count exactly where it was');

  select count(*) into n from public.invoices i
   where i.session_id = ses and i.due_date <> public.fn__day_in_month(i.period_month, 10);
  perform pg_temp.ok(n = 0, '7. every challan falls due on the day the school set, in every month');

  select count(*) into n from public.fn_billing_calendar(ses) where state = 'billed';
  perform pg_temp.ok(n = months,
    '8. the calendar says which months were charged, so a gap is visible rather than inferred');
end $run$;

-- =============================================================================
-- 9-10. THE OTHER ONE THAT EARNED THIS FILE
-- =============================================================================
do $late$
declare
  sch uuid; own uuid; ses uuid; c1 uuid; s4 uuid; n int;
  today date := (now() at time zone 'Asia/Karachi')::date;
  thismon date := date_trunc('month', today)::date;
begin
  select id into sch from public.schools where name = 'Billing Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into c1 from public.classes where school_id = sch and name = 'Prep';
  perform set_config('test.uid', own::text, false);

  insert into public.students(school_id, gr_no, full_name, admission_date, status)
    values (sch, 'GR-4', 'Late Joiner', today, 'active') returning id into s4;
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s4, ses, c1, '9');

  perform public.fn_ensure_billing_current(ses);

  select count(*) into n from public.invoices where student_id = s4 and status <> 'void';
  perform pg_temp.ok(n = 1,
    '9. a child admitted this month is charged for THIS MONTH ONLY. The pass walks every '
    || 'month of the year and an active enrolment is active in all of them, so without the '
    || 'admission bound this parent''s first challan is five months of fees for a child who '
    || 'has been here a week (got ' || n || ')');

  perform pg_temp.ok(
    exists (select 1 from public.invoices where student_id = s4 and period_month = thismon),
    '10. and it is the month they actually joined');
end $late$;

-- =============================================================================
-- 11-14. The refusals, which are the reason a school can trust the pass
-- =============================================================================
do $guards$
declare
  sch uuid; own uuid; ses uuid; res jsonb;
  today date := (now() at time zone 'Asia/Karachi')::date;
  thismon date := date_trunc('month', today)::date;
begin
  select id into sch from public.schools where name = 'Billing Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  perform set_config('test.uid', own::text, false);

  begin
    perform public.fn_set_month_state(ses, thismon, 'skipped');
    raise exception 'FAIL  11. a month already charged was allowed to be skipped';
  exception when sqlstate '22023' then
    perform pg_temp.ok(true,
      '11. a month that has already been charged cannot be skipped. Skipping does not '
      || 'unsend forty challans, and a settings change that silently reversed them would be '
      || 'the worst thing in this file');
  end;

  perform public.fn_set_month_state(ses, (thismon + interval '1 month')::date, 'skipped',
                                    null, 'no fee in the summer');
  perform pg_temp.ok(
    (select state from public.fn_billing_calendar(ses)
      where period_month = (thismon + interval '1 month')::date) = 'skipped',
    '12. a month the school does not charge for is recorded as a decision, so it stops '
    || 'looking like a month somebody forgot');

  update public.school_settings set auto_bill = false where school_id = sch;
  res := public.fn_ensure_billing_current(ses);
  perform pg_temp.ok(res->>'skipped_reason' = 'auto billing is off',
    '13. a school that has chosen to bill by hand is never billed behind its back');
  update public.school_settings set auto_bill = true where school_id = sch;

  -- An observer opens the Fees screen. The app calls the pass on load, so this
  -- must be a quiet zero: a permission error from an action they did not ask
  -- for reads as the software being broken.
  perform set_config('test.uid', '', false);
  res := public.fn_ensure_billing_current(ses);
  perform pg_temp.ok((res->>'billed')::int = 0,
    '14. somebody who may not bill gets a quiet zero on page load, not a permission error');
end $guards$;

rollback;
\echo 'BILLING MONTH: ALL TESTS PASSED'
