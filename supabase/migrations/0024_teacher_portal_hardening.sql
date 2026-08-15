-- =============================================================================
-- Hardening from the adversarial review of the teacher portal (0022/0023):
--   1. Scoping was only enforced inside the RPCs — but the blanket table grant
--      (0001) + role-only RLS let a teacher write attendance_daily / mark_entries
--      DIRECTLY via PostgREST, bypassing fn_may_manage_class. Revoke direct DML
--      so writes MUST go through the scoped SECURITY DEFINER functions.
--   2. profiles.staff_id became authorization-critical (my_staff_id → scope +
--      check-in identity), but guard_profile_role only protected `role`. A
--      teacher could repoint their own staff_id and inherit another teacher's
--      class + attendance identity. Guard staff_id too.
--   3. Test marks-entry now also validates every enrolment is in the test's class.
--   4. Check-in: use Pakistan time for "today" and make it race-safe.
--   5. Atomic class-teacher assignment (assignment row + class_teacher_id in one
--      transaction) and a backfill of existing class_teacher_id → assignments.
--   6. teacher_assignments is no longer world-readable.
-- =============================================================================

-- 1. Direct DML on the marked tables is revoked; the definer RPCs still work
--    (they run as the function owner and bypass grants + RLS).
revoke insert, update, delete on public.attendance_daily from authenticated;
revoke insert, update, delete on public.mark_entries    from authenticated;

-- 2. Guard staff_id like role — only owner/principal may change either.
create or replace function public.guard_profile_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may change a user role';
  end if;
  if new.staff_id is distinct from old.staff_id and not public.has_role('owner', 'principal') then
    raise exception 'Only owner/principal may relink a login to a staff record';
  end if;
  return new;
end;
$$;

