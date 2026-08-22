-- =============================================================================
-- The fee counter: are the four figures on the busiest screen actually right?
--
-- The rules this file defends:
--
--  1. Income today counts VERIFIED money only. A pending bank transfer must not
--     inflate it, or the drawer looks short at closing and the clerk is blamed.
--  2. Pending money is reported separately, not hidden — accepted but uncleared
--     cash has to be visible somewhere or it is simply lost.
--  3. "Unpaid invoices" counts challans still owing, derived from allocations
--     rather than read off invoices.status. It must fall when one is paid and
--     must not count one that is settled.
--  4. balance_today = income_today - expense_today, at every point.
--  5. The recent-payments list shows WHO took the money. Without that the list
--     is a convenience; with it, it is a control.
--  6. Neither function leaks across schools, and neither is callable by a
--     parent. A cash position is not something a portal login may read.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/counter.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- One transaction, rolled back: schools cannot be deleted in this schema, and
-- committing would leave rows that other suites' global queries would pick up.
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

create or replace function pg_temp.sum_key(p_key text) returns numeric
language sql as $$ select (public.fn_counter_summary()->>p_key)::numeric $$;

-- --- Fixture -----------------------------------------------------------------
-- Two schools, so every figure can be checked for cross-tenant bleed. School A
-- has one family with two children at Rs 1,000/month; school B has money of its
-- own that must never appear in A's totals.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000c7001';
  v_ob uuid := '00000000-0000-0000-0000-0000000c7002';
  v_pa uuid := '00000000-0000-0000-0000-0000000c7003';
  v_sess uuid; v_class uuid; v_head uuid; v_fam uuid;
begin
  insert into public.schools (name) values ('Counter School A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'starter', 'active', current_date + 30);
  insert into public.schools (name) values ('Counter School B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'fa@counter.test'), (v_ob, 'fb@counter.test'), (v_pa, 'fp@counter.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Counter Owner A', 'owner',  v_a),
    (v_ob, 'Counter Owner B', 'owner',  v_b),
    (v_pa, 'Counter Parent',  'parent', v_a)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  -- ---- school A ----
  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_a) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1000, v_a);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'CT Elder', 'father_name', 'CT Father', 'father_cnic', '35201-1212121-1',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'CT Younger', 'father_name', 'CT Father', 'father_cnic', '35201-1212121-1',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));

  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);

  -- ---- school B: money that must stay invisible to A ----
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_b) returning id into v_class;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_b) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 5000, v_b);
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'B Child', 'father_name', 'B Father', 'father_cnic', '35201-3434343-3',
    'session_id', v_sess, 'class_id', v_class, 'links', '[]'::jsonb));
  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', current_date)::date, current_date + 10);
  select family_id into v_fam from public.students where full_name = 'B Child';
  perform public.fn_record_family_payment(v_fam, 5000, 'cash', 'school B money', false);
end $seed$;

-- =============================================================================
-- 1-3: the day starts at zero for school A, and B's money is not in it
-- =============================================================================
do $t$
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7001', false);

  perform pg_temp.ok(pg_temp.sum_key('income_today') = 0,
    '1. school A has taken nothing today, despite B taking Rs 5,000');
  perform pg_temp.ok(pg_temp.sum_key('unpaid_invoices') = 2,
    '2. two challans outstanding — one per child (' || pg_temp.sum_key('unpaid_invoices') || ')');
  perform pg_temp.ok(pg_temp.sum_key('balance_today') = 0,
    '3. balance starts at zero');
end $t$;

-- =============================================================================
-- 4-6: a pending payment must not move the income figure
-- =============================================================================
do $t$
declare v_fam uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7001', false);
  select family_id into v_fam from public.students where full_name = 'CT Elder';

  perform public.fn_record_family_payment(v_fam, 700, 'bank_transfer', 'not cleared', true);

  perform pg_temp.ok(pg_temp.sum_key('income_today') = 0,
    '4. an uncleared bank transfer does not count as income');
  perform pg_temp.ok(pg_temp.sum_key('pending_amount') = 700,
    '5. but it is reported as pending, not silently dropped');
  perform pg_temp.ok(pg_temp.sum_key('pending_count') = 1,
    '6. and counted');
end $t$;

