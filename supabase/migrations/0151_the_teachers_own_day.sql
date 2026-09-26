-- =============================================================================
-- 0151: the teacher's own day.
--
-- The teacher portal was rebuilt, and reading every screen against the
-- database found four things wrong underneath it.
--
--   1. A SUBJECT TEACHER HAD AN EMPTY PORTAL. Every teacher screen took its
--      classes from fn_my_assignments, which reads teacher_assignments: the
--      CLASS teacher's table. A teacher who only teaches Maths to Class 4
--      (subject_teachers, 0085) saw "You have no class assigned yet" on the
--      home screen, no class in the Tests picker, and no class in Subject
--      attendance, the one screen that exists for them. The database let them
--      set and mark those tests all along; no screen could reach it.
--      fn_my_teaching() lists both, with the subject on each subject row.
--      fn_my_assignments is left exactly as it is: the daily register belongs
--      to the class teacher (0134) and it is the right answer to that question.
--
--   2. THE HOME SCREEN COULD NOT SAY WHAT TODAY NEEDS. fn_my_day() answers,
--      for the teacher's own classes: how many pupils, whether today's
--      register is marked, saved or locked and what it says, whose birthday
--      it is, which tests are this week and how many are waiting to be marked.
--      One read, scoped to the caller's own staff record, on Karachi's clock.
--
--   3. A TEST SET BY MISTAKE COULD NOT BE REMOVED BY ITS TEACHER. Deleting a
--      test is owner and principal only, which is right for a test with marks
--      in it. But a duplicate "Test 1" with no marks stayed for ever, and once
--      its date passed fn_my_unmarked_tests chased the teacher to mark it every
--      day. fn_delete_my_test() lets the teacher who may set the test remove
--      it while it is unlocked and has no mark and no absence recorded.
--
--   4. A LOCKED TEST COULD STILL BE EDITED. The update policy checks who may
--      set the test, not whether it is locked, so a teacher could change a
--      locked test's date, class or total directly. And the total could change
--      after marks were saved, so "18" entered out of 20 read as 18 out of 25.
--      A trigger now freezes a locked test (only the lock itself may change,
--      which is how the head's reopen works) and fixes the total, the class,
--      the section and the year once any mark or absence is saved.
--
--   5. A SECTION'S SUBJECT TEACHER COULD SET A TEST FOR THE WHOLE CLASS.
--      fn_may_mark_subject reads a query with no section as "the whole class"
--      and lets any teacher of that subject in that class through, which is
--      right for an EXAM (an exam paper is set for a class, see 0085). For a
--      class test it let the Maths teacher of 5 A set a test with no section
--      and then enter marks for 5 B's children. fn_may_set_a_test now asks for
--      whole-class cover when the test has no section: the class teacher of
--      the whole class, a subject assignment with no section, or the owner.
--      Exams are unaffected; they do not use this function.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Everything this teacher teaches, this year
-- ---------------------------------------------------------------------------
create or replace function public.fn_my_teaching()
returns table(
  class_id uuid, class_name text, level_order integer,
  section_id uuid, section_name text,
  is_class_teacher boolean, subject_id uuid, subject_name text
) language sql stable security definer set search_path = public as $$
  select ta.class_id, c.name, c.level_order, ta.section_id, sec.name,
         true, null::uuid, null::text
    from public.teacher_assignments ta
    join public.academic_sessions s on s.id = ta.session_id and s.is_current
    join public.classes c on c.id = ta.class_id
    left join public.sections sec on sec.id = ta.section_id
    join public.staff sf on sf.id = ta.staff_id and sf.status <> 'left'
   where ta.staff_id = public.my_staff_id()
     and ta.school_id = public.current_school_id()
  union all
  select st.class_id, c.name, c.level_order, st.section_id, sec.name,
         false, st.subject_id, sub.name
    from public.subject_teachers st
    join public.academic_sessions s on s.id = st.session_id and s.is_current
    join public.classes c on c.id = st.class_id
    left join public.sections sec on sec.id = st.section_id
    join public.subjects sub on sub.id = st.subject_id
    join public.staff sf on sf.id = st.staff_id and sf.status <> 'left'
   where st.staff_id = public.my_staff_id()
     and st.school_id = public.current_school_id()
  order by 3, 5 nulls first, 6 desc, 8;
$$;

revoke all on function public.fn_my_teaching() from public, anon;
grant execute on function public.fn_my_teaching() to authenticated;

comment on function public.fn_my_teaching() is
  'The caller''s own classes this year: the ones they are class teacher of '
  '(subject null) and the ones they teach a subject in. See 0151.';

-- ---------------------------------------------------------------------------
-- 2. What today needs, for the teacher's own classes
-- ---------------------------------------------------------------------------
create or replace function public.fn_my_day()
returns jsonb language plpgsql stable security definer
set search_path = public set timezone to 'Asia/Karachi' as $$
declare
  v_school   uuid := public.current_school_id();
  v_today    date := (now() at time zone 'Asia/Karachi')::date;
  v_year     integer := extract(year from (now() at time zone 'Asia/Karachi'))::integer;
  v_session  uuid;
  v_classes  jsonb;
  v_birth    jsonb;
  v_upcoming jsonb;
  v_to_mark  integer := 0;
begin
  if v_school is null or not public.has_role('owner', 'class_teacher', 'subject_teacher') then
    raise exception 'This is a teacher''s own day' using errcode = '42501';
  end if;

  select s.id into v_session
    from public.academic_sessions s
   where s.school_id = v_school and s.is_current
   limit 1;
  if v_session is null then
    return jsonb_build_object('today', v_today, 'session_id', null, 'classes', '[]'::jsonb,
      'birthdays', '[]'::jsonb, 'upcoming', '[]'::jsonb, 'to_mark', 0);
  end if;

  -- One card per class and section the teacher teaches. A class teacher row
  -- and subject rows for the same class and section fold into one card.
  with mine as (
    select * from public.fn_my_teaching()
  ), grouped as (
    select m.class_id, m.class_name, m.level_order, m.section_id, m.section_name,
           bool_or(m.is_class_teacher) as is_class_teacher,
           coalesce(array_agg(distinct m.subject_name) filter (where m.subject_name is not null),
                    '{}'::text[]) as subjects
      from mine m
     group by 1, 2, 3, 4, 5
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'class_id', g.class_id, 'class_name', g.class_name,
           'section_id', g.section_id, 'section_name', g.section_name,
           'is_class_teacher', g.is_class_teacher,
           'subjects', to_jsonb(g.subjects),
           'pupils', r.pupils,
           -- The register is the class teacher's (0134), so only their cards
           -- carry it. A subject teacher is not asked about a register they
           -- cannot mark.
           'register', case when g.is_class_teacher then jsonb_build_object(
               'marked', r.marked, 'present', r.present, 'late', r.late,
               'half_day', r.half_day, 'absent', r.absent, 'leave', r.leave,
               'locked', r.pupils > 0 and r.locked = r.pupils) end)
         order by g.level_order, g.section_name nulls first), '[]'::jsonb)
    into v_classes
    from grouped g
    cross join lateral (
      select count(*)::integer as pupils,
             count(ad.enrollment_id)::integer as marked,
             count(*) filter (where ad.status = 'present')::integer as present,
             count(*) filter (where ad.status = 'late')::integer as late,
             count(*) filter (where ad.status = 'half_day')::integer as half_day,
             count(*) filter (where ad.status = 'absent')::integer as absent,
             count(*) filter (where ad.status = 'leave')::integer as leave,
             count(*) filter (where ad.is_locked)::integer as locked
        from public.enrollments e
        left join public.attendance_daily ad
               on ad.enrollment_id = e.id and ad.attendance_date = v_today
       where e.school_id = v_school
         and e.session_id = v_session
         and e.class_id = g.class_id
         and (g.section_id is null or e.section_id = g.section_id)
         and e.status = 'active'
    ) r;

  -- Birthdays today among the teacher's own pupils. 29 February is kept on
  -- the 28th in a year that has no 29th, as fn_birthdays does.
  select coalesce(jsonb_agg(jsonb_build_object(
           'full_name', b.full_name, 'class_name', b.class_name,
           'section_name', b.section_name, 'turning', b.turning)
         order by b.full_name), '[]'::jsonb)
    into v_birth
    from (
      select distinct s.id, s.full_name, c.name as class_name, sec.name as section_name,
             (v_year - extract(year from s.dob))::integer as turning
        from public.fn_my_teaching() m
        join public.enrollments e
          on e.school_id = v_school and e.session_id = v_session
         and e.class_id = m.class_id
         and (m.section_id is null or e.section_id = m.section_id)
         and e.status = 'active'
        join public.students s on s.id = e.student_id and s.deleted_at is null and s.dob is not null
        join public.classes c on c.id = e.class_id
        left join public.sections sec on sec.id = e.section_id
       where to_char(s.dob, 'MM-DD') = to_char(v_today, 'MM-DD')
          or (to_char(s.dob, 'MM-DD') = '02-29' and to_char(v_today, 'MM-DD') = '02-28'
              and not (v_year % 4 = 0 and (v_year % 100 <> 0 or v_year % 400 = 0)))
    ) b;

  -- This week's tests the teacher may set: today and the next seven days,
  -- not locked. fn_may_set_a_test is the same rule the marks grid uses, so a
  -- subject teacher sees their subject's tests and not a colleague's.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'title', t.title, 'date', t.assessment_date,
           'max_marks', t.max_marks, 'class_id', t.class_id, 'class_name', t.class_name,
           'section_name', t.section_name, 'subject_name', t.subject_name)
         order by t.assessment_date, t.class_name, t.title), '[]'::jsonb)
    into v_upcoming
    from (
      select a.id, a.title, a.assessment_date, a.max_marks, a.class_id,
             c.name as class_name, sec.name as section_name, sub.name as subject_name
        from public.assessments a
        join public.classes c on c.id = a.class_id
        left join public.sections sec on sec.id = a.section_id
        left join public.subjects sub on sub.id = a.subject_id
       where a.school_id = v_school
         and a.session_id = v_session
         and not a.is_locked
         and a.assessment_date between v_today and v_today + 7
         and public.fn_may_set_a_test(a.session_id, a.class_id, a.section_id, a.subject_id)
       limit 20
    ) t;

  select count(*)::integer into v_to_mark from public.fn_my_unmarked_tests(v_session);

  return jsonb_build_object(
    'today', v_today, 'session_id', v_session, 'classes', v_classes,
    'birthdays', v_birth, 'upcoming', v_upcoming, 'to_mark', v_to_mark);
