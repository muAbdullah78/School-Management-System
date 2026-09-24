-- =============================================================================
-- The office all day (0147): Accounts in Karachi time, fee reads for the fee
-- office only, a due day after the billing day, a test that cannot be locked
-- half marked and can be reopened by the head, and the chart reads.
--
-- Every chart read is checked against a figure the school already trusts, so
-- a chart cannot start telling a different story from the tile beside it:
--
--   fn_fees_today            equals the dashboard's collected today
--   fn_finance_months        its last month equals the profit snapshot's month
--   fn_attendance_overview   its marked counts equal fn_attendance_day's
--   fn_tests_marks           its average is worked by hand below
--   fn_discounts_month       equals the discount lines on the month's challans
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_office_all_day.sql
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

create or replace function pg_temp.raises(p_sql text, p_label text, p_like text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_like is not null and sqlerrm not like p_like then
      raise exception 'FAIL  % (refused, but with: %)', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 80);
    return;
  end;
  raise exception 'FAIL  % (it was ALLOWED)', p_label;
end;
$$;

create or replace function pg_temp.k_today() returns date language sql stable as
  $$ select (now() at time zone 'Asia/Karachi')::date $$;

-- --- Fixture -----------------------------------------------------------------
do $seed$
declare
  v_a uuid; v_b uuid;
  v_own uuid := '00000000-0000-0000-0000-0000000fa001';
  v_pr  uuid := '00000000-0000-0000-0000-0000000fa002';
  v_ct  uuid := '00000000-0000-0000-0000-0000000fa003';
  v_ob  uuid := '00000000-0000-0000-0000-0000000fa004';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid; v_stf uuid;
  v_sess_b uuid;
  v_d date; v_i int;
  v_ay uuid; v_bi uuid; v_ch uuid;
  v_disc uuid;
begin
  insert into public.schools (name) values ('Office A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Office B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own, 'own@office.test'), (v_pr, 'pr@office.test'),
    (v_ct, 'ct@office.test'), (v_ob, 'ob@office.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own, 'Office Owner',     'owner',         v_a),
    (v_pr,  'Office Principal', 'principal',     v_a),
    (v_ct,  'Office Teacher',   'class_teacher', v_a),
    (v_ob,  'Office B Owner',   'owner',         v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2026-2027', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Office Class 1', 1, v_a) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_a) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1000, v_a);

  insert into public.staff (full_name, designation, school_id)
    values ('Office Teacher', 'Teacher', v_a) returning id into v_stf;
  alter table public.profiles disable trigger user;
  update public.profiles set staff_id = v_stf where id = v_ct;
  alter table public.profiles enable trigger user;
  perform public.fn_set_class_teacher(v_stf, v_sess, v_class, v_sec);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'Ayesha Office', 'session_id', v_sess, 'class_id', v_class,
    'section_id', v_sec, 'roll_no', '1', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'Bilal Office', 'session_id', v_sess, 'class_id', v_class,
    'section_id', v_sec, 'roll_no', '2', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'Chand Office', 'session_id', v_sess, 'class_id', v_class,
    'section_id', v_sec, 'roll_no', '3', 'links', '[]'::jsonb));

  select e.id into v_ay from public.enrollments e join public.students s on s.id = e.student_id
   where s.full_name = 'Ayesha Office';
  select e.id into v_bi from public.enrollments e join public.students s on s.id = e.student_id
   where s.full_name = 'Bilal Office';
  select e.id into v_ch from public.enrollments e join public.students s on s.id = e.student_id
   where s.full_name = 'Chand Office';

  -- Twelve school days before today. Ayesha every day (100), Bilal away four
  -- (66.7, below the line), Chand away three (75.0 exactly, on the line and so
  -- NOT below it).
  for v_i in 1 .. 12 loop
    v_d := pg_temp.k_today() - v_i;
    insert into public.attendance_daily (enrollment_id, attendance_date, status, school_id)
      values (v_ay, v_d, 'present', v_a),
             (v_bi, v_d, case when v_i <= 4 then 'absent' else 'present' end::public.attendance_status, v_a),
             (v_ch, v_d, case when v_i <= 3 then 'absent' else 'present' end::public.attendance_status, v_a);
  end loop;

  perform public.fn_generate_class_invoices(v_sess, v_class,
    date_trunc('month', pg_temp.k_today())::date, pg_temp.k_today() + 10);

  -- A ten per cent concession on Ayesha, approved, which reprices her month.
  v_disc := public.fn_add_discount(
    (select id from public.students where full_name = 'Ayesha Office'),
    'sibling', 10, true, 'two in the school',
    date_trunc('month', pg_temp.k_today())::date, null);
  perform public.fn_set_discount_status(v_disc, 'approved');

  -- School B, with a session of its own.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2026-2027', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;

  perform set_config('test.uid', v_own::text, false);
  raise notice 'fixture ok';
