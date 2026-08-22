-- =============================================================================
-- 0048 — Make the mark and attendance audit trail visible.
--
-- WHAT WAS WRONG
--
-- mark_entries and attendance_daily both carry `corrected_from` and
-- `correction_reason`. The three entry functions diligently write
-- `corrected_from` — the previous mark, the previous attendance status —
-- whenever a value actually changes.
--
-- Nothing has ever READ either column. Not one function, not one screen. And
-- `correction_reason` was never written at all.
--
-- So the system quietly records that a teacher changed a mark from 45 to 40 the
-- night before results, and no principal can see it, no parent disputing that
-- mark can be answered, and nobody was ever asked why. An audit trail nobody
-- can read is not an audit trail; it is a database column that makes the
-- software look trustworthy without being trustworthy.
--
-- Found by supabase/check-columns-used.sh, which now fails CI for any new
-- column nothing reads or writes.
--
-- WHAT THIS DOES
--
--   1. The three entry functions take an optional reason, and record it ONLY on
--      the rows whose value actually changed. A reason attached to an unchanged
--      mark would be noise in the very report this exists to make readable.
--   2. Two read paths — fn_mark_corrections and fn_attendance_corrections —
--      gated on owner/principal, because this is an oversight tool. A subject
--      teacher auditing colleagues is not what it is for, and the person most
--      likely to want it hidden is the person who changed the mark.
--
-- WHY THE SIGNATURES ARE DROPPED AND RECREATED
--
-- `create or replace` cannot add a parameter: it creates an OVERLOAD instead,
-- and then a two-argument call matches both the old function and the new one's
-- default, which Postgres rejects as ambiguous. So the two-argument forms are
-- dropped first. Existing two-argument callers — the app included — keep
-- working through the new default.
-- =============================================================================

drop function if exists public.fn_enter_marks(uuid, jsonb);
drop function if exists public.fn_enter_assessment_marks(uuid, jsonb);
drop function if exists public.fn_mark_attendance(date, jsonb);

