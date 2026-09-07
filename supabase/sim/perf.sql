-- =============================================================================
-- THE READ SWEEP: every screen in the product, timed, on a full database.
--
-- Each call is made three times and the LAST is reported, so the number is a
-- warm-cache figure rather than a first-read one. A school's second visit to a
-- screen is the common case and the fair one to quote; the cold number is
-- always worse and is noted where it matters.
--
-- Run as a real signed-in owner with RLS on, because a definer function called
-- by a superuser skips the policy machinery that a real request pays for.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/perf.sql
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

begin;

select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = 'Chaudhary Puclix High School Ghauriii'
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

create temp table perf(screen text, call text, ms numeric) on commit drop;

do $perf$
declare
  v_sess uuid; v_class uuid; v_section uuid; v_stu uuid; v_fam uuid;
  v_enr uuid; v_term uuid; v_es uuid; v_staff uuid;
  t0 timestamptz; i int;

  procedure_placeholder int;
begin
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current;
  select c.id, s.id into v_class, v_section
    from public.classes c join public.sections s on s.class_id = c.id
   where c.school_id = public.current_school_id() and c.level_order = 5
   order by s.sort_order limit 1;
  select st.id, st.family_id into v_stu, v_fam from public.students st
   where st.school_id = public.current_school_id() and st.status = 'active'
     and st.family_id is not null limit 1;
  select e.id into v_enr from public.enrollments e
   where e.student_id = v_stu and e.session_id = v_sess limit 1;
  select id into v_term from public.exam_terms
   where school_id = public.current_school_id() order by starts_on desc limit 1;
  select id into v_es from public.exam_subjects where exam_term_id = v_term limit 1;
  select id into v_staff from public.staff
   where school_id = public.current_school_id() and status = 'active' limit 1;

  -- A tiny helper would need a function; three explicit runs is clearer and
  -- means the timing code is visible beside the call it times.
  <<dashboard>> begin
    for i in 1..3 loop t0 := clock_timestamp();
      perform public.fn_dashboard_summary();
    end loop;
    insert into perf values ('Dashboard', 'fn_dashboard_summary()',
      extract(epoch from (clock_timestamp()-t0))*1000);
  end;

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_global_search('Ahmed', 20); end loop;
  insert into perf values ('Search bar', 'fn_global_search(''Ahmed'')', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_global_search('Chaudhary', 20); end loop;
  insert into perf values ('Search bar', 'fn_global_search(''Chaudhary'') -- 30 hits', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_global_search('0300', 20); end loop;
  insert into perf values ('Search bar', 'fn_global_search(''0300'') -- a phone prefix', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_global_search('R-1', 20); end loop;
  insert into perf values ('Search bar', 'fn_global_search(''R-1'') -- a receipt', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_student_list(null, null, null, false, 50, 0); end loop;
  insert into perf values ('Students', 'fn_student_list() page 1', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_student_list(null, null, null, true, 50, 200); end loop;
  insert into perf values ('Students', 'fn_student_list() page 5, inactive too', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_section_roster(v_sess, v_class, v_section, current_date); end loop;
  insert into perf values ('Attendance', 'fn_section_roster() today', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_attendance_summary(v_enr, current_date - 365, current_date); end loop;
  insert into perf values ('Attendance', 'fn_attendance_summary() one child, a year', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_defaulters(v_sess); end loop;
  insert into perf values ('Fees', 'fn_defaulters() whole school', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_class_dues(v_sess, v_class, v_section, date_trunc('month', current_date)::date); end loop;
  insert into perf values ('Fees', 'fn_class_dues() one section', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_head_wise_dues(v_sess); end loop;
  insert into perf values ('Fees', 'fn_head_wise_dues() whole school', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_student_ledger(v_stu); end loop;
  insert into perf values ('Fees', 'fn_student_ledger() one child, 2.5 years', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_family_sheet(v_fam); end loop;
  insert into perf values ('Fees', 'fn_family_sheet() one family', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_fee_reconciliation(v_sess); end loop;
  insert into perf values ('Reports', 'fn_fee_reconciliation() expected vs collected', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_report_unpaid_invoices(v_sess); end loop;
  insert into perf values ('Reports', 'fn_report_unpaid_invoices()', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_report_ledger(current_date - 365, current_date, 'all'); end loop;
  insert into perf values ('Reports', 'fn_report_ledger() a full year', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_report_balance_sheet(current_date); end loop;
  insert into perf values ('Reports', 'fn_report_balance_sheet()', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_finance_summary(date_trunc('month', current_date)::date, current_date); end loop;
  insert into perf values ('Accounts', 'fn_finance_summary() this month', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_profit_snapshot(); end loop;
  insert into perf values ('Accounts', 'fn_profit_snapshot()', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_counter_summary(); end loop;
  insert into perf values ('Cash drawer', 'fn_counter_summary()', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_till_report(current_date - 120, current_date); end loop;
  insert into perf values ('Cash drawer', 'fn_till_report() 120 days', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_recent_payments(25); end loop;
  insert into perf values ('Fees', 'fn_recent_payments(25)', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_enquiry_list(null, null, null, null, false, 200, 0); end loop;
  insert into perf values ('Enquiries', 'fn_enquiry_list() 200', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform public.fn_enquiry_summary(); end loop;
  insert into perf values ('Enquiries', 'fn_enquiry_summary()', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_birthdays(30); end loop;
  insert into perf values ('Birthdays', 'fn_birthdays(30)', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_exam_marksheet(v_es); end loop;
  insert into perf values ('Exams', 'fn_exam_marksheet() one paper', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_position_holders(v_term, 3); end loop;
  insert into perf values ('Exams', 'fn_position_holders() top 3', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_certificate_register(100); end loop;
  insert into perf values ('Certificates', 'fn_certificate_register(100)', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_staff_attendance_summary(v_staff, current_date - 365, current_date); end loop;
  insert into perf values ('Staff', 'fn_staff_attendance_summary() a year', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_report_admissions(current_date - 730, current_date); end loop;
  insert into perf values ('Reports', 'fn_report_admissions() two years', extract(epoch from (clock_timestamp()-t0))*1000);

  for i in 1..3 loop t0 := clock_timestamp(); perform * from public.fn_report_discounts(current_date - 730, current_date); end loop;
  insert into perf values ('Reports', 'fn_report_discounts() two years', extract(epoch from (clock_timestamp()-t0))*1000);
end
$perf$;

select rpad(screen, 14) || rpad(call, 46) ||
       lpad(round(ms, 1)::text, 9) || ' ms' ||
       case when ms > 1000 then '   <<< over a second'
            when ms > 300  then '   <<  slow'
            when ms > 100  then '   <   worth a look'
            else '' end as read_sweep
  from perf order by ms desc;

rollback;