end $seed$;

create or replace function pg_temp.sess() returns uuid language sql as $$
  select s.id from public.academic_sessions s join public.schools sch on sch.id = s.school_id
   where sch.name = 'Office A'
$$;
create or replace function pg_temp.klass() returns uuid language sql as $$
  select id from public.classes where name = 'Office Class 1'
$$;
create or replace function pg_temp.student(p text) returns uuid language sql as $$
  select id from public.students where full_name = p
$$;

-- =============================================================================
-- 1-6: ACCOUNTS COUNTS A PAYMENT ON THE DAY IT WAS TAKEN IN PAKISTAN
-- =============================================================================
do $t$
declare v_pay uuid; v_on_day numeric; v_day_before numeric; v_early timestamptz;
begin
  perform pg_temp.be('Office Owner');
  perform public.fn_record_payment(pg_temp.student('Ayesha Office'), 500, 'cash', 'early', false);
  select id into v_pay from public.payments where note = 'early';
  -- 02:00 in Karachi is 21:00 UTC the day before: the case that was counted
  -- on the wrong day.
  v_early := (pg_temp.k_today()::text || ' 02:00:00')::timestamp at time zone 'Asia/Karachi';
  update public.payments set created_at = v_early where id = v_pay;

  v_on_day := (public.fn_finance_summary(pg_temp.k_today(), pg_temp.k_today())->>'fee_income')::numeric;
  v_day_before := (public.fn_finance_summary(pg_temp.k_today() - 1, pg_temp.k_today() - 1)->>'fee_income')::numeric;
  perform pg_temp.ok(v_on_day = 500, '1. a fee taken at 02:00 Karachi counts on that Karachi day');
  perform pg_temp.ok(v_day_before = 0, '2. and not on the day before, which is where UTC put it');
  perform pg_temp.ok((public.fn_profit_snapshot()->'today'->>'fee_income')::numeric = 500,
                     '3. Profit today agrees');
end $t$;

do $t$
begin
  perform pg_temp.be('Office Owner');
  perform pg_temp.raises(
    format('select public.fn_record_expense(100, null, %L::date, ''K-Electric'', ''cash'', null)',
           pg_temp.k_today() + 1),
    '4. an expense dated tomorrow is refused', '%cannot be dated after today%');
  perform pg_temp.raises(
    format('select public.fn_record_other_income(100, ''Canteen'', %L::date, ''cash'', null)',
           pg_temp.k_today() + 1),
    '5. income dated tomorrow is refused', '%cannot be dated after today%');
  perform public.fn_record_expense(250, null, pg_temp.k_today(), 'K-Electric', 'cash', null);
  perform public.fn_record_expense(50, null);
  perform pg_temp.ok(
    (select spent_on from public.expenses where amount = 50) = pg_temp.k_today(),
    '6. an expense with no date is dated today in Karachi');
end $t$;

