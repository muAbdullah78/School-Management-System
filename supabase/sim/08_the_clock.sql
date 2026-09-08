-- =============================================================================
-- SIMULATION, PART 8: making the clock agree with the calendar.
--
-- Everything up to here was written by the application's own functions, which
-- stamp created_at with the wall clock. So at this point two and a half years
-- of school life all claims to have been entered in the same few minutes: the
-- business dates are right (attendance_date, period_month, due_date, spent_on,
-- received_on, admission_date, assessment_date, exam dates) and the audit
-- timestamps are not.
--
-- That matters more than it sounds. "Collected today" on the dashboard,
-- "collected this month", the till report, fn_recent_payments, the audit log's
-- ordering and every "changed since" reading in the product are computed from
-- created_at. Left alone, this school would show two years of fees as having
-- been collected in one afternoon.
--
-- WHY THIS FILE HAS TO EXIST AT ALL, and it is finding F1 in FINDINGS.md.
-- `payments` has no business date. There is no paid_on column and
-- fn_record_payment takes no date argument, so there is NO WAY, through the
-- application, to say when money actually arrived. Expenses and other income
-- can both be dated (fn_record_expense takes p_spent_on, fn_record_other_income
-- takes p_received_on); fee income cannot. A clerk who enters Saturday's cash
-- on Monday has it counted in Monday's till and Saturday's drawer can never be
-- balanced.
--
-- So this file reaches around the schema, as the table owner, and that is
-- exactly the point: a school cannot do this, and correctly so. An application
-- that let a school rewrite its own audit timestamps would have no audit trail
-- at all. This is the one place in the whole simulation that steps outside what
-- the product can do, it is here rather than scattered through the other files
-- so that it can be counted, and the right fix is to give payments a paid_on
-- column rather than to keep this file.
--
-- -----------------------------------------------------------------------------
-- IT NOW TURNS THE ROW TRIGGERS OFF WHILE IT WORKS, AND THAT IS NOT AN
-- OPTIMISATION. It fixes a silent failure, and the measurement is what found
-- it. After this file had run:
--
--     rows    created_at on the right day    updated_at on the right day
--   89,634                        89,634                            202
--
-- Every one of the 89,634 `updated_at = attendance_date + time '08:20'`
-- assignments was thrown away, and all 89,634 values carried the minute the
-- seed ran. `trg_attendance_updated` is a BEFORE UPDATE trigger whose whole
-- body is `new.updated_at := now()`, so it overwrote each one on its way past.
-- The same trigger sits on students, enrollments, families, invoices and
-- mark_entries, which is six of the tables this file re-dates and roughly half
-- the timestamps it claims to move. The file reported success and did half the
-- job, which is the worst of the three possible outcomes.
--
-- Three more things it stops, each measured on the same school:
--
--   * 120,000 AUDIT ROWS WRITTEN AND THEN DELETED. Every re-dating is an
--     UPDATE and `trg_audit_attend` and friends fire on updates, so this file
--     used to write one full before/after row per timestamp it moved and then
--     delete them all again by watermark. About 120 MB of table churn to
--     produce nothing, and a delete does not shrink the file, so the school
--     was left needing a `vacuum full` afterwards to get the space back.
--     Migration 0126 does not help here: it skips the audit row when the ONLY
--     difference is `is_locked`, and this file changes `created_at`.
--   * 1,634 count refreshes. `fn__refresh_counts_touched` is an AFTER trigger
--     on students and enrollments, and this file updates every row of both.
--   * Any future AFTER trigger somebody adds to one of these fifteen tables,
--     which would fire 133,000 times on a file that is only moving a clock.
--
-- WHAT TURNING THEM OFF COSTS, said plainly. It takes an ACCESS EXCLUSIVE lock
-- on each of the fifteen tables for as long as the file runs, so nobody can
-- read or write the school while it does. That is already true in effect (it
-- rewrites 133,000 rows in one transaction) and this is a demo school. It also
-- needs table ownership, which the SQL editor has and a school never does. If
-- it cannot get it the file stops with that as the reason rather than
-- half-working, which is the state it was in before.
--
-- The re-enable is in the SAME transaction as the disable, so there is no
-- committed state in which the triggers are off: either the whole file commits
-- with them back on, or it rolls back and they were never off.
--
-- EVERY STATEMENT NOW SKIPS THE ROWS THAT ARE ALREADY RIGHT, so a second run
-- reports zero and means it. Six of them did not, and the count they printed
-- was "rows rewritten" while the line above it said "timestamps moved onto
-- their real dates", which is the same species of untruth this whole file
-- exists to correct. One of the six was worse than untidy:
-- admission_enquiries.updated_at was computed from admitted_at, which the same
-- statement overwrites, so a second run read what the first had written and
-- produced a different answer.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/08_the_clock.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

