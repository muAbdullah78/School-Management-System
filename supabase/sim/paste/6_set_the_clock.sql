-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE 6 OF 7: set the clock
--
-- Moves 133,000 timestamps onto their real dates, so two years of school life stops claiming to have been entered this afternoon. Under a minute.
--
-- HOW TO RUN THE SET. Paste each file into the Supabase SQL editor and press
-- Run, IN ORDER, waiting for each to finish before starting the next. Exactly
-- like the numbered migration bundles. Each file is one transaction, so if one
-- fails it writes nothing and can be fixed and re-run on its own.
--
-- WHAT THE SET DOES. It finds the school named below and fills it with February
-- 2024 to today: about 220 children on the roll, 589 school days of register,
-- three year-end rollovers, 6,000 challans, 4,600 payments, 663 class tests,
-- 5 exam terms, 715 result cards, a cash drawer counted daily, and today half
-- marked the way a real register is at eleven in the morning. About 370,000
-- rows.
--
-- Every row arrives through the application's OWN functions, with a real
-- signed-in owner's session and Row Level Security on. Raw inserts would fill
-- the tables faster and prove nothing, because it is those functions that keep
-- the ledger balanced and the receipt numbers gapless.
--
-- BEFORE YOU START
--
--   1. IT IS NOT REVERSIBLE BY THESE FILES. To undo it, sign in as the owner
--      and clear the school's data from Settings, which calls
--      fn_reset_school_data. That works only while the school is still on its
--      free trial. Once the trial has ended there is no undo.
--   2. Only run it against a school you are willing to fill with invented
--      data. It writes nothing outside the one tenant named below.
--   3. It creates NO logins. See the note at the end of file 7.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- THE ONE LINE TO EDIT, and it must be the same in every file of the set: the
-- exact name of the school to fill. It must match
-- Settings -> School Profile -> School name character for character. If it
-- does not, the file stops with "No owner session." and writes nothing.
-- ---------------------------------------------------------------------------
set local "sim.school" = 'Chaudhary Puclix High School Ghauriii';

-- Some of these files take minutes, which is longer than the editor's default
-- limit. Only a superuser can lift it, which the SQL editor is.
set local statement_timeout = 0;

-- ---------------------------------------------------------------------------
-- IS THIS DATABASE NEW ENOUGH? Asked here, at the top, rather than found out
-- thirteen minutes into a file.
--
-- The register section reopens a finalised day and corrects it, which is what
-- the corrections report exists to show and which no database could do before
-- migration 0121. On a database that is behind, that call fails with "function
-- does not exist" AFTER the file has done all its work, and because each file
-- is one transaction the whole lot is rolled back with nothing to show for it.
-- ---------------------------------------------------------------------------
do $prereq$
begin
  if to_regprocedure('public.fn_unlock_attendance(uuid,uuid,uuid,date,text)') is null then
    raise exception 'This project is behind the application. Run '
      'supabase/verify.sql, paste every bundle it names in a FAIL row (the '
      'first of them is 27_a_finalised_register_can_be_reopened.sql), then '
      'start this set again.';
  end if;
end $prereq$;



-- ------------------------------------------------------------------------
-- 08_the_clock.sql
-- ------------------------------------------------------------------------
reset role;
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
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/08_the_clock.sql
-- =============================================================================



-- No jwt claim and no role change: this runs as the owner of the tables,
-- because created_at is not writable by a school.

do $clock$
declare
  v_school uuid;
  v_n bigint; v_tot bigint := 0;
  v_audit_mark bigint;