do $t$
declare v_m jsonb; v_last jsonb;
begin
  perform pg_temp.be('Office Owner');
  v_m := public.fn_finance_months(3);
  v_last := v_m->(jsonb_array_length(v_m) - 1);
  perform pg_temp.ok(jsonb_array_length(v_m) = 3, '7. three months asked, three months given');
  perform pg_temp.ok(
    (v_last->>'total_income')::numeric = (public.fn_profit_snapshot()->'month'->>'total_income')::numeric
    and (v_last->>'expenses')::numeric = (public.fn_profit_snapshot()->'month'->>'expenses')::numeric,
    '8. the chart''s this month is the tile''s this month');
  perform pg_temp.ok((v_last->>'expenses')::numeric = 300, '9. both expenses are in it');
  perform pg_temp.be('Office Teacher');
  perform pg_temp.raises('select public.fn_finance_months(3)', '10. a teacher does not see the books');
end $t$;

-- =============================================================================
-- 11-18: THE FEE READS ARE FOR THE FEE OFFICE
-- =============================================================================
do $t$
begin
  perform pg_temp.be('Office Teacher');
  perform pg_temp.raises(
    format('select * from public.fn_class_dues(%L, %L, null, %L)',
           pg_temp.sess(), pg_temp.klass(), date_trunc('month', pg_temp.k_today())::date),
    '11. a teacher cannot read a class''s dues and phone numbers');
  perform pg_temp.raises('select * from public.fn_recent_payments(10)',
    '12. a teacher cannot read the receipts');
  perform pg_temp.raises('select public.fn_counter_summary()',
    '13. a teacher cannot read the counter');
  perform pg_temp.raises('select * from public.fn_student_list()',
    '14. a teacher cannot read every child''s balance');
  perform pg_temp.raises(format('select * from public.fn_report_unpaid_invoices(%L)', pg_temp.sess()),
    '15. a teacher cannot read the unpaid challans');
  perform pg_temp.raises('select public.fn_fees_today()',
    '16. nor the day at the counter');

  perform pg_temp.be('Office Owner');
  perform pg_temp.ok(
    (select count(*) from public.fn_class_dues(pg_temp.sess(), pg_temp.klass(), null,
       date_trunc('month', pg_temp.k_today())::date)) = 3,
    '17. the owner reads the class, all three children');
  perform pg_temp.ok((select count(*) from public.fn_student_list()) = 3,
    '18. and the roll');
end $t$;

-- =============================================================================
-- 19-22: THE DAY AT THE COUNTER, AND WHAT THE CONCESSIONS COST
-- =============================================================================
do $t$
declare v jsonb; v_lines numeric;
begin
  perform pg_temp.be('Office Owner');
  perform public.fn_record_payment(pg_temp.student('Bilal Office'), 300, 'bank_challan', 'waiting', true);
  v := public.fn_fees_today();
  perform pg_temp.ok((v->>'cleared_total')::numeric = (public.fn_dashboard_summary()->>'collected_today')::numeric,
    '19. cleared today equals the dashboard''s collected today');
  perform pg_temp.ok((v->>'pending_count')::int = 1 and (v->>'pending_total')::numeric = 300,
    '20. the payment waiting on the bank is counted apart');

  select coalesce(sum(l.amount), 0) into v_lines
    from public.invoice_lines l join public.invoices i on i.id = l.invoice_id
   where i.session_id = pg_temp.sess() and l.is_discount and i.status <> 'void'
     and i.period_month = date_trunc('month', pg_temp.k_today())::date;
  v := public.fn_discounts_month(pg_temp.sess());
  perform pg_temp.ok(v_lines > 0 and (v->>'amount')::numeric = v_lines and (v->>'children')::int = 1,
    '21. the month''s concessions are the discount lines on its challans');

  perform pg_temp.be('Office B Owner');
  perform pg_temp.raises(format('select public.fn_discounts_month(%L)', pg_temp.sess()),
    '22. another school cannot ask about this one');
