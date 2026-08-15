-- =============================================================================
-- Exams module — marks entry, grading, and result-card generation, as
-- server-side Postgres functions (SECURITY DEFINER + explicit role guards).
--
-- Shape (see docs/02-DATA-MODEL.md):
--   * exam_terms       — a term in a session (First Term, Mid, Final…).
--   * exam_subjects    — which subjects a class sits in that term + their
--                        max/pass marks (unique per term+class+subject).
--   * mark_entries     — one mark per (exam_subject, enrollment); lock-after-
--                        finalize, snapshots corrected_from on a change.
--   * result_cards     — the computed card (totals, %, grade, class position,
--                        attendance %), VERSIONED with a `frozen` jsonb snapshot
--                        so a reprint is byte-identical.
--
-- Exam setup (terms/subjects) and card READS are done client-side under RLS
-- (exam_* + result_cards: read all authenticated, write owner/principal/
-- admin_clerk). Marks + card generation are here because they cross rows.
-- Enum/number-from-text gotcha applies as elsewhere.
-- =============================================================================

-- Percentage → letter grade, honouring school_settings.pass_percent. (A gpa10
-- scale can refine this later; v1 is the common letter scale.)
create or replace function public.fn_grade_for(p_percent numeric)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_pass numeric;
begin
  if p_percent is null then return null; end if;
  select coalesce(pass_percent, 33) into v_pass from public.school_settings where school_id = public.current_school_id();
  v_pass := coalesce(v_pass, 33);
  if p_percent < v_pass then return 'F'; end if;
  return case
    when p_percent >= 90 then 'A+'
    when p_percent >= 80 then 'A'
    when p_percent >= 70 then 'B'
    when p_percent >= 60 then 'C'
    when p_percent >= 50 then 'D'
    else 'E' end;
end;
$$;

-- The marksheet for one exam subject: every active enrollment in the class with
-- its mark (null = unmarked), absent flag, lock state, and the subject max.
create or replace function public.fn_exam_marksheet(p_exam_subject_id uuid)
returns table(
  enrollment_id uuid, student_id uuid, full_name text, roll_no text,
  section_name text, marks numeric, is_absent boolean, is_locked boolean, max_marks numeric
) language plpgsql stable security definer set search_path = public as $$
declare v_session uuid; v_class uuid; v_max numeric;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the marksheet';
  end if;
  perform public.assert_own('exam_subjects', p_exam_subject_id);
  select t.session_id, es.class_id, es.max_marks into v_session, v_class, v_max
  from public.exam_subjects es join public.exam_terms t on t.id = es.exam_term_id
  where es.id = p_exam_subject_id;
  if v_session is null then raise exception 'Exam subject not found'; end if;
  return query
    select e.id, s.id, s.full_name, e.roll_no, sec.name,
           me.marks, coalesce(me.is_absent, false), coalesce(me.is_locked, false), v_max
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.sections sec on sec.id = e.section_id
    left join public.mark_entries me on me.exam_subject_id = p_exam_subject_id and me.enrollment_id = e.id
    where e.session_id = v_session and e.class_id = v_class and e.status = 'active' and s.deleted_at is null
    order by sec.sort_order nulls first,
             coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- Enter/overwrite marks for one exam subject. Idempotent per (subject, student);