end;
$$;

revoke all on function public.fn_my_day() from public, anon;
grant execute on function public.fn_my_day() to authenticated;

comment on function public.fn_my_day() is
  'The teacher home screen in one read: each of the caller''s classes with '
  'today''s register (class teacher only), birthdays among their pupils, this '
  'week''s tests and how many are waiting to be marked. See 0151.';

-- ---------------------------------------------------------------------------
-- 3. A teacher removes a test set by mistake, while nothing is in it
-- ---------------------------------------------------------------------------
create or replace function public.fn_delete_my_test(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_a public.assessments%rowtype;
begin
  if not public.has_role('owner', 'class_teacher', 'subject_teacher') then
    raise exception 'A test is removed by the teacher who set it. A principal '
      'can remove one from the Tests overview.' using errcode = '42501';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  select * into v_a from public.assessments
   where id = p_assessment_id and school_id = public.current_school_id();
  if not found then raise exception 'Test not found' using errcode = '42501'; end if;

  if not public.fn_may_set_a_test(v_a.session_id, v_a.class_id, v_a.section_id, v_a.subject_id) then
    raise exception 'You can only remove a test for a class and subject you teach.'
      using errcode = '42501';
  end if;
  if v_a.is_locked then
    raise exception 'This test is locked, so it stays. The owner or the principal can reopen it.'
      using errcode = '42501';
  end if;
  if exists (select 1 from public.mark_entries me
              where me.assessment_id = p_assessment_id
                and (me.marks is not null or me.is_absent)) then
    raise exception 'Marks have been entered for this test, so it cannot be removed. '
      'If it was set by mistake, ask the principal.' using errcode = '22023';
  end if;

  delete from public.mark_entries where assessment_id = p_assessment_id;
  delete from public.assessments where id = p_assessment_id;
end;
$$;

revoke all on function public.fn_delete_my_test(uuid) from public, anon;
grant execute on function public.fn_delete_my_test(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. A locked test is frozen, and saved marks fix the test they belong to
--
-- SECURITY DEFINER so the marks check reads mark_entries whoever the caller is.
-- It takes no argument a caller could point anywhere: it reads the row being
-- updated and nothing else.
-- ---------------------------------------------------------------------------
create or replace function public.guard_assessment_edits()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_has_marks boolean;
begin
  -- Only the lock may change on a locked test: that is how fn_lock_assessment
  -- sets it and how the head's reopen (fn_unlock_assessment) clears it.
  if old.is_locked and new.is_locked
     and (new.session_id, new.class_id, new.section_id, new.subject_id, new.title,
          new.assessment_date, new.max_marks, new.weightage)
         is distinct from
         (old.session_id, old.class_id, old.section_id, old.subject_id, old.title,
          old.assessment_date, old.max_marks, old.weightage) then
    raise exception 'This test is locked, so it cannot be changed. The owner or the '
      'principal can reopen it.' using errcode = '42501';
  end if;

  if (new.max_marks, new.class_id, new.section_id, new.session_id)
     is distinct from (old.max_marks, old.class_id, old.section_id, old.session_id) then
    select exists (select 1 from public.mark_entries me
                    where me.assessment_id = old.id
                      and me.school_id = old.school_id
                      and (me.marks is not null or me.is_absent))
      into v_has_marks;
    if v_has_marks and new.max_marks is distinct from old.max_marks then
      raise exception 'Marks have already been entered out of %, so the total cannot '
        'change to %. Every saved mark would mean something else.',
        trim_scale(old.max_marks), trim_scale(new.max_marks) using errcode = '22023';
    end if;
    if v_has_marks then
      raise exception 'Marks have already been entered for this class, so the test '
        'cannot move to another class, section or year.' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.guard_assessment_edits() from public, anon, authenticated;

drop trigger if exists trg_assessment_edits on public.assessments;
create trigger trg_assessment_edits
  before update on public.assessments
  for each row execute function public.guard_assessment_edits();

-- ---------------------------------------------------------------------------
-- 5. A test with no section needs whole-class cover
--
-- Same signature and the same two conditions as 0135, plus the third. Still
-- fn_may_ and SECURITY DEFINER: it is read inside the assessments row policies.
-- ---------------------------------------------------------------------------
create or replace function public.fn_may_set_a_test(
  p_session uuid, p_class uuid, p_section uuid, p_subject uuid
) returns boolean language sql stable security definer set search_path = public as $$
  select not public.has_role('principal')
     and public.fn_may_mark_subject(p_session, p_class, p_section, p_subject)
     and (
       p_section is not null
       or public.has_role('owner')
       or exists (select 1 from public.teacher_assignments ta
                   where ta.staff_id = public.my_staff_id()
                     and ta.school_id = public.current_school_id()
                     and ta.session_id = p_session and ta.class_id = p_class
                     and ta.section_id is null)
       or exists (select 1 from public.subject_teachers st
                   where st.staff_id = public.my_staff_id()
                     and st.school_id = public.current_school_id()
                     and st.session_id = p_session and st.class_id = p_class
                     and st.section_id is null and st.subject_id = p_subject)
     );
$$;

revoke all on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.fn_may_set_a_test(uuid, uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Did it take?
--
-- A WARNING and not an exception, for the reason recorded in 0100: a bundle
-- runs as ONE transaction and raising here would revert everything else in it.
-- supabase/tests/the_teachers_own_day.sql walks it as real logins.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.fn_my_teaching()') is null then
    v_bad := v_bad || 'fn_my_teaching is missing';
  end if;
  if to_regprocedure('public.fn_my_day()') is null then
    v_bad := v_bad || 'fn_my_day is missing';
  end if;
  if to_regprocedure('public.fn_delete_my_test(uuid)') is null then
    v_bad := v_bad || 'fn_delete_my_test is missing';
  end if;
  if not exists (select 1 from pg_trigger t
                  where t.tgrelid = 'public.assessments'::regclass
                    and t.tgname = 'trg_assessment_edits' and not t.tgisinternal) then
    v_bad := v_bad || 'a locked test can still be edited';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'fn_may_set_a_test'
                    and p.prosrc like '%section_id is null%') then
    v_bad := v_bad || 'a section''s subject teacher can still set a test for the whole class';
  end if;

  if array_length(v_bad, 1) is null then
    raise notice '0151: subject teachers see their classes, the home screen knows the day, '
      'a mistaken test can be removed and a locked one cannot change';
  else
    raise warning '0151: %. Everything else in this bundle applied. Send the output of '
      'supabase/verify.sql.', array_to_string(v_bad, '; ');
  end if;
end $assert$;