end $t$;

-- =============================================================================
-- 23-24: THE FEE FALLS DUE AFTER IT IS RAISED
-- =============================================================================
do $t$
begin
  perform pg_temp.be('Office Owner');
  perform pg_temp.raises('select public.fn_set_billing_days(15, 10, true)',
    '23. due on the 10th, raised on the 15th, is refused', '%cannot fall due%');
  perform public.fn_set_billing_days(5, 10, true);
  perform pg_temp.ok((select due_day from public.school_settings ss join public.schools s on s.id = ss.school_id
                       where s.name = 'Office A') = 10,
    '24. raised on the 5th and due on the 10th is saved');
end $t$;

-- =============================================================================
-- 25-36: A TEST IS FINISHED WHEN EVERY CHILD HAS A MARK
-- =============================================================================
do $t$
declare v_t uuid; v_ay uuid; v_bi uuid; v_ch uuid; v_r record;
begin
  select e.id into v_ay from public.enrollments e where e.student_id = pg_temp.student('Ayesha Office');
  select e.id into v_bi from public.enrollments e where e.student_id = pg_temp.student('Bilal Office');
  select e.id into v_ch from public.enrollments e where e.student_id = pg_temp.student('Chand Office');

  perform pg_temp.be('Office Teacher');
  insert into public.assessments (session_id, class_id, section_id, title, assessment_date, max_marks, school_id)
    values (pg_temp.sess(), pg_temp.klass(),
            (select id from public.sections where class_id = pg_temp.klass()),
            'Weekly spelling', pg_temp.k_today() - 1, 20,
            (select id from public.schools where name = 'Office A'))
    returning id into v_t;
  perform pg_temp.ok((select created_by from public.assessments where id = v_t)
                       = (select id from public.profiles where full_name = 'Office Teacher'),
    '25. the test records who set it');

  perform public.fn_enter_assessment_marks(v_t, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_ay, 'marks', 15),
    jsonb_build_object('enrollment_id', v_bi, 'marks', 5)));
  perform pg_temp.raises(format('select public.fn_lock_assessment(%L)', v_t),
    '26. locking with one child unmarked is refused', '%1 child(ren)%');
  perform pg_temp.ok(not (select is_locked from public.assessments where id = v_t),
    '27. and nothing was locked');

  perform public.fn_enter_assessment_marks(v_t, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_ch, 'is_absent', true)));
  perform public.fn_lock_assessment(v_t);
  perform pg_temp.ok((select is_locked from public.assessments where id = v_t),
    '28. every child marked or absent, and it locks');

  perform pg_temp.be('Office Principal');
  select * into v_r from public.fn_tests_marks(pg_temp.sess(), pg_temp.k_today() - 30, pg_temp.k_today())
   where assessment_id = v_t;
  perform pg_temp.ok(v_r.sat = 2 and v_r.absent = 1, '29. two sat it, one was absent');
  perform pg_temp.ok(v_r.avg_pct = 50.0 and v_r.top_pct = 75.0,
    '30. the average is (75 + 25) / 2 and the top is 75, absentees left out');
  perform pg_temp.ok(v_r.below_pass = 1 and v_r.pass_pct = 33,
    '31. 5 out of 20 is below a 33 per cent pass, 15 is not');

  perform pg_temp.be('Office Teacher');
  perform pg_temp.raises(format('select public.fn_unlock_assessment(%L, ''wrong marks'')', v_t),
    '32. a teacher cannot reopen a locked test');
  perform pg_temp.be('Office Principal');
  perform pg_temp.raises(format('select public.fn_unlock_assessment(%L, '' '')', v_t),
    '33. the head must say why', '%why%');
  perform public.fn_unlock_assessment(v_t, 'Bilal''s paper was marked out of 10');
  perform pg_temp.ok(not (select is_locked from public.assessments where id = v_t)
                     and not exists (select 1 from public.mark_entries where assessment_id = v_t and is_locked),
    '34. reopened, and every mark with it');
  perform pg_temp.ok(exists (select 1 from public.audit_log where action = 'ASSESSMENT_UNLOCK'
                              and entity_id = v_t::text
                              and after->>'reason' = 'Bilal''s paper was marked out of 10'),
    '35. the reason is on the record');
  perform pg_temp.raises(format('select public.fn_unlock_assessment(%L, ''again please'')', v_t),
    '36. an open test cannot be reopened', '%not locked%');
