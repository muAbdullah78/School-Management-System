-- =============================================================================
-- Admissions module — admit a student and change a student's status, as
-- transactional Postgres functions (SECURITY DEFINER + explicit role guards).
--
-- Identity vs. year-state (see docs/02-DATA-MODEL.md):
--   * A Student is a lifelong identity carrying a gapless GR number.
--   * An Enrollment is that student's state for ONE session (class/section/roll).
--   * fn_admit_student creates both (and an optional guardian) in one txn, so a
--     new admission is immediately visible in the attendance roster and billable
--     in fees.
--
-- Enum gotcha: text from jsonb / a CASE must be cast to its enum type
--   (::public.gender, ::public.student_status, ::public.enrollment_status).
-- Bio-data EDITS and profile READS are done client-side under RLS
-- (students_write = owner/principal/admin_clerk; *_select = all authenticated),
-- so only the multi-table operations live here.
-- =============================================================================

-- Admit a new student: assign a GR number, create the student + this session's
-- enrollment (auto roll number if none given), and an optional primary guardian.
-- p is a jsonb object; recognised keys:
--   full_name (required), father_name, mother_name, b_form, dob, gender,
--   address, phone, whatsapp, admission_no, admission_date, notes,
--   session_id (required), class_id (required), section_id, roll_no,
--   gr_no (caller-supplied overrides the counter),
--   guardian: { name, relation, phone, whatsapp }
create or replace function public.fn_admit_student(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_prefix  text;
  v_counter bigint;
  v_gr      text;
  v_student uuid;
  v_enroll  uuid;
  v_session uuid := nullif(p->>'session_id','')::uuid;
  v_class   uuid := nullif(p->>'class_id','')::uuid;
  v_section uuid := nullif(p->>'section_id','')::uuid;
  v_roll    text := nullif(p->>'roll_no','');
  v_gr_in   text := nullif(p->>'gr_no','');
  v_next    int;
  v_g       jsonb := p->'guardian';
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to admit students';
  end if;
  if nullif(p->>'full_name','') is null then raise exception 'Student name is required'; end if;
  if v_session is null then raise exception 'Academic session is required'; end if;
  if v_class   is null then raise exception 'Class is required'; end if;

  -- GR number: a caller-supplied value wins; otherwise the gapless counter,
  -- prefixed with school_settings.gr_prefix and zero-padded.
  if v_gr_in is not null then
    v_gr := v_gr_in;
  else
    select gr_prefix into v_prefix from public.school_settings where school_id = public.current_school_id();
    v_counter := public.next_counter('gr');
    v_gr := coalesce(v_prefix, '') || lpad(v_counter::text, 4, '0');
  end if;

  insert into public.students(
    gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender,
    address, phone, whatsapp, status, admission_date, notes)
  values (
    v_gr,
    nullif(p->>'admission_no',''),
    p->>'full_name',
    nullif(p->>'father_name',''),
    nullif(p->>'mother_name',''),
    nullif(p->>'b_form',''),
    nullif(p->>'dob','')::date,
    nullif(p->>'gender','')::public.gender,
    nullif(p->>'address',''),
    nullif(p->>'phone',''),
    nullif(p->>'whatsapp',''),
    'active',
    coalesce(nullif(p->>'admission_date','')::date, current_date),
    nullif(p->>'notes',''))
  returning id into v_student;

  -- auto roll number = next numeric roll within the same section/session
  if v_roll is null then
    select coalesce(max(nullif(regexp_replace(coalesce(roll_no,''), '[^0-9]', '', 'g'), '')::int), 0) + 1
    into v_next
    from public.enrollments
    where session_id = v_session and class_id = v_class and section_id is not distinct from v_section;
    v_roll := v_next::text;
  end if;

  insert into public.enrollments(student_id, session_id, class_id, section_id, roll_no, status)
  values (v_student, v_session, v_class, v_section, v_roll, 'active')
  returning id into v_enroll;

  -- optional primary guardian
  if v_g is not null and jsonb_typeof(v_g) = 'object' and nullif(v_g->>'name','') is not null then
    insert into public.guardians(student_id, name, relation, phone, whatsapp, is_primary)
    values (v_student, v_g->>'name', nullif(v_g->>'relation',''), nullif(v_g->>'phone',''),
            nullif(v_g->>'whatsapp',''), true);
  end if;

  return jsonb_build_object(
    'student_id', v_student, 'enrollment_id', v_enroll, 'gr_no', v_gr, 'roll_no', v_roll);
end;
$$;

-- Change a student's status (struck off / withdrawn / graduated / reinstated) and
-- reflect it on the current session's enrollment. Significant action → owner/
-- principal only (separation of duties). Never physically deletes.
create or replace function public.fn_set_student_status(
  p_student_id uuid, p_status public.student_status, p_reason text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only owner/principal may change a student''s status';
  end if;
  perform public.assert_own('students', p_student_id);

  update public.students
    set status = p_status,
        notes = case when nullif(p_reason,'') is null then notes
                     else coalesce(notes || E'\n', '') || 'Status → ' || p_status::text || ': ' || p_reason end
    where id = p_student_id;

  -- mirror onto the current-session enrollment (withdrawn maps to 'left')
  if p_status <> 'active' then
    update public.enrollments e
      set status = (case p_status
                      when 'struck_off' then 'struck_off'
                      when 'graduated'  then 'graduated'
                      when 'withdrawn'  then 'left'
                      else 'active' end)::public.enrollment_status
      from public.academic_sessions s
      where e.student_id = p_student_id and e.session_id = s.id and s.is_current;
  else
    update public.enrollments e
      set status = 'active'
      from public.academic_sessions s
      where e.student_id = p_student_id and e.session_id = s.id and s.is_current
        and e.status in ('struck_off', 'left');
  end if;
end;
$$;

grant execute on function public.fn_admit_student(jsonb) to authenticated;
grant execute on function public.fn_set_student_status(uuid, public.student_status, text) to authenticated;