-- ---------------------------------------------------------------------------
-- 1. Exam marks
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_marks(
  p_exam_subject_id uuid, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks into v_max from public.exam_subjects where id = p_exam_subject_id;
  if v_max is null then raise exception 'Exam subject not found'; end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_max)
  ) then
    raise exception 'Marks must be between 0 and %', v_max;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (exam_subject_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_exam_subject_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (exam_subject_id, enrollment_id) where exam_subject_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
                  -- Only on the rows that actually CHANGED. Stamping the reason
                  -- on an unchanged mark would fill the corrections report with
                  -- rows where nothing happened, which is how a report stops
                  -- being read.
                  correction_reason = case when me.marks is distinct from excluded.marks
                                           then v_reason else me.correction_reason end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Assessment (class test) marks
-- ---------------------------------------------------------------------------
create or replace function public.fn_enter_assessment_marks(
  p_assessment_id uuid, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_a      record;
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  select * into v_a from public.assessments
  where id = p_assessment_id and school_id = public.current_school_id();
  if not found then raise exception 'Assessment not found'; end if;
  if v_a.is_locked then raise exception 'This assessment is locked'; end if;

  -- Teacher scope, as before: a subject teacher may only mark their own class.
  if not public.has_role('owner','principal','admin_clerk') then
    if not public.fn_may_manage_class(v_a.session_id, v_a.class_id, v_a.section_id) then
      raise exception 'You can only enter marks for your assigned class';
    end if;
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where coalesce((e->>'is_absent')::boolean, false) = false
      and nullif(e->>'marks', '') is not null
      and ((e->>'marks')::numeric < 0 or (e->>'marks')::numeric > v_a.max_marks)
  ) then
    raise exception 'Marks must be between 0 and %', v_a.max_marks;
  end if;

  -- Every enrolment must be in this school.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id())
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, marks, is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.mark_entries as me
      (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_a.max_marks, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent,
                  marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks
                                        then me.marks else me.corrected_from end,
                  correction_reason = case when me.marks is distinct from excluded.marks
                                           then v_reason else me.correction_reason end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Attendance
-- ---------------------------------------------------------------------------
create or replace function public.fn_mark_attendance(
  p_date date, p_marks jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to mark attendance';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- Tenant scope: every enrolment must be in THIS school. Checked for all
  -- roles, because the teacher-scope check below is skipped for admins —
  -- leaving them able to mark attendance against another school's enrolment ids.
  if exists (
    select 1 from jsonb_array_elements(p_marks) e
    where not exists (
      select 1 from public.enrollments en
      where en.id = (e->>'enrollment_id')::uuid
        and en.school_id = public.current_school_id()
    )
  ) then
    raise exception 'Unknown enrolment in this school' using errcode = '42501';
  end if;

  if not public.has_role('owner','principal','admin_clerk') then
    if exists (
      select 1 from jsonb_array_elements(p_marks) e
      join public.enrollments en on en.id = (e->>'enrollment_id')::uuid
      where not public.fn_may_manage_class(en.session_id, en.class_id, en.section_id)
    ) then
      raise exception 'You can only mark attendance for your assigned class';
    end if;
  end if;

  select count(distinct (e->>'enrollment_id')) into v_total
  from jsonb_array_elements(p_marks) e;

  with input as (
    select distinct on (enrollment_id) enrollment_id, status
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             (e->>'status')::public.attendance_status as status
      from jsonb_array_elements(p_marks) e
    ) q
    order by enrollment_id
  ),
  upserted as (
    insert into public.attendance_daily as ad
      (enrollment_id, attendance_date, status, marked_by)
    select enrollment_id, p_date, status, v_actor from input
    on conflict (enrollment_id, attendance_date) do update
      set status = excluded.status,
          marked_by = excluded.marked_by,
          corrected_from = case when ad.status is distinct from excluded.status
                                then ad.status else ad.corrected_from end,
          correction_reason = case when ad.status is distinct from excluded.status
                                   then v_reason else ad.correction_reason end
      where not ad.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The read path that did not exist
--
-- Every mark that has been changed since it was first entered, across exams and
-- class tests, with what it was, what it is, who changed it and why. This is
-- the answer to "my son got 45, you have written 40", and it is the report a
-- head teacher wants the week before results go out.
--
-- Owner and principal only. This is an oversight tool, and the person most
-- likely to want it hidden is the person who changed the mark.
-- ---------------------------------------------------------------------------
create or replace function public.fn_mark_corrections(
  p_from date default null, p_to date default null)
returns table (
  changed_at timestamptz, kind text, student_name text, gr_no text,
  class_name text, section_name text, subject_name text, paper text,
  was numeric, now_is numeric, max_marks numeric, is_absent boolean,
  reason text, changed_by text, is_locked boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may review mark corrections'
      using errcode = '42501';
  end if;

  return query
  select
    me.updated_at,
    case when me.exam_subject_id is not null then 'Exam' else 'Class test' end,
    s.full_name, s.gr_no, c.name, sec.name,
    coalesce(subj_x.name, subj_a.name),
    coalesce(et.name, a.title),
    me.corrected_from, me.marks, me.max_marks, me.is_absent,
    me.correction_reason,
    coalesce(p.full_name, '—'),
    me.is_locked
  from public.mark_entries me
  join public.enrollments en on en.id = me.enrollment_id and en.school_id = v_school
  join public.students s on s.id = en.student_id and s.school_id = v_school
  left join public.classes c on c.id = en.class_id and c.school_id = v_school
  left join public.sections sec on sec.id = en.section_id and sec.school_id = v_school
  left join public.exam_subjects es on es.id = me.exam_subject_id and es.school_id = v_school
  left join public.exam_terms et on et.id = es.exam_term_id and et.school_id = v_school
  left join public.subjects subj_x on subj_x.id = es.subject_id and subj_x.school_id = v_school
  left join public.assessments a on a.id = me.assessment_id and a.school_id = v_school
  left join public.subjects subj_a on subj_a.id = a.subject_id and subj_a.school_id = v_school
  left join public.profiles p on p.id = me.marked_by
  where me.school_id = v_school
    -- corrected_from is only set when a mark actually changed, so its presence
    -- IS the definition of a correction.
    and me.corrected_from is not null
    and (p_from is null or me.updated_at::date >= p_from)
    and (p_to   is null or me.updated_at::date <= p_to)
  order by me.updated_at desc;
end;
$$;

-- Attendance changes. Lower stakes than marks, but the same principle: an
-- attendance record altered after the fact, with no reason, is how a disputed
-- absence becomes unanswerable.
create or replace function public.fn_attendance_corrections(
  p_from date default null, p_to date default null)
returns table (
  changed_at timestamptz, attendance_date date, student_name text, gr_no text,
  class_name text, section_name text, was text, now_is text,
  reason text, changed_by text)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may review attendance corrections'
      using errcode = '42501';
  end if;

  return query
  select
    ad.updated_at, ad.attendance_date, s.full_name, s.gr_no, c.name, sec.name,
    ad.corrected_from::text, ad.status::text,
    ad.correction_reason, coalesce(p.full_name, '—')
  from public.attendance_daily ad
  join public.enrollments en on en.id = ad.enrollment_id and en.school_id = v_school
  join public.students s on s.id = en.student_id and s.school_id = v_school
  left join public.classes c on c.id = en.class_id and c.school_id = v_school
  left join public.sections sec on sec.id = en.section_id and sec.school_id = v_school
  left join public.profiles p on p.id = ad.marked_by
  where ad.school_id = v_school
    and ad.corrected_from is not null
    and (p_from is null or ad.updated_at::date >= p_from)
    and (p_to   is null or ad.updated_at::date <= p_to)
  order by ad.updated_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants. The three entry functions were granted under their old
--    two-argument signatures, which no longer exist.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_enter_marks(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_enter_assessment_marks(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_mark_attendance(date, jsonb, text) to authenticated;
grant execute on function public.fn_mark_corrections(date, date) to authenticated;
grant execute on function public.fn_attendance_corrections(date, date) to authenticated;

revoke all on function public.fn_enter_marks(uuid, jsonb, text) from anon;
revoke all on function public.fn_enter_assessment_marks(uuid, jsonb, text) from anon;
revoke all on function public.fn_mark_attendance(date, jsonb, text) from anon;
revoke all on function public.fn_mark_corrections(date, date) from anon;
revoke all on function public.fn_attendance_corrections(date, date) from anon;