-- 3. Test marks: reject/ignore any enrolment outside the test's class.
create or replace function public.fn_enter_assessment_marks(p_assessment_id uuid, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_max    numeric;
  v_locked boolean;
  v_session uuid; v_class uuid; v_section uuid;
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to enter marks';
  end if;
  perform public.assert_own('assessments', p_assessment_id);
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;
  select max_marks, is_locked, session_id, class_id, section_id
    into v_max, v_locked, v_session, v_class, v_section
  from public.assessments where id = p_assessment_id;
  if v_max is null then raise exception 'Assessment not found'; end if;
  if not public.fn_may_manage_class(v_session, v_class, v_section) then
    raise exception 'You can only enter marks for your assigned class';
  end if;
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

  with input as (
    select distinct on (q.enrollment_id) q.enrollment_id, q.marks, q.is_absent
    from (
      select (e->>'enrollment_id')::uuid as enrollment_id,
             nullif(e->>'marks', '')::numeric as marks,
             coalesce((e->>'is_absent')::boolean, false) as is_absent
      from jsonb_array_elements(p_marks) e
    ) q
    -- only enrolments that actually belong to this test's class/section
    join public.enrollments en on en.id = q.enrollment_id
      and en.session_id = v_session and en.class_id = v_class
      and (v_section is null or en.section_id = v_section)
    order by q.enrollment_id
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

  select count(distinct (e->>'enrollment_id')) into v_total from jsonb_array_elements(p_marks) e;
  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- 4. Check-in: Pakistan-time "today" + race-safe insert.
create or replace function public.fn_staff_check_in(
  p_code text, p_lat double precision default null, p_lng double precision default null, p_device text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff  uuid := public.my_staff_id();
  v_code   record;
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_exist  record;
  v_geo_on boolean; v_lat double precision; v_lng double precision; v_radius integer; v_dist double precision;
  v_new    uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if v_staff is null then
    raise exception 'Your login is not linked to a staff record — ask the principal to link it in Staff.';
  end if;

  -- Scope the lookup to the caller's school. Codes are only unique per school
  -- now, so without this a teacher could check in against another school's code
  -- — and `limit 1` would pick between duplicates arbitrarily.
  select * into v_code from public.staff_checkin_codes
   where code = p_code and active and school_id = public.current_school_id()
   limit 1;
  if not found then raise exception 'Invalid or inactive check-in code'; end if;
  if v_code.valid_from is not null and v_today < v_code.valid_from then raise exception 'This check-in code is not active yet'; end if;
  if v_code.valid_to  is not null and v_today > v_code.valid_to  then raise exception 'This check-in code has expired'; end if;

  select geofence_enabled, geo_lat, geo_lng, geo_radius_m
    into v_geo_on, v_lat, v_lng, v_radius from public.school_settings where school_id = public.current_school_id();
  if coalesce(v_geo_on, false) then
    if p_lat is null or p_lng is null then raise exception 'Location is required to check in — enable location and try again.'; end if;
    if v_lat is null or v_lng is null then raise exception 'School location is not set — ask the principal to set it in Settings.'; end if;
    v_dist := 2 * 6371000 * asin(least(1, sqrt(
      power(sin(radians((p_lat - v_lat) / 2)), 2)
      + cos(radians(v_lat)) * cos(radians(p_lat)) * power(sin(radians((p_lng - v_lng) / 2)), 2))));
    if v_dist > coalesce(v_radius, 200) then
      raise exception 'You are too far from the school to check in (about % m away).', round(v_dist);
    end if;
  end if;

  insert into public.staff_attendance(staff_id, attendance_date, status, checked_at, code_id, source, device)
  values (v_staff, v_today, 'present', now(), v_code.id, 'qr', nullif(btrim(p_device),''))
  on conflict (staff_id, attendance_date) do nothing
  returning id into v_new;

  if v_new is null then
    select * into v_exist from public.staff_attendance where staff_id = v_staff and attendance_date = v_today;
    return jsonb_build_object('status', 'already', 'checked_at', v_exist.checked_at, 'attendance_status', v_exist.status);
  end if;
  return jsonb_build_object('status', 'ok', 'checked_at', now());
end;
$$;

-- 5a. Atomic class-teacher assignment: assignment row + class_teacher_id mirror.
create or replace function public.fn_set_class_teacher(
  p_staff_id uuid, p_session_id uuid, p_class_id uuid, p_section_id uuid
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to assign class teachers';
  end if;
  -- Guard every id: the DELETE below is scoped only by session/class, so
  -- another school's ids would wipe their teacher assignments.
  perform public.assert_own('staff', p_staff_id);
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  delete from public.teacher_assignments
   where session_id = p_session_id and class_id = p_class_id
     and section_id is not distinct from p_section_id;
  if p_section_id is not null then
    update public.sections set class_teacher_id = p_staff_id where id = p_section_id;
  end if;
  if p_staff_id is not null then
    insert into public.teacher_assignments(staff_id, session_id, class_id, section_id, created_by)
    values (p_staff_id, p_session_id, p_class_id, p_section_id, auth.uid())
    on conflict (staff_id, session_id, class_id, section_id) do nothing;
  end if;
end;
$$;

-- 5b. Backfill existing section class-teachers into assignments (current session),
--     so teachers assigned the old way keep working after this deploy.
insert into public.teacher_assignments(staff_id, session_id, class_id, section_id)
select sec.class_teacher_id, s.id, sec.class_id, sec.id
from public.sections sec
join public.academic_sessions s on s.is_current
where sec.class_teacher_id is not null
on conflict (staff_id, session_id, class_id, section_id) do nothing;

-- 6. teacher_assignments: admins see all; a teacher sees only their own.
drop policy if exists teacher_assign_select on public.teacher_assignments;
create policy teacher_assign_select on public.teacher_assignments for select to authenticated
  using (public.has_role('owner','principal','admin_clerk') or staff_id = public.my_staff_id());

grant execute on function public.fn_set_class_teacher(uuid, uuid, uuid, uuid) to authenticated;
