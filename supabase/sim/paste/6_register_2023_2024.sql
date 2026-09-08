-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE 6 OF 13: register 2023 2024
--
-- February and March 2024 of the register, section by section, day by day, finalised. Seconds.
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
--   3. It creates NO logins. See the note at the end of file 13.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- THE ONE LINE TO EDIT, and it must be the same in every file of the set: the
-- exact name of the school to fill. It must match
-- Settings -> School Profile -> School name character for character. If it
-- does not, the file stops with "No owner session." and writes nothing.
-- ---------------------------------------------------------------------------
set local "sim.school" = 'Chaudhary Puclix High School Ghauriii';

-- WHICH ACADEMIC YEAR THIS FILE IS. Do not change it, and run the four year
-- files IN ORDER: each one ends by rolling the whole school forward into the
-- next, and there is nothing for the next file to bill until it has.
set local "sim.year" = '2023-2024';

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
-- 05_daily_operations.sql
-- ------------------------------------------------------------------------
reset role;
-- =============================================================================
-- SIMULATION, PART 4: every school day from February 2024 to today.
--
-- THE CALENDAR IS THE POINT. A seed that marks attendance on all 365 days of
-- the year produces a school that sat exams on Eid and a percentage that no
-- report can reconcile. So this builds a real Islamabad private-school calendar
-- first: closed on Sundays, from 1 June to 14 August, over the winter break,
-- on the national holidays, and for both Eids in each of the three years.
-- Everything downstream counts against that calendar, which is what makes
-- fn_attendance_summary's percentages mean anything.
--
-- TODAY IS DELIBERATELY LEFT HALF DONE. Attendance for today is marked but NOT
-- finalised, and the staff check-ins for today stop at whoever had arrived by
-- now. A demo where today is closed and reconciled is a demo of yesterday; the
-- state a school is actually in when somebody logs in at 11am is one with
-- today's register open.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/sim/04_daily_operations.sql
-- =============================================================================



select set_config('request.jwt.claims',
  jsonb_build_object('sub', p.id::text, 'role','authenticated')::text, true)
from public.profiles p join public.schools s on s.id = p.school_id
where s.name = current_setting('sim.school')
  and p.role = 'owner' and p.active limit 1;
set local role authenticated;

-- --- The school calendar ------------------------------------------------------
drop table if exists sim_day;
create temp table sim_day(d date primary key) on commit drop;
insert into sim_day(d)
select g::date
  from generate_series(date '2024-02-01', current_date, interval '1 day') g
 where extract(dow from g) <> 0                             -- Sunday
   and not (extract(month from g) = 6)                      -- summer, June
   and not (extract(month from g) = 7)                      -- summer, July
   and not (extract(month from g) = 8 and extract(day from g) <= 14)
   and not (extract(month from g) = 12 and extract(day from g) >= 24)
   and not (extract(month from g) = 1  and extract(day from g) = 1)
   and g::date not in (
     -- Fixed national holidays.
     '2024-03-23','2024-05-01','2024-11-09','2024-12-25',
     '2025-03-23','2025-05-01','2025-11-09','2025-12-25',
     '2026-03-23','2026-05-01',
     -- Eid al-Fitr and Eid al-Adha, three days each, actual dates.
     '2024-04-10','2024-04-11','2024-04-12',
     '2024-09-16',
     '2025-03-31','2025-04-01','2025-04-02',
     '2025-09-05',
     '2026-03-20','2026-03-21','2026-03-23'
   );