-- skips locked rows; snapshots corrected_from on a change. p_marks = jsonb array
-- of { enrollment_id, marks, is_absent }.
create or replace function public.fn_enter_marks(p_exam_subject_id uuid, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_total  integer;
  v_marked integer;
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
    insert into public.mark_entries as me (exam_subject_id, enrollment_id, marks, max_marks, is_absent, marked_by)
    select p_exam_subject_id, enrollment_id, marks, v_max, is_absent, v_actor from input
    on conflict (exam_subject_id, enrollment_id) where exam_subject_id is not null
    do update set marks = excluded.marks, is_absent = excluded.is_absent, marked_by = excluded.marked_by,
                  corrected_from = case when me.marks is distinct from excluded.marks then me.marks else me.corrected_from end
    where not me.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Generate result cards for a class in a term: sum marks across the term's exam
-- subjects, compute %, grade, class position (rank), and attendance % over the
-- term window, then write a NEW version with a frozen jsonb snapshot (so any
-- reprint is byte-identical). Results are withheld for fee-defaulters when the
-- term says so. owner/principal/admin_clerk only.
create or replace function public.fn_generate_result_cards(p_exam_term_id uuid, p_class_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_actor   uuid := auth.uid();
  v_session uuid; v_from date; v_to date; v_withhold boolean;
  v_count   integer := 0;
  r         record;
  v_ver     integer; v_att numeric; v_grade text; v_frozen jsonb; v_bal numeric; v_withheld boolean;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate result cards';
  end if;
  perform public.assert_own('exam_terms', p_exam_term_id);
  perform public.assert_own('classes', p_class_id);
  select session_id, starts_on, ends_on, result_withheld_for_defaulters
    into v_session, v_from, v_to, v_withhold
  from public.exam_terms where id = p_exam_term_id;
  if v_session is null then raise exception 'Exam term not found'; end if;

  for r in
    with subj as (
      select id, max_marks from public.exam_subjects
      where exam_term_id = p_exam_term_id and class_id = p_class_id
    ),
    tot as (
      select e.id as enrollment_id, e.student_id,
             coalesce(sum(case when me.is_absent then 0 else me.marks end), 0) as total_marks,
             (select coalesce(sum(max_marks), 0) from subj) as total_max
      from public.enrollments e
      left join public.mark_entries me
        on me.enrollment_id = e.id and me.exam_subject_id in (select id from subj)
      where e.session_id = v_session and e.class_id = p_class_id and e.status = 'active'
      group by e.id, e.student_id
    ),
    ranked as (
      select *, case when total_max > 0 then round(total_marks / total_max * 100, 2) else null end as pct
      from tot
    )
    select enrollment_id, student_id, total_marks, total_max, pct,
           rank() over (order by pct desc nulls last) as position
    from ranked
  loop
    select coalesce(max(version), 0) + 1 into v_ver from public.result_cards
      where enrollment_id = r.enrollment_id and exam_term_id = p_exam_term_id;

    select case when count(*) = 0 then null else
      round(100.0 * (count(*) filter (where status in ('present','late')) + 0.5 * count(*) filter (where status = 'half_day')) / count(*), 1) end
      into v_att
    from public.attendance_daily
    where enrollment_id = r.enrollment_id
      and (v_from is null or attendance_date >= v_from)
      and (v_to   is null or attendance_date <= v_to);

    v_grade    := public.fn_grade_for(r.pct);
    v_bal      := public.student_balance(r.student_id);
    v_withheld := coalesce(v_withhold, false) and coalesce(v_bal, 0) > 0;

    select jsonb_build_object(
      'subjects', coalesce(jsonb_agg(jsonb_build_object(
          'subject', sub.name, 'max', es.max_marks, 'pass', es.pass_marks,
          'marks', me.marks, 'is_absent', coalesce(me.is_absent, false),
          'grade', public.fn_grade_for(case when es.max_marks > 0 and not coalesce(me.is_absent, false) and me.marks is not null
                                            then round(me.marks / es.max_marks * 100, 2) else null end)
        ) order by sub.sort_order, sub.name), '[]'::jsonb),
      'total_marks', r.total_marks, 'total_max', r.total_max, 'percentage', r.pct,
      'grade', v_grade, 'position', r.position, 'attendance_pct', v_att,
      'withheld', v_withheld, 'balance', v_bal)
      into v_frozen
    from public.exam_subjects es
    join public.subjects sub on sub.id = es.subject_id
    left join public.mark_entries me on me.exam_subject_id = es.id and me.enrollment_id = r.enrollment_id
    where es.exam_term_id = p_exam_term_id and es.class_id = p_class_id;

    insert into public.result_cards(student_id, enrollment_id, exam_term_id, total_marks, total_max,
      percentage, grade, position, attendance_pct, version, frozen, generated_by)
    values (r.student_id, r.enrollment_id, p_exam_term_id, r.total_marks, r.total_max,
      r.pct, v_grade, r.position, v_att, v_ver, v_frozen, v_actor);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

grant execute on function public.fn_grade_for(numeric) to authenticated;
grant execute on function public.fn_exam_marksheet(uuid) to authenticated;
grant execute on function public.fn_enter_marks(uuid, jsonb) to authenticated;
grant execute on function public.fn_generate_result_cards(uuid, uuid) to authenticated;