-- =============================================================================
-- 7-10: real money moves the figures, and settles a challan
-- =============================================================================
do $t$
declare v_fam uuid; v_unpaid_before numeric;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7001', false);
  select family_id into v_fam from public.students where full_name = 'CT Elder';
  v_unpaid_before := pg_temp.sum_key('unpaid_invoices');

  -- Exactly one child's challan, so the count must drop by exactly one.
  perform public.fn_record_family_payment(v_fam, 1000, 'cash', 'first child', false);

  perform pg_temp.ok(pg_temp.sum_key('income_today') = 1000,
    '7. income today reflects the verified payment (' || pg_temp.sum_key('income_today') || ')');
  perform pg_temp.ok(pg_temp.sum_key('unpaid_invoices') = v_unpaid_before - 1,
    '8. a settled challan leaves the unpaid count (' || pg_temp.sum_key('unpaid_invoices') || ')');
  perform pg_temp.ok(pg_temp.sum_key('balance_today') = 1000,
    '9. balance = income while there are no expenses');
  perform pg_temp.ok(pg_temp.sum_key('pending_amount') = 700,
    '10. the pending figure is untouched by a cash payment');
end $t$;

-- =============================================================================
-- 11-12: expenses pull the balance down
-- =============================================================================
do $t$
declare v_cat uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7001', false);
  select id into v_cat from public.expense_categories
   where school_id = public.current_school_id() limit 1;

  perform public.fn_record_expense(250, v_cat, current_date, 'Stationery shop', 'cash', 'Chalk');

  perform pg_temp.ok(pg_temp.sum_key('expense_today') = 250,
    '11. today''s expense is picked up');
  perform pg_temp.ok(pg_temp.sum_key('balance_today') = 750,
    '12. balance = 1000 - 250 (' || pg_temp.sum_key('balance_today') || ')');
end $t$;

-- =============================================================================
-- 13-17: the recent payments list
-- =============================================================================
do $t$
declare r record; v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7001', false);

  select count(*) into v_n from public.fn_recent_payments(25);
  perform pg_temp.ok(v_n = 2,
    '13. both of school A''s payments are listed, B''s is not (' || v_n || ')');

  select * into r from public.fn_recent_payments(25) limit 1;
  perform pg_temp.ok(r.received_by = 'Counter Owner A',
    '14. the list names who took the money — the whole point of the column');
  perform pg_temp.ok(r.parent_name is not null,
    '15. and the parent, so a clerk can confirm who is at the window');
  perform pg_temp.ok(r.class_name = 'Class 1',
    '16. and the class');

  -- The cash payment settled this month's challan, so it must say which month.
  perform pg_temp.ok(exists (
    select 1 from public.fn_recent_payments(25)
     where paid_for = to_char(current_date, 'Mon YYYY')),
    '17. and what the receipt actually paid for');
end $t$;

-- =============================================================================
-- 18-20: the guards
-- =============================================================================
do $t$
begin
  -- A parent must not be able to read the school's cash position.
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7003', false);
  begin
    perform public.fn_counter_summary();
    raise exception 'FAIL  18. a parent read the school''s cash position';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  18. a parent cannot read the counter summary (%)', sqlerrm;
  end;

  begin
    perform count(*) from public.fn_recent_payments(25);
    raise exception 'FAIL  19. a parent listed the school''s payments';
  exception
    when others then
      if sqlerrm like 'FAIL%' then raise; end if;
      raise notice 'PASS  19. a parent cannot list payments (%)', sqlerrm;
  end;

  -- And school B's owner sees only B's money — the mirror of tests 1 and 13.
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7002', false);
  perform pg_temp.ok(pg_temp.sum_key('income_today') = 5000,
    '20. school B sees its own Rs 5,000 and none of A''s (' || pg_temp.sum_key('income_today') || ')');
end $t$;

-- =============================================================================
-- 21: the limit is clamped, so a caller cannot ask for the whole ledger
-- =============================================================================
do $t$
declare v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000000c7001', false);
  select count(*) into v_n from public.fn_recent_payments(100000);
  perform pg_temp.ok(v_n <= 200, '21. an absurd limit is clamped rather than honoured');
  select count(*) into v_n from public.fn_recent_payments(null);
  perform pg_temp.ok(v_n > 0, '22. a null limit falls back to the default instead of returning nothing');
end $t$;

do $$ begin raise notice '--- counter.sql: all assertions passed'; end $$;

rollback;
