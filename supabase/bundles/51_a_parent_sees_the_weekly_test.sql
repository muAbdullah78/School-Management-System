-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0150_a_parent_sees_the_weekly_test.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0150: a parent sees the weekly test.
--
-- A class teacher set a weekly test for Class 4, marked it and locked it. The
-- office saw it at once. The parent of a child in Class 4 opened Results and
-- read "No results published yet".
--
-- THE PORTAL HAD NO WAY TO SEE A TEST AT ALL. fn_portal_child_results reads
-- result_cards, which exist only for exam TERMS, and only once the office
-- publishes a term. A class test is an assessments row with mark_entries, and
-- no portal function had ever read either table. So the week-to-week record a
-- parent most wants, how did my child do in Friday's test, could not reach
-- them in any form, and the Results tab said nothing had been published while
-- the teacher's work sat in the database.
--
-- WHAT THIS ADDS
--
--   1. fn_portal_child_tests(student). Every LOCKED test this child sat, with
--      their mark (or Absent), newest first. Locked, because locking is the
--      teacher saying "these marks are final": a test the teacher is still
--      entering is not shown with half its marks.
--
--      With each test, the class average and the highest mark, ONLY WHEN AT
--      LEAST FIVE PUPILS HAVE A MARK. In a class of two, the average and your
--      own child's mark give you the other child's mark exactly. Five is the
--      smallest class where that sum no longer names a child. No other child's
--      name, mark or position is ever returned.
--
--      Also the tests that are COMING UP (the teacher can schedule ahead since
--      0135) and the ones that have been SAT BUT NOT YET MARKED in the last two
--      weeks, with no marks, so a parent can help with revision and knows the
--      marks are on their way instead of assuming the teacher forgot. Older
--      unmarked tests are left off: a parent told for months that marks are
--      coming learns to ignore the line.
--
--   2. fn_portal_me, same signature, same keys, and three more per child:
--      (It keeps 0106's licence check as its first statement. 0106 patched
--      that line into the live function rather than the file, so a rewrite
--      from 0033's text would quietly reopen an unpaid school's portal. The
--      check at the foot of this file refuses to call it done without it.)
--      date of birth (the portal wishes the child a happy birthday on the
--      day), roll number, and the class teacher's name. Each child is also now
--      read from ONE enrollment: the current year's, else the latest active
--      one. The old join took every active enrollment, so a child left active
--      in last year's class as well as this year's appeared twice.
--
-- Both are SECURITY DEFINER and both start from fn__assert_my_child / the
-- caller's own family, like every other portal read. A parent passing another
-- family's child is refused with the same message as an invented id.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The weekly test, as the parent sees it
-- ---------------------------------------------------------------------------
-- On Karachi's clock, like every function that works out a date since 0148:
-- a test "today" must mean today in Pakistan between midnight and 5am too.
create or replace function public.fn_portal_child_tests(p_student_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = public set timezone to 'Asia/Karachi' as $$
declare
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_done  jsonb;
  v_next  jsonb;
begin
  perform public.fn__assert_my_child(p_student_id);

  -- Marked: every locked test with a row for one of this child's enrollments.
  -- An inner join on the child's own mark row, so a child who joined the class
  -- after a test was sat is not shown a test they never took.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'title', x.title,
           'subject', x.subject,
           'date', x.assessment_date,
           'max_marks', x.max_marks,
           'marks', x.marks,
           'is_absent', x.is_absent,
           'class_marked', x.n_marked,
           'class_average', x.avg_marks,
           'class_highest', x.high_marks,
           'session', x.session_name)
         order by x.assessment_date desc nulls last, x.created_at desc), '[]'::jsonb)
    into v_done
  from (
    select a.id, a.title,
           coalesce(sub.name, 'General') as subject,
           a.assessment_date, a.created_at,
           coalesce(me.max_marks, a.max_marks) as max_marks,
           case when me.is_absent then null else me.marks end as marks,
           me.is_absent,
           st.n_marked,
           -- Five or more, or nothing. See the header: in a smaller class the
           -- average and the parent's own mark add up to another child's.
           case when st.n_marked >= 5 then round(st.avg_marks, 1) end as avg_marks,
           case when st.n_marked >= 5 then st.high_marks end as high_marks,
           ses.name as session_name
      from public.enrollments e
      join public.assessments a
        on a.session_id = e.session_id
       and a.class_id = e.class_id
       and (a.section_id is null or a.section_id = e.section_id)
       and a.is_locked
      join public.mark_entries me
        on me.assessment_id = a.id and me.enrollment_id = e.id
      left join public.subjects sub on sub.id = a.subject_id
      left join public.academic_sessions ses on ses.id = e.session_id
      cross join lateral (
        select count(*) filter (where m2.marks is not null and not m2.is_absent) as n_marked,
               avg(m2.marks) filter (where m2.marks is not null and not m2.is_absent) as avg_marks,
               max(m2.marks) filter (where m2.marks is not null and not m2.is_absent) as high_marks
          from public.mark_entries m2
         where m2.assessment_id = a.id
      ) st
     where e.student_id = p_student_id
     order by a.assessment_date desc nulls last, a.created_at desc
     limit 100
  ) x;

  -- Coming up, today, or sat and waiting for marks. The current year's
  -- enrollment only, and never a mark: none of these is finished.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', y.id,
           'title', y.title,
           'subject', y.subject,
           'date', y.assessment_date,
           'max_marks', y.max_marks,
           'status', y.status)
         order by y.assessment_date, y.title), '[]'::jsonb)
    into v_next
  from (
    select a.id, a.title,
           coalesce(sub.name, 'General') as subject,
           a.assessment_date, a.max_marks,
           case when a.assessment_date > v_today then 'upcoming'
                when a.assessment_date = v_today then 'today'
                else 'awaiting' end as status
      from public.enrollments e
      join public.academic_sessions ses on ses.id = e.session_id and ses.is_current
      join public.assessments a
        on a.session_id = e.session_id
       and a.class_id = e.class_id
       and (a.section_id is null or a.section_id = e.section_id)
       and not a.is_locked
       and a.assessment_date is not null
      left join public.subjects sub on sub.id = a.subject_id
     where e.student_id = p_student_id
       and e.status = 'active'
       and a.assessment_date between v_today - 14 and v_today + 60
     order by a.assessment_date, a.title
     limit 30
  ) y;

  return jsonb_build_object('today', v_today, 'tests', v_done, 'upcoming', v_next);