do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_marks jsonb; v_day date; v_n int := 0; v_rows bigint;
begin
  if v_school is null then raise exception 'No owner session.'; end if;
  raise notice 'school days from 2024-02-01 to today: %', (select count(*) from sim_day);

  -- --- 1. Student attendance, section by section, day by day ----------------
  -- Only enrollments that were ACTIVE on the day in question, which is what
  -- makes the roll grow through the two years instead of every child appearing
  -- on day one. A child admitted in 2025 has no attendance in 2024, and a query
  -- that assumes otherwise has an inflated denominator.
  for r in
    select s.id as section_id, s.class_id, c.level_order,
           a.id as session_id, a.starts_on, a.ends_on
      from public.sections s
      join public.classes c on c.id = s.class_id
      cross join public.academic_sessions a
     where c.school_id = v_school and a.school_id = v_school
       and a.ends_on >= date '2024-02-01' and a.starts_on <= current_date
       -- ONE ACADEMIC YEAR AT A TIME WHEN ASKED, for the same reason
       -- 04_the_years.sql is: the Supabase SQL editor is reached over an HTTP
       -- API whose timeout `set statement_timeout = 0` cannot touch, and this
       -- file whole took 84 seconds on a fast local disk, which is the longest
       -- of the set and the next one certain to fail on a shared instance.
       and coalesce(nullif(btrim(current_setting('sim.year', true)), ''), a.name) = a.name
     order by a.starts_on, c.level_order, s.sort_order
  loop
    -- ALREADY MARKED? Skipped, so re-pasting a year file after a timeout costs
    -- seconds rather than redoing the register. fn_mark_attendance is an upsert
    -- and would not corrupt anything, but it would refuse every finalised day
    -- and then spend a minute discovering that.
    for v_day in
      select d from sim_day
       where d between greatest(r.starts_on, date '2024-02-01') and least(r.ends_on, current_date)
         and not exists (
           select 1 from public.attendance_daily ad
             join public.enrollments e on e.id = ad.enrollment_id
            where ad.school_id = v_school
              and ad.attendance_date = sim_day.d
              and e.section_id = r.section_id
              and e.session_id = r.session_id)
    loop
      select jsonb_agg(jsonb_build_object('enrollment_id', q.id, 'status', q.st))
        into v_marks
        from (
          select e.id,
                 -- ~93% present, and the absences are not uniform: Saturdays
                 -- and the days either side of a holiday are worse, which is
                 -- true of every school and is what makes a monthly percentage
                 -- move at all.
                 case
                   when (hashtextextended(e.id::text || v_day::text, 42) % 100 + 100) % 100
                        < (case when extract(dow from v_day) = 6 then 84 else 93 end)
                     then 'present'
                   when (hashtextextended(e.id::text || v_day::text, 7) % 100 + 100) % 100 < 55
                     then 'absent'
                   when (hashtextextended(e.id::text || v_day::text, 7) % 100 + 100) % 100 < 80
                     then 'late'
                   when (hashtextextended(e.id::text || v_day::text, 7) % 100 + 100) % 100 < 93
                     then 'leave'
                   else 'half_day'
                 end as st
            from public.enrollments e
            join public.students stu on stu.id = e.student_id
           where e.section_id = r.section_id
             and e.session_id = r.session_id
             -- admission_date, NOT created_at. Every enrollment row in this
             -- simulation was written in the same second, so a created_at
             -- filter excluded every day before today and produced 45 rows of
             -- attendance for two years. The child's admission date is the
             -- only thing that says when they were actually on the roll.
             and stu.admission_date <= v_day
             and (stu.left_on is null or stu.left_on > v_day)
        ) q;

      if v_marks is not null then
        perform public.fn_mark_attendance(v_day, v_marks, null);
        v_n := v_n + 1;
        -- Finalised for every day EXCEPT today, so today's register is open
        -- the way a real one is at 11 in the morning.
        if v_day < current_date then
          perform public.fn_finalize_attendance(r.session_id, r.class_id, r.section_id, v_day);
        end if;
      end if;
    end loop;
  end loop;

  select count(*) into v_rows from public.attendance_daily where school_id = v_school;
  raise notice 'student attendance: % section-days, % rows', v_n, v_rows;
end
$sim$;

