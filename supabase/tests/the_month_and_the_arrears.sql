-- =============================================================================
-- The month, the roll, who has paid, and the two clocks that were wrong (0140).
--
-- THE FEES SCREEN USED TO OPEN ON FOUR NUMBERS AND NONE OF THEM WAS THE
-- QUESTION: unpaid challans, collected today, spent today, balance today. A
-- school at the counter wants to know that it is September, there are 240
-- children, 118 have paid and 122 have not, and who they are.
--
-- ASSERTION 5 IS THE ONE THAT CANNOT BE ARGUED WITH. fn_counter_summary
-- measured today as date_trunc('day', now()), in the server's timezone, and
-- Supabase runs UTC. A fee taken at 02:00 in Karachi was counted on the
-- PREVIOUS day, every morning, for five hours. 0107 exists to put every date
-- bound through Asia/Karachi and this function and the dashboard were missed.
--
-- ASSERTION 3 IS THE RULE THE VENDOR CHOSE. Arrears means owing for a month
-- BEFORE the current one, so a child billed on the 1st and due on the 30th is
-- not chased on the 2nd. The old Defaulters screen meant "owes anything" and
-- fired on day one.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_month_and_the_arrears.sql
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

-- Three children, four months in. One has settled everything, one is straight
-- up to last month and owes only September, one has paid nothing at all. Those
-- are the three states a school actually has and they must not be confused.
do $seed$
declare
  sch uuid := gen_random_uuid(); own uuid := gen_random_uuid();
  ses uuid; c1 uuid; fh uuid; s1 uuid; s2 uuid; s3 uuid; pay jsonb;
  today date := (now() at time zone 'Asia/Karachi')::date;
  start date := date_trunc('month', today - interval '3 months')::date;
begin
  insert into public.schools(id, name, city) values (sch, 'Month View School', 'Okara');
  insert into public.subscriptions(school_id, plan_code, status, trial_ends_on)
    values (sch, 'growth', 'active', today + 90);
  insert into auth.users(id, email) values (own, 'head@monthview.test') on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles(id, school_id, full_name, role) values (own, sch, 'Head', 'owner');
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', own::text, false);

  insert into public.academic_sessions(school_id, name, starts_on, ends_on, is_current)
    values (sch, 'Y', start, (start + interval '11 months' + interval '27 days')::date, true)
    returning id into ses;
  update public.school_settings set current_session_id = ses, billing_day = 1, due_day = 10
   where school_id = sch;
  insert into public.classes(school_id, name, level_order) values (sch, 'Prep', 1) returning id into c1;
  insert into public.fee_heads(school_id, name, type, is_refundable, is_recurring, sort_order, active)
    values (sch, 'Monthly Fee', 'monthly', false, true, 1, true) returning id into fh;
  insert into public.fee_structures(school_id, session_id, class_id, fee_head_id, amount, effective_from)
    values (sch, ses, c1, fh, 2000, start);

  insert into public.students(school_id, gr_no, full_name, admission_date, status)
    values (sch, 'A', 'Settled Child', start, 'active') returning id into s1;
  insert into public.students(school_id, gr_no, full_name, admission_date, status)
    values (sch, 'B', 'Owes This Month', start, 'active') returning id into s2;
  insert into public.students(school_id, gr_no, full_name, admission_date, status)
    values (sch, 'C', 'Owes Since June', start, 'active') returning id into s3;
  insert into public.enrollments(school_id, student_id, session_id, class_id, roll_no)
    values (sch, s1, ses, c1, '1'), (sch, s2, ses, c1, '2'), (sch, s3, ses, c1, '3');

  perform public.fn_ensure_billing_current(ses);
  pay := public.fn_record_payment(s1, public.student_balance(s1), 'cash', 'all clear', false);
  pay := public.fn_record_payment(s2, 2000 * 3, 'cash', 'up to last month', false);
end $seed$;

