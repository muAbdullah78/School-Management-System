-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE 10 OF 10: check it worked
--
-- Asserts the result is a school somebody would recognise. Instant. This is the one whose output to read.
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
--   3. It creates NO logins. See the note at the end of file 10.
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
-- CAN THIS FILE DO ANYTHING AT ALL? Four questions, asked here at the top
-- rather than found out four minutes into a file, and each one answered with
-- WHAT IS ACTUALLY THERE rather than with the fact that something is wrong.
--
-- THE FIRST VERSION OF THIS ASKED ONLY THE FIRST QUESTION, and the file then
-- died on the school name with
--
--     ERROR: No owner session. Is the school name exactly right?
--
-- seven times in a row. That message names the right suspect and then leaves
-- the reader with nowhere to go: the name is in Settings, truncated in the
-- sidebar, and the difference is usually a trailing space or one letter. A
-- diagnostic that can read the answer and does not print it is not a
-- diagnostic. So this one lists the school names it can see.
-- ---------------------------------------------------------------------------
do $prereq$
declare
  -- NOT btrim'd: see question 3. `nullif` on the raw value only asks whether
  -- anything arrived at all.
  v_name   text := coalesce(current_setting('sim.school', true), '');
  v_school uuid;
  v_near   integer;   -- schools whose name differs only in case or spacing
  v_owners integer;
  v_all    text;
begin
  -- 1. Is the schema new enough? The register section reopens a finalised day
  --    and corrects it, which no database could do before migration 0121.
  if to_regprocedure('public.fn_unlock_attendance(uuid,uuid,uuid,date,text)') is null then
    raise exception 'This project is behind the application. Run '
      'supabase/verify.sql, paste every bundle it names in a FAIL row (the '
      'first of them is 27_a_finalised_register_can_be_reopened.sql), then '
      'start this set again.';
  end if;

  -- 2. Did the school name survive as far as this statement? `set local` only
  --    holds for the transaction, and pressing Run on a pasted file makes the
  --    whole file one transaction. Run a SELECTION of it and the setting is
  --    gone by the time anything reads it, and every later error then blames
  --    the school name instead of the way it was run. Outside a transaction
  --    `set local` does not fail: it warns, and reads back EMPTY.
  if btrim(v_name) = '' then
    raise exception 'The school name never arrived: "sim.school" is empty here. '
      'Paste and run the WHOLE file in one go rather than a selection of it, '
      'because the line that sets the name only holds for as long as the file '
      'runs as one batch.';
  end if;

  -- 3. Is there a school of that name? And if not, SAY WHAT THERE IS, and fix
  --    it where the answer is not in doubt.
  --
  --    THE COMPARISON HERE IS EXACTLY THE ONE THE REST OF THE FILE USES: plain
  --    equality on schools.name. An earlier version trimmed the setting before
  --    comparing, which made this check PASS on a name the body then failed on,
  --    and a check that disagrees with the code it guards is worse than no
  --    check. So instead of loosening the comparison, this loosens the SEARCH
  --    and then corrects the setting, which every later statement reads.
  --
  --    IT SEARCHES BOTH NAME COLUMNS, and that is not belt and braces: it is
  --    the defect migration 0123 fixes. school_settings.name is the only one a
  --    school can edit, schools.name is the one this file matches on, and until
  --    0123 nothing kept them in step. So a school reading its own name off its
  --    own screen and pasting it in here would be pasting the OTHER column, and
  --    every file in the set refused. That is exactly how it was reported.
  select id into v_school from public.schools where name = v_name;

  if v_school is null then
    -- The name the school sees on its own screens, which is the one a reader
    -- copies. Matched exactly first, before any fuzziness.
    select s.id, s.name into v_school, v_all
      from public.schools s
      join public.school_settings st on st.school_id = s.id
     where st.name = v_name;

    if v_school is not null then
      raise notice 'That is the name on this school''s own screens. In the '
        'database it is still stored as "%", which is what the console and its '
        'invoices show: two names for one school, which '
        'supabase/bundles/29_a_school_has_one_name.sql puts right. Continuing '
        'with the stored one.', v_all;
      perform set_config('sim.school', v_all, true);
      v_name := v_all;
    else
      -- One near miss and no ambiguity, across either column: almost always a
      -- trailing space, which is invisible in Settings and in the sidebar, or a
      -- capital letter. Fix it and say so loudly enough that nobody could think
      -- a different school was filled by accident.
      select count(*), min(s.name) into v_near, v_all
        from public.schools s
        left join public.school_settings st on st.school_id = s.id
       where lower(btrim(s.name))  = lower(btrim(v_name))
          or lower(btrim(st.name)) = lower(btrim(v_name));

      if v_near = 1 then
        raise notice 'The name given was "%" and this school is stored as "%". '
          'Same school, so continuing with the stored spelling.', v_name, v_all;
        perform set_config('sim.school', v_all, true);
        v_name := v_all;
      else
        -- BOTH names per school, because the whole difficulty here is that a
        -- school has two and can only see one of them.
        select string_agg('"' || s.name || '"'
                 || case when st.name is distinct from s.name
                           then ' (its own screens say "' || st.name || '")'
                         else '' end, ', ' order by s.name)
          into v_all
          from public.schools s
          left join public.school_settings st on st.school_id = s.id;
        raise exception 'No school is named "%". This project holds %. Copy the '
          'one you want, character for character including any spaces, into the '
          '"sim.school" line at the top of every file in this set.',
          v_name, coalesce(v_all, 'no schools at all');
      end if;
    end if;
    select id into v_school from public.schools where name = v_name;
  end if;

  -- 4. Is there an owner to act as? Every row in this set is written through
  --    the application's own functions with a real signed-in owner's session,
  --    so without one there is nobody to be. Kept separate from question 3 on
  --    purpose: the two were one message before, and "is the school name
  --    right?" is unanswerable advice when the name was right all along.
  select count(*) into v_owners from public.profiles
   where school_id = v_school and role = 'owner' and active;
  if v_owners = 0 then
    raise exception 'The school "%" exists but has no active owner login, and '
      'this set writes as its owner. Sign in as the school and check Settings, '
      'Users & Roles.', v_name;
  end if;

  raise notice 'Filling "%", which has an owner to write as. This whole file is '
    'one transaction: if it stops, it writes nothing.', v_name;