end;
$$;

revoke all on function public.fn_portal_child_tests(uuid) from public, anon;
grant execute on function public.fn_portal_child_tests(uuid) to authenticated;

comment on function public.fn_portal_child_tests(uuid) is
  'A parent''s view of their own child''s class tests: every locked test with the '
  'child''s mark, the class average and highest only where five or more pupils '
  'have a mark, and the tests coming up or awaiting marks. See 0150.';

-- ---------------------------------------------------------------------------
-- 2. Who am I: one row per child, with a birthday, a roll number and a teacher
-- ---------------------------------------------------------------------------
create or replace function public.fn_portal_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_p record; v_school text; v_children jsonb; v_classes jsonb;
begin
  -- 0106: a school that has stopped paying closes its portal, before any read.
  perform public.fn__require_live_licence();
  select p.*, s.name as school_name into v_p
  from public.profiles p
  left join public.schools s on s.id = p.school_id
  where p.id = auth.uid();
  if not found then raise exception 'Not signed in' using errcode = '42501'; end if;

  v_school := coalesce(
    (select ss.name from public.school_settings ss where ss.school_id = v_p.school_id),
    v_p.school_name);

  if v_p.role = 'parent' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'student_id', s.id, 'full_name', s.full_name, 'gr_no', s.gr_no,
             'class_name', c.name, 'section_name', sec.name, 'status', s.status,
             'dob', s.dob,
             'roll_no', e.roll_no,
             'class_teacher', (
               select string_agg(distinct st.full_name, ', ')
                 from public.teacher_assignments ta
                 join public.staff st on st.id = ta.staff_id
                where ta.session_id = e.session_id
                  and ta.class_id = e.class_id
                  and (ta.section_id is null or ta.section_id = e.section_id)
                  and st.status <> 'left')
           ) order by s.full_name), '[]'::jsonb)
      into v_children
    from public.students s
    -- ONE enrollment: the current year's, else the latest active. The old
    -- plain join returned a row per active enrollment.
    left join lateral (
      select en.*
        from public.enrollments en
        left join public.academic_sessions ay on ay.id = en.session_id
       where en.student_id = s.id and en.status = 'active'
       order by coalesce(ay.is_current, false) desc, en.created_at desc
       limit 1
    ) e on true
    left join public.classes c on c.id = e.class_id
    left join public.sections sec on sec.id = e.section_id
    where s.family_id = v_p.family_id and s.school_id = v_p.school_id and s.deleted_at is null;
  else
    v_children := '[]'::jsonb;
  end if;

  if v_p.role in ('class_teacher', 'subject_teacher') then
    select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_classes
    from public.fn_my_assignments() a;
  else
    v_classes := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'profile_id', v_p.id,
    'full_name', v_p.full_name,
    'role', v_p.role,
    'school_name', v_school,
    'children', v_children,
    'classes', v_classes);
end;
$$;

revoke all on function public.fn_portal_me() from public, anon;
grant execute on function public.fn_portal_me() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Did it take?
--
-- A WARNING and not an exception, for the reason recorded in 0100: this file
-- is pasted as part of a bundle the SQL editor runs as ONE transaction, and
-- raising here would revert everything else in it. supabase/verify.sql names
-- what is outstanding, and supabase/tests/a_parent_sees_the_weekly_test.sql
-- proves the reads return what they should, as a parent login.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.fn_portal_child_tests(uuid)') is null then
    v_bad := v_bad || 'fn_portal_child_tests is missing';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_portal_me'
      and p.prosrc like '%class_teacher%') then
    v_bad := v_bad || 'fn_portal_me does not return the class teacher';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_portal_me'
      and p.prosrc like '%fn__require_live_licence%') then
    v_bad := v_bad || 'fn_portal_me lost the licence check 0106 gave it';
  end if;

  if array_length(v_bad, 1) is null then
    raise notice '0150: a parent now sees every locked class test, and the tests coming up';
  else
    raise warning '0150: %. Everything else in this bundle applied. Send the '
      'output of supabase/verify.sql.', array_to_string(v_bad, '; ');
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0150_a_parent_sees_the_weekly_test.sql', '51_a_parent_sees_the_weekly_test.sql');
end $ledger$;