-- No jwt claim and no role change: this runs as the owner of the tables,
-- because created_at is not writable by a school.

do $clock$
declare
  v_school uuid;
  v_n bigint; v_tot bigint := 0;
  v_audit_mark bigint;
  v_t text;
  -- THE FIFTEEN TABLES THIS FILE RE-DATES, in one list rather than fifteen
  -- ALTER statements, so a table added to the body below and forgotten here
  -- cannot silently keep its triggers.
  v_tables text[] := array[
    'attendance_daily', 'staff_attendance', 'students', 'enrollments',
    'families', 'admission_enquiries', 'enquiry_contacts', 'invoices',
    'till_sessions', 'payments', 'expenses', 'assessments', 'mark_entries',
    'message_outbox', 'certificates'];
begin
  select id into v_school from public.schools
   where name = 'Chaudhary Puclix High School Ghauriii';
  if v_school is null then raise exception 'school not found'; end if;

  -- --- The row triggers off, for the duration -------------------------------
  -- `disable trigger user` and not `disable trigger all`: the ALL form takes
  -- the internally generated foreign-key triggers with it, which needs
  -- superuser and would let this file write a row pointing at nothing.
  begin
    foreach v_t in array v_tables loop
      execute format('alter table public.%I disable trigger user', v_t);
    end loop;
  exception when others then
    raise exception 'This file has to turn the row triggers off while it works, '
      'and it cannot: %. It needs to own the tables, which the Supabase SQL '
      'editor does and a signed-in school does not. Without it the BEFORE '
      'UPDATE trigger that stamps updated_at overwrites half of what this file '
      'sets, and the audit triggers write 120,000 rows that then have to be '
      'deleted again. Run this file in the SQL editor, or with psql as the '
      'table owner.', sqlerrm;
  end;

  -- A WATERMARK, TAKEN AFTER THE TRIGGERS ARE OFF AND BEFORE ANY UPDATE.
  --
  -- With the audit triggers disabled nothing below can add an audit row, so
  -- this is now a CHECK rather than a cleanup: if anything has appeared above
  -- the mark by the end, the disable did not do what it says and the rows are
  -- removed and the reader is told. It stays because the alternative is
  -- trusting a claim this file makes about itself.
  --
  -- An id watermark and not `created_at > now() - interval '10 minutes'`, which
  -- is what the first version deleted on: on a fresh build that is EVERY audit
  -- row in the database, because the whole seed had just run. It took the table
  -- from 299,593 rows to almost nothing and the census reported 155,417 total
  -- rows instead of 438,653. A cleanup broad enough to delete its own evidence
  -- is worse than no cleanup, and it was caught only because the total moved in
  -- the wrong direction.
  select coalesce(max(id), 0) into v_audit_mark from public.audit_log;
  raise notice 'audit watermark %', v_audit_mark;

  -- --- Attendance: the register was marked at 8:20, on the day itself --------
  update public.attendance_daily
     set created_at = attendance_date + time '08:20',
         updated_at = attendance_date + time '08:20'
   where school_id = v_school
     and (created_at::date <> attendance_date or updated_at::date <> attendance_date);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'attendance      %', v_n;

  update public.staff_attendance
     set created_at = attendance_date + time '07:50',
         checked_at = attendance_date + time '07:50'
   where school_id = v_school and created_at::date <> attendance_date;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'staff register  %', v_n;

  -- --- Students and enrollments: the day they were admitted -----------------
  update public.students
     set created_at = admission_date + time '10:15',
         updated_at = admission_date + time '10:15'
   where school_id = v_school
     and (created_at::date <> admission_date or updated_at::date <> admission_date);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'students        %', v_n;

  update public.enrollments e
     set created_at = greatest(st.admission_date, a.starts_on) + time '10:20',
         updated_at = greatest(st.admission_date, a.starts_on) + time '10:20'
    from public.students st, public.academic_sessions a
   where e.school_id = v_school and st.id = e.student_id and a.id = e.session_id
     and (e.created_at is distinct from greatest(st.admission_date, a.starts_on) + time '10:20'
       or e.updated_at is distinct from greatest(st.admission_date, a.starts_on) + time '10:20');
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'enrollments     %', v_n;

  update public.families f
     set created_at = q.first_admission + time '10:15',
         updated_at = q.first_admission + time '10:15'
    from (select st.family_id, min(st.admission_date) as first_admission
            from public.students st
           where st.school_id = v_school and st.family_id is not null
           group by st.family_id) q
   where f.id = q.family_id
     and (f.created_at is distinct from q.first_admission + time '10:15'
       or f.updated_at is distinct from q.first_admission + time '10:15');
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'families        %', v_n;

  -- --- Enquiries: three days before the admission they led to ---------------
  -- updated_at USED TO BE COMPUTED FROM admitted_at, which this same statement
  -- overwrites, so the file was not idempotent: a second run read the value the
  -- first run had written and produced a different answer. It comes off
  -- follow_up_on now, like the other two, which is the same day and does not
  -- depend on what this statement is in the middle of doing.
  update public.admission_enquiries e
     set created_at = q.c, updated_at = q.u, admitted_at = q.a
    from (
      select id,
             least(coalesce(follow_up_on, current_date) - 3, current_date)
               + time '11:40' as c,
             least(coalesce(follow_up_on, current_date), current_date)
               + time '12:00' as u,
             case when admitted_at is not null
                  then least(coalesce(follow_up_on, current_date), current_date)
                       + time '12:00'
                  else null end as a
        from public.admission_enquiries
       where school_id = v_school
    ) q
   where e.id = q.id
     and (e.created_at, e.updated_at, e.admitted_at)
         is distinct from (q.c, q.u, q.a);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'enquiries       %', v_n;

  update public.enquiry_contacts c
     set contacted_at = e.created_at + interval '1 day',
         created_at   = e.created_at + interval '1 day'
    from public.admission_enquiries e
   where c.school_id = v_school and e.id = c.enquiry_id
     and (c.contacted_at, c.created_at)
         is distinct from (e.created_at + interval '1 day',
                           e.created_at + interval '1 day');
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'enquiry contacts %', v_n;

  -- --- Invoices: issued at the start of the month they bill for -------------
  update public.invoices i
     set created_at = q.d, updated_at = q.d, issued_at = q.d
    from (
      select id, coalesce(period_month, issued_at::date, due_date - 9) + time '09:00' as d
        from public.invoices where school_id = v_school
    ) q
   where i.id = q.id
     and (i.created_at, i.updated_at, i.issued_at) is distinct from (q.d, q.d, q.d);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'invoices        %', v_n;

  -- invoice_lines carries no timestamp of its own, so there is nothing to move.

  -- --- Tills FIRST, because the payments are dated relative to them ---------
  -- fn__ensure_till opened a drawer the first time a cash payment was taken and
  -- nothing closed it for two years, so that one till row was stamped with the
  -- moment the seed ran. Dating the payments before the tills therefore dragged
  -- 2,236 historical receipts into "today", because the till holding them
  -- looked like today's. It is dated from the money inside it instead.
  update public.till_sessions t
     set opened_at = q.first_money,
         created_at = q.first_money,
         closed_at  = case when t.closed_at is not null
                           then q.first_money::date + time '14:10' else null end,
         approved_at = case when t.approved_at is not null
                            then q.first_money::date + time '16:30' else null end
    from (
      select t2.id,
             coalesce(min(i.period_month) + 1, t2.opened_at::date)::timestamptz
               + time '08:00' as first_money
        from public.till_sessions t2
        left join public.payments p  on p.till_session_id = t2.id
        left join public.payment_allocations al on al.payment_id = p.id
        left join public.invoices i on i.id = al.invoice_id
       where t2.school_id = v_school
       group by t2.id, t2.opened_at
    ) q
   where t.id = q.id and t.school_id = v_school
     and (t.opened_at, t.created_at, t.closed_at, t.approved_at)
         is distinct from (
           q.first_money, q.first_money,
           case when t.closed_at is not null
                then q.first_money::date + time '14:10' else null end,
           case when t.approved_at is not null
                then q.first_money::date + time '16:30' else null end);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'till sessions   %', v_n;

  -- --- Payments: THE ONE WITH NO BUSINESS DATE ------------------------------
  -- Spread over the first twelve working days of the month the payment is
  -- against, which is when a Pakistani school actually collects. The month
  -- comes from the invoice the payment was allocated to; a payment that
  -- allocated to nothing keeps the month of the receipt sequence around it.
  update public.payments p
     set created_at = q.day + time '09:30' + (q.slot * interval '7 minutes')
    from (
      select p2.id,
             -- SPREAD OVER THE DAYS THAT HAVE ACTUALLY HAPPENED, which is
             -- not the same as clamping to today.
             --
             -- Fees are collected in the first twelve working days of the
             -- month. For a month that is over, that is days 1 to 12. For the
             -- CURRENT month, only part of it exists: today is the 7th, so
             -- there are seven days to spread across, not twelve.
             --
             -- Two drafts got this wrong in opposite directions. The first
             -- ignored today and dated 149 payments up to a week into the
             -- future. The second wrapped the whole thing in least(...,
             -- current_date), which stopped that and then piled every offset
             -- from 7 to 12 onto today: the dashboard read Rs 366,942
             -- collected today against Rs 612,546 for the whole month, so 60%
             -- of September's fees arrived this morning. A modulo over the
             -- days available is the answer to both.
             (coalesce(min(i.period_month), date_trunc('month', current_date)::date)
              + ((p2.receipt_no %
                  (case when coalesce(min(i.period_month), date_trunc('month', current_date)::date)
                             = date_trunc('month', current_date)::date
                        then greatest(1, extract(day from current_date)::int)
                        else 12 end))::int
                 + case when coalesce(min(i.period_month), date_trunc('month', current_date)::date)
                             = date_trunc('month', current_date)::date
                        then 0 else 1 end)) as day,
             (p2.receipt_no % 40)::int as slot
        from public.payments p2
        left join public.payment_allocations al on al.payment_id = p2.id
        left join public.invoices i on i.id = al.invoice_id
       where p2.school_id = v_school
       group by p2.id, p2.receipt_no
    ) q
   where p.id = q.id and p.school_id = v_school
     and p.created_at is distinct from
         q.day + time '09:30' + (q.slot * interval '7 minutes');
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'payments        %  (no business date exists: see F1)', v_n;

  -- Today's counter payments stay today: the drawer that is open now has to
  -- hold money taken now, or the till report for today is empty on a day the
  -- simulation says was busy. Safe only because the tills were dated above:
  -- before that, the two-year-old auto-opened till also looked like today's.
  update public.payments p
     set created_at = now() - (interval '1 minute' * (((p.receipt_no % 180) + 5)::int))
    from public.till_sessions t
   where p.school_id = v_school and p.till_session_id = t.id
     and t.opened_at::date = current_date;
  get diagnostics v_n = row_count;
  raise notice 'todays counter  %', v_n;

  -- --- Expenses and other income already carry their real dates ------------
  update public.expenses set created_at = spent_on + time '15:00'
   where school_id = v_school and created_at::date <> spent_on;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'expenses        %', v_n;

  -- --- Tests and exam marks -------------------------------------------------
  update public.assessments set created_at = assessment_date + time '13:00'
   where school_id = v_school and created_at::date <> assessment_date;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'tests           %', v_n;

  update public.mark_entries m
     set created_at = coalesce(a.assessment_date, es.exam_date, m.created_at::date) + time '16:00',
         updated_at = coalesce(a.assessment_date, es.exam_date, m.created_at::date) + time '16:00'
    from public.mark_entries m2
    left join public.assessments a   on a.id  = m2.assessment_id
    left join public.exam_subjects es on es.id = m2.exam_subject_id
   where m.id = m2.id and m.school_id = v_school
     and (m.created_at, m.updated_at) is distinct from (
           coalesce(a.assessment_date, es.exam_date, m.created_at::date) + time '16:00',
           coalesce(a.assessment_date, es.exam_date, m.created_at::date) + time '16:00');
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'marks           %', v_n;

  -- --- The outbox: queued when the thing it is about happened --------------
  -- A message hangs off a payment, an enquiry or a student, and NOT an invoice:
  -- message_outbox has payment_id, enquiry_id, student_id and family_id, which
  -- is the right set. A receipt message is about the money, not the challan.
  update public.message_outbox m
     set created_at = coalesce(p.created_at, e.created_at, st.created_at, m.created_at),
         sent_at    = case when m2.status = 'sent'
                           then coalesce(p.created_at, e.created_at, st.created_at,
                                         m.created_at) + interval '40 minutes'
                           else null end
    from public.message_outbox m2
    left join public.payments p            on p.id  = m2.payment_id
    left join public.admission_enquiries e on e.id  = m2.enquiry_id
    left join public.students st           on st.id = m2.student_id
   where m.id = m2.id and m.school_id = v_school
     and (m.created_at, m.sent_at) is distinct from (
           coalesce(p.created_at, e.created_at, st.created_at, m.created_at),
           case when m2.status = 'sent'
                then coalesce(p.created_at, e.created_at, st.created_at,
                              m.created_at) + interval '40 minutes'
                else null end);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'outbox          %', v_n;

  -- --- Certificates ---------------------------------------------------------
  update public.certificates set created_at = coalesce(issued_on, created_at::date) + time '11:00'
   where school_id = v_school and created_at::date <> coalesce(issued_on, created_at::date);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'certificates    %', v_n;

  raise notice '--- % timestamps moved onto their real dates', v_tot;

  -- --- The audit log --------------------------------------------------------
  -- What survives is the school's real history, and it is re-dated to sit with
  -- the row it describes. The audit log is ordered by created_at on the screen
  -- that reads it, so a log whose every entry claims the same second is not a
  -- log.
  --
  -- JOINS AND NOT CORRELATED SUBQUERIES, and the difference is the difference
  -- between a minute and ten. The first version ran six `(select ... where
  -- id::text = a.entity_id)` lookups PER ROW over 215,000 audit rows;
  -- entity_id is text with no index, so none of them could use one and the
  -- planner had no choice but to scan per row. As one join per entity type it
  -- is a handful of hash joins over the set. Which is itself a small finding:
  -- nothing in the product joins the audit log back to the row it describes
  -- today, but "show me the history of this child" would, and it would be slow.
  update public.audit_log a set created_at = ad.created_at
    from public.attendance_daily ad
   where a.school_id = v_school and a.entity = 'attendance_daily'
     and a.action in ('INSERT', 'UPDATE', 'DELETE')
     and ad.id::text = a.entity_id
     and a.created_at is distinct from ad.created_at;
  get diagnostics v_n = row_count; v_tot := v_n;

  update public.audit_log a set created_at = m.created_at
    from public.mark_entries m
   where a.school_id = v_school and a.entity = 'mark_entries'
     and m.id::text = a.entity_id
     and a.created_at is distinct from m.created_at;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  update public.audit_log a set created_at = sa.created_at
    from public.staff_attendance sa
   where a.school_id = v_school and a.entity = 'staff_attendance'
     and sa.id::text = a.entity_id
     and a.created_at is distinct from sa.created_at;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  update public.audit_log a set created_at = p.created_at
    from public.payments p
   where a.school_id = v_school and a.entity = 'payments'
     and p.id::text = a.entity_id
     and a.created_at is distinct from p.created_at;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  update public.audit_log a set created_at = e.created_at
    from public.admission_enquiries e
   where a.school_id = v_school and a.entity = 'admission_enquiries'
     and e.id::text = a.entity_id
     and a.created_at is distinct from e.created_at;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  -- THE THREE AUDIT ACTIONS WHOSE entity_id IS NOT A ROW ID, and one of them
  -- is now the largest single thing in the log.
  --
  -- Closing or reopening a register is about a whole section-day, and there is
  -- no single attendance_daily row that IS the day, so the function records the
  -- DATE. Locking a test records the ASSESSMENT. None of them can be reached by
  -- the joins above, and after migration 0126 the finalise rows are 9,505 of
  -- the school's 18,053 audit rows: leaving them out means the majority of the
  -- audit log still claims two years of registers were closed this afternoon.
  -- The unlock statement was here already; the other two arrived with 0126 and
  -- would have been missed by anybody reading this file rather than counting.
  --
  -- Each is clamped to now(), so the last few days cannot land in the future.
  update public.audit_log a
     set created_at = least(a.entity_id::date + time '13:30', now())
   where a.school_id = v_school and a.action = 'ATTENDANCE_FINALIZE'
     and a.entity_id ~ '^\d{4}-\d{2}-\d{2}$'
     and a.created_at is distinct from least(a.entity_id::date + time '13:30', now());
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'registers closed:   % audit row(s) dated', v_n;

  -- The morning AFTER the day in question, because that is when the father
  -- turns up with the letter.
  update public.audit_log a
     set created_at = least((a.entity_id::date) + interval '1 day' + time '09:40', now())
   where a.school_id = v_school and a.action = 'ATTENDANCE_UNLOCK'
     and a.entity_id ~ '^\d{4}-\d{2}-\d{2}$'
     and a.created_at is distinct from
         least((a.entity_id::date) + interval '1 day' + time '09:40', now());
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'registers reopened: % audit row(s) dated', v_n;

  -- The evening the marks were entered.
  update public.audit_log a
     set created_at = least(s.assessment_date + time '17:00', now())
    from public.assessments s
   where a.school_id = v_school and a.action = 'ASSESSMENT_LOCK'
     and s.id::text = a.entity_id
     and a.created_at is distinct from least(s.assessment_date + time '17:00', now());
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'tests locked:       % audit row(s) dated', v_n;

  raise notice 'audit rows re-dated: %', v_tot;

  -- --- Did the disable hold? ------------------------------------------------
  -- The claim this file makes about itself, checked rather than asserted. With
  -- the triggers off nothing above can have written an audit row.
  select count(*) into v_n from public.audit_log where id > v_audit_mark;
  if v_n > 0 then
    delete from public.audit_log where id > v_audit_mark;
    raise notice 'the row triggers were NOT off after all: % audit row(s) '
      'describing corrections that never happened were written by this file '
      'and have been removed. The updated_at columns it set are probably wrong '
      'too, because the same disable covers the trigger that overwrites them.',
      v_n;
  end if;

  -- --- The row triggers back on ---------------------------------------------
  -- Same transaction as the disable, so there is no committed state in which
  -- they are off.
  foreach v_t in array v_tables loop
    execute format('alter table public.%I enable trigger user', v_t);
  end loop;

  raise notice 'audit_log now holds % rows',
    (select count(*) from public.audit_log where school_id = v_school);
end
$clock$;

-- --- And prove the triggers are back --------------------------------------
-- Outside the block that turned them off, because a check inside the thing it
-- is checking can be skipped by the same mistake that broke it.
do $back$
declare v_off text;
begin
  select string_agg(distinct c.relname, ', ' order by c.relname) into v_off
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal and t.tgenabled = 'D'
     and c.relnamespace = 'public'::regnamespace;
  if v_off is not null then
    raise exception 'These tables still have their row triggers disabled: %. '
      'Nothing after this point would be audited and nothing would keep the '
      'student counts up to date. This file turns them off while it re-dates '
      'and back on before it finishes, so reaching here means it did not '
      'finish.', v_off;
  end if;
  raise notice 'row triggers are back on';
end
$back$;

commit;
