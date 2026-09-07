-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE 3 OF 7: the register
--
-- 589 school days of student and staff attendance, finalised for every day except today. About a minute.
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
     order by a.starts_on, c.level_order, s.sort_order
  loop
    for v_day in
      select d from sim_day
       where d between greatest(r.starts_on, date '2024-02-01') and least(r.ends_on, current_date)
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


-- The clock is NOT set here. Every timestamp in this simulation is moved onto
-- its real date by 08_the_clock.sql, in one place, as the table owner, because
-- created_at is not writable by a school. An earlier draft did the register
-- half here and the rest there, which is two places to look for one rule and
-- meant this file reported "0 rows moved" once 08 existed.
