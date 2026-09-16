-- =============================================================================
-- A discount belongs to the child (0138).
--
-- ASSERTION 1 IS THE WHOLE FILE. Before 0138, discounts hung off enrollment_id
-- and fn_rollover inserted into exactly one table, enrollments. So on the first
-- day of a new session every approved sibling, staff-child, hardship and
-- scholarship discount stopped existing, every one of those families was
-- charged the full fee, and not one screen said so. This test rolls a year over
-- and demands the concession is still there.
--
-- ASSERTION 4 IS THE OTHER HALF. Discount lines were written only inside
-- invoice generation, so a discount approved on the 5th did nothing to the
-- challan raised on the 1st, for ever.
--
-- ASSERTION 6 IS THE LIMIT ON THAT, and it is deliberate. Repricing must not
-- touch a month somebody has already paid against: changing what a paid month
-- charges is a refund, and a refund is a decision with a person's name on it.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/discount_belongs_to_the_child.sql
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

do $seed$
declare
  sch uuid := gen_random_uuid(); own uuid := gen_random_uuid();
  ses uuid; c1 uuid; fh uuid; s1 uuid; e1 uuid;
  today date := (now() at time zone 'Asia/Karachi')::date;
  start date := date_trunc('month', today - interval '2 months')::date;
begin
  insert into public.schools(id, name, city) values (sch, 'Discount Test School', 'Sialkot');
  insert into public.subscriptions(school_id, plan_code, status, trial_ends_on)
    values (sch, 'growth', 'active', today + 90);
  insert into auth.users(id, email) values (own, 'head@discount.test') on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles(id, school_id, full_name, role) values (own, sch, 'Head', 'owner');
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', own::text, false);

  insert into public.academic_sessions(school_id, name, starts_on, ends_on, is_current)
    values (sch, 'Year One', start, (start + interval '11 months' + interval '27 days')::date, true)
    returning id into ses;
  update public.school_settings set current_session_id = ses, billing_day = 1, due_day = 10
   where school_id = sch;

  insert into public.classes(school_id, name, level_order) values (sch, 'Prep', 1) returning id into c1;
  insert into public.fee_heads(school_id, name, type, is_refundable, is_recurring, sort_order, active)
    values (sch, 'Monthly Fee', 'monthly', false, true, 1, true) returning id into fh;
  insert into public.fee_structures(school_id, session_id, class_id, fee_head_id, amount, effective_from)
    values (sch, ses, c1, fh, 4000, start);

  insert into public.students(school_id, gr_no, full_name, admission_date, status)
    values (sch, 'GR-1', 'Hamza', start, 'active') returning id into s1;
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s1, ses, c1, '1') returning id into e1;
end $seed$;

-- =============================================================================
-- 1-3. It survives the year, which is what it never did
-- =============================================================================
do $rollover$
declare
  sch uuid; own uuid; ses uuid; ses2 uuid; c1 uuid; s1 uuid; d1 uuid;
  v numeric; n int;
  today date := (now() at time zone 'Asia/Karachi')::date;
  start date := date_trunc('month', today - interval '2 months')::date;
begin
  select id into sch from public.schools where name = 'Discount Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch;
  select id into c1  from public.classes where school_id = sch;
  select id into s1  from public.students where school_id = sch and gr_no = 'GR-1';
  perform set_config('test.uid', own::text, false);

  d1 := public.fn_add_discount(s1, 'hardship', 25, true, 'father out of work', start, null);
  perform public.fn_set_discount_status(d1, 'approved');
  perform public.fn_ensure_billing_current(ses);

  select sum(l.amount) into v from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
   where i.student_id = s1 and i.period_month = date_trunc('month', today)::date and l.is_discount;
  perform pg_temp.ok(v = 1000, '1a. a 25% hardship waiver on Rs 4,000 is Rs 1,000 this year');

  -- NEXT YEAR. A fresh session, a fresh enrolment, the same child.
  insert into public.academic_sessions(school_id, name, starts_on, ends_on, is_current)
    values (sch, 'Year Two', (start + interval '12 months')::date,
            (start + interval '23 months' + interval '27 days')::date, false)
    returning id into ses2;
  insert into public.fee_structures(school_id, session_id, class_id, fee_head_id, amount, effective_from)
    select sch, ses2, c1, fh.id, 4500, (start + interval '12 months')::date
      from public.fee_heads fh where fh.school_id = sch limit 1;
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s1, ses2, c1, '1');

  select count(*) into n from public.fn__discounts_live(s1, (start + interval '13 months')::date);
  perform pg_temp.ok(n = 1,
    '1. THE ONE THIS FILE EXISTS FOR: the waiver is still live in the next session. Keyed to '
    || 'the enrolment, as it was, it would be gone and this family would be charged the full '
    || 'fee with nothing said');

  select (public.fn_student_fee_for_month(s1, (start + interval '13 months')::date)->>'discount')::numeric
    into v;
  perform pg_temp.ok(v = 1125,
    '2. and it follows the new fee: 25% of Rs 4,500 is Rs 1,125, not last year''s Rs 1,000');

  perform pg_temp.ok(
    (select count(*) from public.discounts where student_id = s1) = 1,
    '3. without anybody having to grant it again, which is the thing a school would forget');
