-- =============================================================================
-- Assessments (class tests / quizzes) — the lighter cousin of exams. Marks live
-- in the shared mark_entries table under assessment_id. These mirror the exam
-- marks functions: a roster+marks reader and a validated, idempotent upsert that
-- skips locked rows. Creating/listing assessments is plain RLS'd CRUD.
-- =============================================================================

-- Roster for one test with any marks already entered.
create or replace function public.fn_assessment_marksheet(p_assessment_id uuid)
returns table(
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, is_absent boolean, is_locked boolean, max_marks numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_section uuid; v_max numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the marksheet';
  end if;
  select a.session_id, a.class_id, a.section_id, a.max_marks
    into v_session, v_class, v_section, v_max
  from public.assessments a where a.id = p_assessment_id;
  if v_session is null then raise exception 'Assessment not found'; end if;

  return query
    select e.id, s.id, s.full_name, e.roll_no, sec.name,
           me.marks, coalesce(me.is_absent, false), coalesce(me.is_locked, false), v_max
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.sections sec on sec.id = e.section_id
    left join public.mark_entries me on me.assessment_id = p_assessment_id and me.enrollment_id = e.id
    where e.session_id = v_session and e.class_id = v_class and e.status = 'active' and s.deleted_at is null
      and (v_section is null or e.section_id = v_section)
    order by sec.sort_order nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- Enter/overwrite marks for one test. Idempotent per (assessment, student);
-- skips locked rows; snapshots corrected_from on a change. p_marks = jsonb array
-- of { enrollment_id, marks, is_absent }.
create or replace function public.fn_enter_assessment_marks(p_assessment_id uuid, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_locked boolean;
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks, is_locked into v_max, v_locked from public.assessments where id = p_assessment_id;
  if v_max is null then raise exception 'Assessment not found'; end if;
  if v_locked then raise exception 'This test is locked'; end if;
  if v_max <= 0 then raise exception 'Set the total marks for this test before entering scores'; end if;

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
    insert into public.mark_entries as me (assessment_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_assessment_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (assessment_id, enrollment_id) where assessment_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent, marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks then me.marks else me.corrected_from end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Lock a test: freeze the assessment and all its mark rows against further edits.
create or replace function public.fn_lock_assessment(p_assessment_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to lock this test';
  end if;
  if not exists (select 1 from public.assessments where id = p_assessment_id) then
    raise exception 'Assessment not found';
  end if;
  update public.mark_entries set is_locked = true where assessment_id = p_assessment_id;
  update public.assessments set is_locked = true where id = p_assessment_id;
end;
$$;

grant execute on function public.fn_assessment_marksheet(uuid) to authenticated;
grant execute on function public.fn_enter_assessment_marks(uuid, jsonb) to authenticated;
grant execute on function public.fn_lock_assessment(uuid) to authenticated;