do $month$
declare ses uuid; m jsonb; n int; st jsonb;
begin
  select id into ses from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Month View School');
  perform set_config('test.uid',
    (select id::text from public.profiles
      where school_id = (select id from public.schools where name = 'Month View School')), false);

  m := public.fn_fees_month(ses, null);
  perform pg_temp.ok((m->>'roll')::int = 3 and (m->>'paid')::int = 1
                 and (m->>'unpaid')::int = 2 and (m->>'due_total')::numeric = 4000,
    '1. the screen can say what the school asks: a roll of ' || (m->>'roll')
    || ', ' || (m->>'paid') || ' paid for this month, ' || (m->>'unpaid')
    || ' not, Rs ' || (m->>'due_total') || ' still to come');

  select count(*) into n from public.fn_fees_month_pupils(ses, null, 'unpaid');
  perform pg_temp.ok(n = 2, '2a. the unpaid count opens into a list of exactly those children');
  select count(*) into n from public.fn_fees_month_pupils(ses, null, 'paid');
  perform pg_temp.ok(n = 1, '2b. and so does the paid count');

  -- 3. THE RULE THE VENDOR CHOSE. Two children owe for September. Only the one
  -- who also owes for June, July and August is in arrears.
  select count(*) into n from public.fn_arrears(ses);
  perform pg_temp.ok(n = 1,
    '3. arrears holds the child owing for a month BEFORE this one, and not the other child '
    || 'who simply has not paid September yet. The old Defaulters screen called both of them '
    || 'defaulters on the second of the month');

  st := public.fn_student_fee_state((select id from public.students where gr_no = 'C'));
  perform pg_temp.ok(st->>'state' = 'unpaid' and (st->>'arrears_months')::int = 3
                 and (st->>'arrears_amount')::numeric = 6000,
    '4a. and one child''s own record agrees: unpaid this month, three months behind, Rs 6,000');

  st := public.fn_student_fee_state((select id from public.students where gr_no = 'A'));
  perform pg_temp.ok(st->>'state' = 'paid' and (st->>'arrears_months')::int = 0,
    '4b. while the child who settled is tagged paid, which is what the search result shows');
end $month$;

-- =============================================================================
-- 5. THE CLOCK. This one is not a matter of opinion.
-- =============================================================================
do $clock$
declare
  sch uuid; own uuid; s1 uuid; before numeric; after numeric;
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  -- Deliberately the SAME school. Creating a second one inside this
  -- transaction trips the cross-tenant guard, because the seeding trigger runs
  -- as the caller, who still belongs to the first school. That refusal is the
  -- tenant isolation working and is not what this assertion is about.
  select id into sch from public.schools where name = 'Month View School';
  select id into own from public.profiles where school_id = sch and role = 'owner';
  select id into s1  from public.students where school_id = sch and gr_no = 'A';
  perform set_config('test.uid', own::text, false);

  before := (public.fn_counter_summary()->>'income_today')::numeric;

  -- 02:00 in Karachi TODAY is 21:00 YESTERDAY in UTC, which is precisely what
  -- the old date_trunc('day', now()) bound counted it as.
  insert into public.payments(school_id, student_id, amount, method, receipt_no, status,
                              received_by, created_at)
  values (sch, s1, 5000, 'cash', public.next_counter('receipt'), 'verified', own,
          (today::text || ' 02:00+05')::timestamptz);

  after := (public.fn_counter_summary()->>'income_today')::numeric;

  perform pg_temp.ok(after - before = 5000,
    '5. a fee taken at 02:00 in Karachi counts as TODAY. Before the fix it landed on '
    || 'yesterday''s figure, on the counter screen and on the dashboard, every morning, for '
    || 'five hours (today''s total moved by Rs ' || (after - before) || ')');
end $clock$;

rollback;
\echo 'THE MONTH AND THE ARREARS: ALL TESTS PASSED'
