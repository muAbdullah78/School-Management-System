-- =============================================================================
-- SIMULATION, PART 9: is this a believable school?
--
-- Every one of these assertions exists because the simulation got it WRONG at
-- some point during this run and the mistake was caught by eye rather than by
-- anything automatic. A seed that reports success while producing a school with
-- 3.4 children per section-day, or one whose newest payment is next Tuesday, is
-- worse than one that fails: it gets believed.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/09_check.sql
-- =============================================================================

\set ON_ERROR_STOP on

do $check$
declare
  v_school uuid;
  v_fail text[] := '{}';
  v_n numeric; v_m numeric;
  procedure_note text;
begin
  select id into v_school from public.schools
   where name = 'Chaudhary Puclix High School Ghauriii';
  if v_school is null then raise exception 'school not found'; end if;

  -- 1. NOTHING IS DATED IN THE FUTURE. 149 payments, three payrolls and an
  --    enquiry once were, because the current month is only part over and the
  --    spread was not clamped.
  select count(*) into v_n from (
    select 1 from public.payments where school_id=v_school and created_at::date > current_date
    union all select 1 from public.expenses where school_id=v_school and (spent_on > current_date or created_at::date > current_date)
    union all select 1 from public.other_income where school_id=v_school and received_on > current_date
    union all select 1 from public.attendance_daily where school_id=v_school and attendance_date > current_date
    union all select 1 from public.students where school_id=v_school and admission_date > current_date
    union all select 1 from public.admission_enquiries where school_id=v_school and created_at::date > current_date
    union all select 1 from public.audit_log where school_id=v_school and created_at::date > current_date
  ) q;
  if v_n > 0 then v_fail := v_fail || format('%s row(s) dated after today', v_n); end if;

  -- 2. TODAY IS LIVE. The point of the whole exercise: somebody logging in now
  --    must see today's school, not a museum.
  select count(*) into v_n from public.attendance_daily
   where school_id = v_school and attendance_date = current_date;
  if v_n < 50 then v_fail := v_fail || format('only %s children marked today', v_n); end if;

  select count(*) into v_n from public.staff_attendance
   where school_id = v_school and attendance_date = current_date;
  if v_n < 5 then v_fail := v_fail || format('only %s staff marked today', v_n); end if;

  select count(*) into v_n from public.payments
   where school_id = v_school and created_at::date = current_date;
  if v_n < 1 then v_fail := v_fail || 'no money taken today'; end if;

  -- 3. TODAY IS NOT FINISHED EITHER. A register that is already locked at 11am
  --    is yesterday's register.
  select count(*) into v_n from public.attendance_daily
   where school_id = v_school and attendance_date = current_date and not is_locked;
  if v_n = 0 then v_fail := v_fail || 'today''s register is already finalised'; end if;

  -- 4. THE REGISTER IS DENSE. This is the one that caught the module-by-module
  --    seed: 6,098 section-days holding 21,123 rows, 3.4 children each.
  select count(*)::numeric, count(distinct (enrollment_id, attendance_date))::numeric
    into v_n, v_m
    from public.attendance_daily where school_id = v_school;
  if v_n < 60000 then v_fail := v_fail || format('only %s attendance rows', v_n); end if;
  select round(count(*)::numeric / nullif(count(distinct (attendance_date, e.section_id)), 0), 1)
    into v_n
    from public.attendance_daily ad
    join public.enrollments e on e.id = ad.enrollment_id
   where ad.school_id = v_school;
  if v_n < 8 then
    v_fail := v_fail || format('%s children per section-day: the roll is too thin', v_n);
  end if;

  -- 5. THE YEARS ACTUALLY HAPPENED. Three rollovers means four sessions with
  --    enrollments in them, not one session holding everybody.
  select count(*) into v_n from (
    select a.id from public.academic_sessions a
     where a.school_id = v_school
       and exists (select 1 from public.enrollments e where e.session_id = a.id)) q;
  if v_n < 4 then v_fail := v_fail || format('only %s session(s) have enrollments', v_n); end if;

  select count(*) into v_n from public.enrollments
   where school_id = v_school and status = 'promoted';
  if v_n < 300 then v_fail := v_fail || format('only %s promoted enrollments', v_n); end if;

  -- 6. THE MONEY IS NOT ALL PAID AND NOT ALL UNPAID. A school with no
  --    defaulters has nothing for the fee reports to be right about.
  select count(*) into v_n from public.invoices
   where school_id = v_school and status in ('issued','partial');
  if v_n < 100 then v_fail := v_fail || format('only %s unpaid challans', v_n); end if;
  select count(*) into v_n from public.invoices
   where school_id = v_school and status = 'paid';
  if v_n < 1000 then v_fail := v_fail || format('only %s paid challans', v_n); end if;

  -- 7. THE CORRECTION PATHS HAVE BEEN WALKED.
  select count(*) into v_n from public.payments
   where school_id = v_school and reversal_of is not null;
  if v_n < 1 then v_fail := v_fail || 'no payment has ever been reversed'; end if;
  select count(*) into v_n from public.invoices
   where school_id = v_school and status = 'void';
  if v_n < 1 then v_fail := v_fail || 'no challan has ever been voided'; end if;

  --     AND THE REGISTER HAS BEEN PUT RIGHT. This one was zero for the whole
  --     of the first build, and chasing that down is what found the bug in
  --     0121: every past day is finalised, fn_mark_attendance skips a locked
  --     row, and nothing in the schema could clear the lock. So the corrections
  --     report had never been seen with a row in it, and no school could have
  --     corrected a mistake even if it had.
  select count(*) into v_n from public.attendance_daily
   where school_id = v_school and corrected_from is not null;
  if v_n < 5 then
    v_fail := v_fail || format('only %s attendance row(s) carry a correction, so '
      || 'the corrections report is empty and the unlock path is unexercised', v_n);
  end if;
  select count(*) into v_n from public.audit_log
   where school_id = v_school and action = 'ATTENDANCE_UNLOCK';
  if v_n < 5 then
    v_fail := v_fail || format('only %s reopened register(s) in the audit log', v_n);
  end if;

  -- 8. THE DRAWER HAS BEEN COUNTED, AND HAS DISAGREED IN BOTH DIRECTIONS.
  --    The first version's two hashes were correlated and produced five overs
  --    and no shorts, which is half a test.
  select count(*) into v_n from public.till_sessions
   where school_id = v_school and status <> 'open' and variance < 0;
  if v_n < 1 then v_fail := v_fail || 'no drawer has ever come up short'; end if;
  select count(*) into v_n from public.till_sessions
   where school_id = v_school and status <> 'open' and variance > 0;
  if v_n < 1 then v_fail := v_fail || 'no drawer has ever come up over'; end if;

  -- 9. RESULTS EXIST AND ONE TERM IS STILL UNPUBLISHED, so the portal has
  --    something to correctly refuse.
  select count(*) into v_n from public.result_cards where school_id = v_school;
  if v_n < 200 then v_fail := v_fail || format('only %s result cards', v_n); end if;

  -- 10. THE AUDIT LOG READS LIKE A LOG. Ordered by created_at on the one screen
  --     that shows it, so a log where every entry claims the same second is not
  --     a log. This is what the clock pass exists for.
  select count(distinct created_at::date) into v_n
    from public.audit_log where school_id = v_school;
  if v_n < 300 then
    v_fail := v_fail || format('the audit log spans only %s distinct days', v_n);
  end if;

  -- 11. THE OUTBOX HAS BEEN WORKED, AND STILL HAS A BACKLOG.
  select count(*) into v_n from public.message_outbox
   where school_id = v_school and status = 'sent';
  if v_n < 100 then v_fail := v_fail || 'nothing has ever been sent from the outbox'; end if;
  select count(*) into v_n from public.message_outbox
   where school_id = v_school and status = 'queued';
  if v_n < 10 then v_fail := v_fail || 'the outbox has no backlog, which no school has'; end if;

  if array_length(v_fail, 1) > 0 then
    raise exception E'this is not a believable school:\n  - %',
      array_to_string(v_fail, E'\n  - ');
  end if;

  raise notice 'BELIEVABLE. % rows, % children on the roll, % attendance rows over % days, % result cards, audit log spans % days',
    (select sum(n_live_tup) from pg_stat_user_tables),
    (select count(*) from public.students where school_id=v_school and status='active'),
    (select count(*) from public.attendance_daily where school_id=v_school),
    (select count(distinct attendance_date) from public.attendance_daily where school_id=v_school),
    (select count(*) from public.result_cards where school_id=v_school),
    (select count(distinct created_at::date) from public.audit_log where school_id=v_school);
end
$check$;