end $t$;

-- =============================================================================
-- 37-43: THE REGISTER, SCHOOL-WIDE, FOR ANY DAY
-- =============================================================================
do $t$
declare v jsonb; v_day int; v_watch jsonb;
begin
  perform pg_temp.be('Office Principal');
  v := public.fn_attendance_overview(pg_temp.sess(), pg_temp.k_today() - 1);
  select sum(marked) into v_day from public.fn_attendance_day(pg_temp.sess(), pg_temp.k_today() - 1);
  perform pg_temp.ok((v->'sections'->0->>'marked')::int = v_day and v_day = 3,
    '37. the day''s tally is the register''s own count');
  perform pg_temp.ok((v->'sections'->0->>'absent')::int = 2 and (v->'sections'->0->>'present')::int = 1,
    '38. yesterday Bilal and Chand were away and Ayesha was in');
  perform pg_temp.ok(jsonb_array_length(v->'trend') = 12, '39. twelve school days, no Sundays invented');
  v_watch := v->'watchlist';
  perform pg_temp.ok(jsonb_array_length(v_watch) = 1 and v_watch->0->>'full_name' = 'Bilal Office'
                     and (v_watch->0->>'pct')::numeric = 66.7,
    '40. below 75 per cent: Bilal, and not Chand who is exactly on it');

  perform pg_temp.raises(format('select public.fn_attendance_overview(%L, %L::date)',
                                pg_temp.sess(), pg_temp.k_today() + 1),
    '41. a day that has not happened is refused');
  perform pg_temp.be('Office Teacher');
  perform pg_temp.raises(format('select public.fn_attendance_overview(%L)', pg_temp.sess()),
    '42. a teacher does not read the whole school');
  perform pg_temp.be('Office B Owner');
  perform pg_temp.raises(format('select public.fn_attendance_overview(%L)', pg_temp.sess()),
    '43. another school cannot read this one''s register');
end $t$;

-- =============================================================================
-- 44-45: REMOVE ON A PAPER SAYS WHAT IT TAKES WITH IT
-- =============================================================================
do $t$
declare v_term uuid; v_sub uuid; v_es uuid; v_a uuid := (select id from public.schools where name = 'Office A');
begin
  perform pg_temp.be('Office Owner');
  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('English', pg_temp.klass(), 1, v_a) returning id into v_sub;
  insert into public.exam_terms (session_id, name, term_type, school_id)
    values (pg_temp.sess(), 'First Term', 'first', v_a) returning id into v_term;
  insert into public.exam_subjects (exam_term_id, class_id, subject_id, max_marks, school_id)
    values (v_term, pg_temp.klass(), v_sub, 100, v_a) returning id into v_es;
  insert into public.mark_entries (exam_subject_id, enrollment_id, marks, max_marks, school_id)
    select v_es, e.id, 60, 100, v_a from public.enrollments e
     where e.class_id = pg_temp.klass() and e.student_id <> pg_temp.student('Chand Office');
  perform pg_temp.ok((public.fn_paper_marks_count(v_es)->>'marks')::int = 2,
    '44. two marks are on the paper, and the count says so');
  perform pg_temp.be('Office Teacher');
  perform pg_temp.raises(format('select public.fn_paper_marks_count(%L)', v_es),
    '45. a teacher is not the one who removes papers');
end $t$;

select 'ALL OFFICE ASSERTIONS PASSED' as result;
rollback;