end $rollover$;

-- =============================================================================
-- 4-7. Granted late, changed, ended
-- =============================================================================
do $reprice$
declare
  sch uuid; own uuid; ses uuid; s2 uuid; c1 uuid; d2 uuid; res jsonb;
  v numeric; n int;
  today date := (now() at time zone 'Asia/Karachi')::date;
  thismon date := date_trunc('month', today)::date;
  start date := date_trunc('month', today - interval '2 months')::date;
begin
  select id into sch from public.schools where name = 'Discount Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into ses from public.academic_sessions where school_id = sch and name = 'Year One';
  select id into c1  from public.classes where school_id = sch;
  perform set_config('test.uid', own::text, false);

  insert into public.students(school_id, gr_no, full_name, admission_date, status)
    values (sch, 'GR-2', 'Zain', start, 'active') returning id into s2;
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s2, ses, c1, '2');
  perform public.fn_ensure_billing_current(ses);

  select sum(l.amount) into v from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
   where i.student_id = s2 and i.period_month = thismon and l.is_discount;
  perform pg_temp.ok(coalesce(v, 0) = 0, '4a. this child starts on the full fee');

  -- THE CHALLAN ALREADY EXISTS. Granting a discount now must reach it.
  d2 := public.fn_add_discount(s2, 'merit', 500, false, 'first in class', thismon, null);
  res := public.fn_set_discount_status(d2, 'approved');

  select sum(l.amount) into v from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
   where i.student_id = s2 and i.period_month = thismon and l.is_discount;
  perform pg_temp.ok(v = 500,
    '4. a discount approved AFTER the challan was raised reaches that challan. Before 0138 the '
    || 'lines were written only during generation, so it reached nothing, for ever, in silence');

  -- Changed in place: 500 becomes 1000, and the challan follows.
  res := public.fn_edit_discount(d2, 'merit', 1000, false, 'first in class', thismon, null);
  select sum(l.amount) into v from public.invoice_lines l
    join public.invoices i on i.id = l.invoice_id
   where i.student_id = s2 and i.period_month = thismon and l.is_discount;
  perform pg_temp.ok(v = 1000,
    '5. raising a concession changes it in place rather than needing it revoked and re-granted, '
    || 'which would read in every report as two separate acts of generosity');

  -- 6. A PAID MONTH IS HISTORY. Pay the earliest month, then widen the discount
  -- back over it, and that month must not move.
  declare v_pay jsonb; v_before numeric; v_after numeric; v_inv uuid;
  begin
    select id into v_inv from public.invoices
      where student_id = s2 and period_month = start and status <> 'void';
    select b.charge into v_before from public.invoice_balances b where b.invoice_id = v_inv;
    v_pay := public.fn_record_payment(s2, v_before, 'cash', 'settled in full', false);

    res := public.fn_edit_discount(d2, 'merit', 1000, false, 'first in class', start, null);
    select b.charge into v_after from public.invoice_balances b where b.invoice_id = v_inv;

    perform pg_temp.ok(v_after = v_before,
      '6. a month already paid against is left exactly as it was. Changing what a paid month '
      || 'charges is a refund, and a refund is a decision with a person''s name on it, not '
      || 'something a discount edit does to a family behind their back');
    perform pg_temp.ok((res->'reprice'->>'left_alone_because_paid')::int >= 1,
      '7. and the office is TOLD it was left alone rather than being left to notice');
  end;
end $reprice$;

-- =============================================================================
-- 8-10. Ending one, and the caps
-- =============================================================================
do $ending$
declare
  sch uuid; own uuid; s2 uuid; d2 uuid; d3 uuid; res jsonb; v numeric;
  today date := (now() at time zone 'Asia/Karachi')::date;
  thismon date := date_trunc('month', today)::date;
begin
  select id into sch from public.schools where name = 'Discount Test School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into s2  from public.students where school_id = sch and gr_no = 'GR-2';
  perform set_config('test.uid', own::text, false);
  select id into d2 from public.discounts where student_id = s2 and type = 'merit';

  res := public.fn_end_discount(d2, thismon);
  perform pg_temp.ok(
    (select count(*) from public.fn__discounts_live(s2, (thismon + interval '1 month')::date)) = 0,
    '8. ending a discount stops it from the following month');
  perform pg_temp.ok(
    (select count(*) from public.fn__discounts_live(s2, thismon)) = 1,
    '9. and leaves the months it did cover alone, so last year''s statement still adds up');

  -- A flat discount larger than the fee, and a second one on top, must not
  -- produce a challan that owes the parent money.
  d3 := public.fn_add_discount(s2, 'scholarship', 99999, false, 'full scholarship', thismon, null);
  perform public.fn_set_discount_status(d3, 'approved');
  select b.charge into v from public.invoice_balances b
    join public.invoices i on i.id = b.invoice_id
   where i.student_id = s2 and i.period_month = thismon;
  perform pg_temp.ok(v = 0,
    '10. a waiver bigger than the fee makes the month free and never negative, got ' || v);
end $ending$;

rollback;
\echo 'DISCOUNT BELONGS TO THE CHILD: ALL TESTS PASSED'