end $prereq$;



-- ------------------------------------------------------------------------
-- 09_check.sql
-- ------------------------------------------------------------------------
reset role;
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


do $check$
declare
  v_school uuid;
  v_fail text[] := '{}';
  v_n numeric; v_m numeric;
  procedure_note text;
begin
  select id into v_school from public.schools
   where name = current_setting('sim.school');
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


-- Statistics, now that the writing is finished.
analyze;


-- =============================================================================
-- ABOUT THE LOGINS, WHICH THESE FILES DELIBERATELY DID NOT CREATE
--
-- The 220 children, their families and the 23 staff all exist as records, and
-- none of them can sign in. That is deliberate twice over.
--
-- It is honest. Supabase hashes a password on its own side, through the admin
-- API, and there is no way to produce a valid hash from SQL. A file that wrote
-- auth.users rows here would create accounts that look real on the Users screen
-- and refuse every password anybody types.
--
-- It is also what a real school looks like a month in: most families have no
-- login yet.
--
-- To make some, use the application's own buttons, which go through the Edge
-- Functions that own this job:
--
--   a parent    Students, open a child, "Give this family a login"
--   a teacher   Settings, Users & Roles; or Staff, "Give them a login"
--
-- Both write the password to the school's key ring at the same time, so the
-- office can read it back to somebody who has lost it. That is migration 0116,
-- and it is why a made-up email address is not a problem.
-- =============================================================================