-- --- 2. Staff attendance ------------------------------------------------------
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_day date; v_n bigint := 0; v_status public.attendance_status;
begin
  -- ONCE, NOT ONCE PER YEAR. Sections 2 to 4 are not scoped to an academic
  -- session: the staff register is per member of staff per day, the gate codes
  -- are per year but cheap and created by name, and the corrections pass needs
  -- every day of the register already finalised before it can reopen any of
  -- them. Section 1 above is emitted once per year by
  -- scripts/build-sim-bundle.py, so these run in the LAST of those files only.
  if coalesce(nullif(btrim(current_setting('sim.year', true)), ''),
              (select a.name from public.academic_sessions a
                where a.school_id = v_school and a.starts_on <= current_date
                order by a.starts_on desc limit 1))
     is distinct from
     (select a.name from public.academic_sessions a
       where a.school_id = v_school and a.starts_on <= current_date
       order by a.starts_on desc limit 1) then
    raise notice 'skipped here: this part runs once, with the last year';
    return;
  end if;

  for r in select id, joined_on, left_on from public.staff where school_id = v_school loop
    for v_day in
      select d from sim_day
       where d >= greatest(r.joined_on, date '2024-02-01')
         and (r.left_on is null or d <= r.left_on)
    loop
      v_status := case
        when (hashtextextended(r.id::text || v_day::text, 3) % 100 + 100) % 100 < 90 then 'present'
        when (hashtextextended(r.id::text || v_day::text, 3) % 100 + 100) % 100 < 95 then 'late'
        when (hashtextextended(r.id::text || v_day::text, 3) % 100 + 100) % 100 < 98 then 'leave'
        else 'absent' end;
      -- Today stops at whoever had arrived: a staff register that is complete
      -- before the day is over is not a state a school is ever in.
      if v_day = current_date and (hashtextextended(r.id::text, 9) % 10 + 10) % 10 < 3 then
        continue;
      end if;
      perform public.fn_set_staff_attendance(r.id, v_day, v_status, null);
      v_n := v_n + 1;
    end loop;
  end loop;
  raise notice 'staff attendance: % rows', v_n;
end
$sim$;

-- --- 3. The check-in kiosk ----------------------------------------------------
-- A rotating code per session year plus a fixed one for the current year, and a
-- scatter of failed attempts. staff_checkin_attempts exists to answer "somebody
-- says the code did not work", and with no failures in it that screen has
-- never been looked at with anything on it.
do $sim$
declare
  v_school uuid := public.current_school_id();
  v_code jsonb;
begin
  -- ONCE, NOT ONCE PER YEAR. Sections 2 to 4 are not scoped to an academic
  -- session: the staff register is per member of staff per day, the gate codes
  -- are per year but cheap and created by name, and the corrections pass needs
  -- every day of the register already finalised before it can reopen any of
  -- them. Section 1 above is emitted once per year by
  -- scripts/build-sim-bundle.py, so these run in the LAST of those files only.
  if coalesce(nullif(btrim(current_setting('sim.year', true)), ''),
              (select a.name from public.academic_sessions a
                where a.school_id = v_school and a.starts_on <= current_date
                order by a.starts_on desc limit 1))
     is distinct from
     (select a.name from public.academic_sessions a
       where a.school_id = v_school and a.starts_on <= current_date
       order by a.starts_on desc limit 1) then
    raise notice 'skipped here: this part runs once, with the last year';
    return;
  end if;

  v_code := public.fn_generate_checkin_code('Gate board 2024-2025', date '2024-04-01', date '2025-03-31', true, false);
  v_code := public.fn_generate_checkin_code('Gate board 2025-2026', date '2025-04-01', date '2026-03-31', true, false);
  v_code := public.fn_generate_checkin_code('Gate board 2026-2027', date '2026-04-01', date '2027-03-31', true, true);
  raise notice 'check-in codes: %', (select count(*) from public.staff_checkin_codes where school_id = v_school);

  -- The failed attempts are written further down, after the role is reset:
  -- staff_checkin_attempts refuses an insert from `authenticated`, which is
  -- right. Only fn_staff_check_in writes that table, so a school cannot
  -- fabricate a gate log, and this simulation should not pretend it can.
end
$sim$;

-- --- 4. The register put right -------------------------------------------------
-- WHY THIS SECTION EXISTS AT ALL, and it is finding F21.
--
-- Section 1 finalises every past day, which is what a real school does. That
-- also made `corrected_from` zero across the whole two years, so
-- fn_attendance_corrections returned nothing and the corrections report on the
-- History screen had never been seen with a row in it. Chasing that down is how
-- the bug in 0121 was found: fn_mark_attendance skips a locked row, and until
-- 0121 NOTHING in the schema could clear the lock. The owner could not fix a
-- wrong mark at any privilege level, and the attendance percentage on the
-- result card is computed from this table.
--
-- So the school now does what a school does: a father turns up with the leave
-- application, the office reopens that day, corrects the one child and closes
-- it again. Every step through the application's own functions, which is what
-- writes corrected_from, correction_reason and the ATTENDANCE_UNLOCK audit row.
do $sim$
declare
  v_school uuid := public.current_school_id();
  r record; v_n int := 0; v_rows bigint; v_reason text; v_new text;
  -- Five real ones, cycled. A school's reasons are not "test".
  v_reasons text[] := array[
    'father produced the leave application the next morning',
    'medical certificate produced, the child was marked absent in error',
    'the child was in the exam hall; the register was marked before assembly',
    'on school duty at the district sports, so not absent',
    'marked against the wrong roll number'
  ];