begin
  select id into v_school from public.schools
   where name = current_setting('sim.school');
  if v_school is null then raise exception 'school not found'; end if;

  -- A WATERMARK, TAKEN BEFORE ANY UPDATE FIRES A TRIGGER.
  --
  -- Every re-dating below is an UPDATE, and the audit triggers fire on updates,
  -- so this file writes an audit row for each of the 134,000 timestamps it
  -- moves. Those rows describe corrections that never happened and have to go.
  --
  -- The first version deleted `where created_at > now() - interval '10 minutes'`
  -- and on a fresh build that is EVERY audit row in the database, because the
  -- whole seed had just run: it took the table from 299,593 rows to almost
  -- nothing and the census reported 155,417 total rows instead of 438,653. A
  -- cleanup broad enough to delete its own evidence is worse than no cleanup,
  -- and it was caught only because the total moved in the wrong direction.
  --
  -- An id watermark is exact: audit_log.id is a bigint sequence, so anything
  -- above this mark was written by this file and nothing else.
  select coalesce(max(id), 0) into v_audit_mark from public.audit_log;
  raise notice 'audit watermark %', v_audit_mark;

  -- --- Attendance: the register was marked at 8:20, on the day itself --------
  update public.attendance_daily
     set created_at = attendance_date + time '08:20',
         updated_at = attendance_date + time '08:20'
   where school_id = v_school and created_at::date <> attendance_date;
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
   where school_id = v_school and created_at::date <> admission_date;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'students        %', v_n;

  update public.enrollments e
     set created_at = greatest(st.admission_date, a.starts_on) + time '10:20',
         updated_at = greatest(st.admission_date, a.starts_on) + time '10:20'
    from public.students st, public.academic_sessions a
   where e.school_id = v_school and st.id = e.student_id and a.id = e.session_id;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'enrollments     %', v_n;

  update public.families f
     set created_at = q.first_admission + time '10:15',
         updated_at = q.first_admission + time '10:15'
    from (select st.family_id, min(st.admission_date) as first_admission
            from public.students st
           where st.school_id = v_school and st.family_id is not null
           group by st.family_id) q
   where f.id = q.family_id;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'families        %', v_n;

  -- --- Enquiries: three days before the admission they led to ---------------
  update public.admission_enquiries
     set created_at = least(coalesce(follow_up_on, current_date) - 3, current_date) + time '11:40',
         updated_at = least(coalesce(admitted_at::date, follow_up_on, current_date),
                            current_date) + time '12:00',
         admitted_at = case when admitted_at is not null
                            then least(coalesce(follow_up_on, current_date), current_date)
                                 + time '12:00'
                            else null end
   where school_id = v_school;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'enquiries       %', v_n;

  update public.enquiry_contacts c
     set contacted_at = e.created_at + interval '1 day',
         created_at   = e.created_at + interval '1 day'
    from public.admission_enquiries e
   where c.school_id = v_school and e.id = c.enquiry_id;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'enquiry contacts %', v_n;

  -- --- Invoices: issued at the start of the month they bill for -------------
  update public.invoices
     set created_at = coalesce(period_month, issued_at::date, due_date - 9) + time '09:00',
         updated_at = coalesce(period_month, issued_at::date, due_date - 9) + time '09:00',
         issued_at  = coalesce(period_month, issued_at::date, due_date - 9) + time '09:00'
   where school_id = v_school;
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
   where t.id = q.id and t.school_id = v_school;
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
   where p.id = q.id and p.school_id = v_school;
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
   where m.id = m2.id and m.school_id = v_school;
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
   where m.id = m2.id and m.school_id = v_school;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'outbox          %', v_n;

  -- --- Certificates ---------------------------------------------------------
  update public.certificates set created_at = coalesce(issued_on, created_at::date) + time '11:00'
   where school_id = v_school and created_at::date <> coalesce(issued_on, created_at::date);
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'certificates    %', v_n;

  raise notice '--- % timestamps moved onto their real dates', v_tot;

  -- --- The audit log, last --------------------------------------------------
  -- Only what this file wrote, identified by the watermark above. Deleting
  -- audit rows is something no school can do and nothing in the product
  -- offers; it is done here because these particular rows describe corrections
  -- that never happened.
  delete from public.audit_log where id > v_audit_mark;
  get diagnostics v_n = row_count;
  raise notice 'audit rows this file created, removed: %', v_n;

  -- What survives is the school's real history, and it is re-dated to sit with
  -- the row it describes. The audit log is ordered by created_at on the screen
  -- that reads it, so a log whose every entry claims the same second is not a
  -- log.
  --
  -- SIX JOINS AND NOT SIX CORRELATED SUBQUERIES, and the difference is the
  -- difference between a minute and ten. The first version ran six `(select ...
  -- where id::text = a.entity_id)` lookups PER ROW over 215,000 audit rows;
  -- entity_id is text with no index, so none of them could use one and the
  -- planner had no choice but to scan per row. As one join per entity type it
  -- is six hash joins over the set. Which is itself a small finding: nothing in
  -- the product joins the audit log back to the row it describes today, but
  -- "show me the history of this child" would, and it would be slow.
  -- The five entities that account for 213,000 of the 215,853 rows, taken from
  -- the table rather than guessed: attendance_daily 180,091, mark_entries
  -- 16,195, staff_attendance 11,656, payments 4,800, admission_enquiries 1,314.
  -- The first draft re-dated `invoices` and `enrollments`, which the audit
  -- trigger does not cover at all, and missed the register, which is 83% of it.
  update public.audit_log a set created_at = ad.created_at
    from public.attendance_daily ad
   where a.school_id = v_school and a.entity = 'attendance_daily'
     and ad.id::text = a.entity_id;
  get diagnostics v_n = row_count; v_tot := v_n;

  update public.audit_log a set created_at = m.created_at
    from public.mark_entries m
   where a.school_id = v_school and a.entity = 'mark_entries'
     and m.id::text = a.entity_id;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  update public.audit_log a set created_at = sa.created_at
    from public.staff_attendance sa
   where a.school_id = v_school and a.entity = 'staff_attendance'
     and sa.id::text = a.entity_id;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  update public.audit_log a set created_at = p.created_at
    from public.payments p
   where a.school_id = v_school and a.entity = 'payments'
     and p.id::text = a.entity_id;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  update public.audit_log a set created_at = e.created_at
    from public.admission_enquiries e
   where a.school_id = v_school and a.entity = 'admission_enquiries'
     and e.id::text = a.entity_id;
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;

  -- THE ONE AUDIT ACTION WHOSE entity_id IS A DATE, not a row id. Reopening a
  -- finalised register (0121) is about a whole section-day, and there is no
  -- single attendance_daily row that IS the day, so the function records the
  -- date. Which means the join above cannot reach these rows and they would
  -- keep claiming that a 2024 register was reopened this afternoon.
  --
  -- Dated to the morning after the day in question, because that is when the
  -- father turns up with the letter. Clamped to now(), so the last few days
  -- cannot land in the future.
  update public.audit_log a
     set created_at = least((a.entity_id::date) + interval '1 day' + time '09:40', now())
   where a.school_id = v_school and a.action = 'ATTENDANCE_UNLOCK'
     and a.id <= v_audit_mark
     and a.entity_id ~ '^\d{4}-\d{2}-\d{2}$';
  get diagnostics v_n = row_count; v_tot := v_tot + v_n;
  raise notice 'registers reopened: % audit row(s) dated', v_n;

  raise notice 'audit rows re-dated: %', v_tot;

  raise notice 'audit_log now holds % rows',
    (select count(*) from public.audit_log where school_id = v_school);
end
$clock$;