begin
  if v_school is null then raise exception 'No owner session.'; end if;

  -- ONCE, NOT ONCE PER YEAR. Sections 2 to 4 are not scoped to an academic
  -- session: the staff register is per member of staff per day, the gate codes
  -- are per year but cheap and created by name, and the corrections pass needs
  -- every day of the register already finalised before it can reopen any of
  -- them. Section 1 above is emitted once per year by
  -- scripts/build-sim-bundle.py, so these run in the LAST of those files only.
  if coalesce(nullif(btrim(current_setting('sim.year', true)), ''),
              (select a.name from public.academic_sessions a
                where a.school_id = v_school and a.starts_on <= current_date
                order by a.starts_on desc limit 1))
     is distinct from
     (select a.name from public.academic_sessions a
       where a.school_id = v_school and a.starts_on <= current_date
       order by a.starts_on desc limit 1) then
    raise notice 'skipped here: this part runs once, with the last year';
    return;
  end if;

  -- EVERY Nth CANDIDATE, not a hash, and the difference matters. A hash filter
  -- (`% 400 = 0` over the roughly 5,000 locked absences) averaged twelve days
  -- and produced eleven on one build and twenty on another, because the ids it
  -- hashes are new every time. 09_check.sql then asserts a floor, and an
  -- assertion whose subject varies by luck fails a build eventually and reads
  -- as a real defect when it does. Taking every Nth row of the ordered
  -- candidate set gives exactly twenty, spread across both years.
  --
  -- Only absences and lates: "present" corrected to something else is not the
  -- story a school tells.
  for r in
    select q.session_id, q.class_id, q.section_id, q.d, q.enrollment_id, q.was
      from (
        select e.session_id, e.class_id, e.section_id, ad.attendance_date as d,
               ad.enrollment_id, ad.status::text as was,
               row_number() over (order by ad.attendance_date, ad.enrollment_id) as rn,
               count(*) over () as total
          from public.attendance_daily ad
          join public.enrollments e on e.id = ad.enrollment_id
         where ad.school_id = v_school
           and ad.is_locked
           and ad.status in ('absent', 'late')
      ) q
     where q.rn % greatest(1, (q.total / 20)::int) = 1
     order by q.d, q.enrollment_id
     limit 20
  loop
    v_reason := v_reasons[(v_n % array_length(v_reasons, 1)) + 1];
    -- Owner and principal only, and this simulation runs as the owner. A class
    -- teacher calling this is refused, which is the point of 0121.
    perform public.fn_unlock_attendance(r.session_id, r.class_id, r.section_id, r.d, v_reason);
    v_new := case when r.was = 'absent' then 'leave' else 'present' end;
    perform public.fn_mark_attendance(r.d,
      jsonb_build_array(jsonb_build_object('enrollment_id', r.enrollment_id, 'status', v_new)),
      v_reason);
    -- Closed again. A day left open after a correction is a day somebody can
    -- quietly change a second time.
    perform public.fn_finalize_attendance(r.session_id, r.class_id, r.section_id, r.d);
    v_n := v_n + 1;
  end loop;

  select count(*) into v_rows from public.attendance_daily
   where school_id = v_school and corrected_from is not null;
  raise notice 'the register put right: % day(s) reopened, % row(s) carry a correction', v_n, v_rows;
end
$sim$;


-- The clock is NOT set here. Every timestamp in this simulation is moved onto
-- its real date by 08_the_clock.sql, in one place, as the table owner, because
-- created_at is not writable by a school. An earlier draft did the register
-- half here and the rest there, which is two places to look for one rule and
-- meant this file reported "0 rows moved" once 08 existed.
