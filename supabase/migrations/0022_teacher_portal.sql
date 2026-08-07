-- =============================================================================
-- Teacher portal (same codebase, teacher-role view):
--   * teacher_assignments — WHICH class/section a teacher owns this session. The
--     scoping backbone: a teacher may only mark attendance / enter test marks for
--     a class they are assigned to. Supports section-level and whole-class
--     (section_id null) assignment.
--   * staff_attendance — the teacher's OWN daily attendance (append-only, one row
--     per staff per day, audited), recorded by scanning the school QR after login.
--   * staff_checkin_codes — rotatable codes the principal prints as a QR. The QR
--     is a deep-link the phone camera opens; integrity = login + SERVER clock +
--     an optional GPS geofence. A photographed code still needs a valid login and
--     (if the geofence is on) being physically at school.
-- =============================================================================

-- --- Teacher assignments ----------------------------------------------------
create table if not exists public.teacher_assignments (
  id         uuid primary key default gen_random_uuid(),
  staff_id   uuid not null references public.staff(id) on delete cascade,
  session_id uuid not null references public.academic_sessions(id),
  class_id   uuid not null references public.classes(id),
  section_id uuid references public.sections(id),      -- null = whole class
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (staff_id, session_id, class_id, section_id)
);
create index if not exists idx_teacher_assign_staff on public.teacher_assignments (staff_id, session_id);
create index if not exists idx_teacher_assign_class on public.teacher_assignments (session_id, class_id, section_id);

alter table public.teacher_assignments enable row level security;
create policy teacher_assign_select on public.teacher_assignments for select to authenticated using (true);
create policy teacher_assign_write on public.teacher_assignments for all to authenticated
  using (public.has_role('owner','principal','admin_clerk'))
  with check (public.has_role('owner','principal','admin_clerk'));
create trigger trg_audit_teacher_assign after insert or update or delete on public.teacher_assignments
  for each row execute function public.audit_trigger();

-- helper: the staff row for the current login (null if unlinked)
create or replace function public.my_staff_id() returns uuid
language sql stable security definer set search_path = public as $$
  select staff_id from public.profiles where id = auth.uid();
$$;

-- --- Check-in codes (created before staff_attendance, which FKs to it) ------
create table if not exists public.staff_checkin_codes (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  label      text,
  valid_from date,
  valid_to   date,
  active     boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
alter table public.staff_checkin_codes enable row level security;
create policy checkin_codes_select on public.staff_checkin_codes for select to authenticated
  using (public.has_role('owner','principal','admin_clerk'));
create policy checkin_codes_write on public.staff_checkin_codes for all to authenticated
  using (public.has_role('owner','principal','admin_clerk'))
  with check (public.has_role('owner','principal','admin_clerk'));

-- --- Staff self-attendance --------------------------------------------------
create table if not exists public.staff_attendance (
  id              uuid primary key default gen_random_uuid(),
  staff_id        uuid not null references public.staff(id) on delete cascade,
  attendance_date date not null,
  status          public.attendance_status not null default 'present',
  checked_at      timestamptz,                 -- server timestamp of the scan
  code_id         uuid references public.staff_checkin_codes(id),
  source          text not null default 'qr',  -- 'qr' | 'manual'
  device          text,
  reason          text,
  marked_by       uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  unique (staff_id, attendance_date)
);
create index if not exists idx_staff_att_staff on public.staff_attendance (staff_id, attendance_date);

alter table public.staff_attendance enable row level security;
-- read: admins see all; a teacher sees only their own
create policy staff_att_select on public.staff_attendance for select to authenticated
  using (public.has_role('owner','principal','admin_clerk') or staff_id = public.my_staff_id());
-- no direct insert/update policy → all writes go through the SECURITY DEFINER
-- functions below (append-only, like payments).
create trigger trg_audit_staff_att after insert or update or delete on public.staff_attendance
  for each row execute function public.audit_trigger();

-- --- Geofence settings (optional integrity control) -------------------------
alter table public.school_settings add column if not exists geofence_enabled boolean not null default false;
alter table public.school_settings add column if not exists geo_lat double precision;
alter table public.school_settings add column if not exists geo_lng double precision;
alter table public.school_settings add column if not exists geo_radius_m integer not null default 200;

-- --- Scoping helper ---------------------------------------------------------
-- May the caller manage (roster/mark) this class/section? Admin roles always;
-- teachers only where they hold an assignment (a whole-class assignment, i.e.
-- section_id null, covers every section of that class).
create or replace function public.fn_may_manage_class(p_session uuid, p_class uuid, p_section uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('owner','principal','admin_clerk')
    or exists (
      select 1 from public.teacher_assignments ta
      join public.staff st on st.id = ta.staff_id
      join public.profiles pr on pr.staff_id = st.id
      where pr.id = auth.uid()
        and ta.session_id = p_session
        and ta.class_id = p_class
        and (ta.section_id is not distinct from p_section or ta.section_id is null)
    );
$$;

-- The caller's assignments for the current session (drives the "My Class" home).
create or replace function public.fn_my_assignments()
returns table(class_id uuid, class_name text, level_order integer, section_id uuid, section_name text)
language sql stable security definer set search_path = public as $$
  select ta.class_id, c.name, c.level_order, ta.section_id, sec.name
  from public.teacher_assignments ta
  join public.academic_sessions s on s.id = ta.session_id and s.is_current
  join public.classes c on c.id = ta.class_id
  left join public.sections sec on sec.id = ta.section_id
  where ta.staff_id = public.my_staff_id()
  order by c.level_order, sec.name nulls first;
$$;

-- --- Attendance functions: add teacher scope --------------------------------
create or replace function public.fn_section_roster(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns table(
  enrollment_id uuid, student_id uuid, full_name text, father_name text,
  roll_no text, status public.attendance_status, is_locked boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to view the attendance roster';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only view your assigned class';
  end if;
  return query
    select e.id, s.id, s.full_name, s.father_name, e.roll_no,
           ad.status, coalesce(ad.is_locked, false)
    from public.enrollments e
    join public.students s on s.id = e.student_id
    left join public.attendance_daily ad
      on ad.enrollment_id = e.id and ad.attendance_date = p_date
    where e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id
      and e.status = 'active'
      and s.deleted_at is null
    order by coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

create or replace function public.fn_mark_attendance(p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_total  integer;
  v_marked integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to mark attendance';
  end if;
  if p_marks is null or jsonb_typeof(p_marks) <> 'array' then
    raise exception 'p_marks must be a JSON array';
  end if;

  -- teacher scope: every enrolment must be in a class the caller is assigned to
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
    insert into public.attendance_daily as ad (enrollment_id, attendance_date, status, marked_by)
    select enrollment_id, p_date, status, v_actor from input
    on conflict (enrollment_id, attendance_date) do update
      set status = excluded.status,
          marked_by = excluded.marked_by,
          corrected_from = case when ad.status is distinct from excluded.status
                                then ad.status else ad.corrected_from end
      where not ad.is_locked
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to finalize attendance';
  end if;
  if not public.fn_may_manage_class(p_session_id, p_class_id, p_section_id) then
    raise exception 'You can only finalize your assigned class';
  end if;
  update public.attendance_daily ad
    set is_locked = true
    from public.enrollments e
    where ad.enrollment_id = e.id
      and ad.attendance_date = p_date
      and e.session_id = p_session_id
      and e.class_id = p_class_id
      and e.section_id is not distinct from p_section_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- --- Check-in code generation + scan ---------------------------------------
create or replace function public.fn_generate_checkin_code(
  p_label text, p_valid_from date, p_valid_to date, p_deactivate_others boolean default true
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_code text; v_id uuid;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to generate a check-in code';
  end if;
  if p_deactivate_others then
    update public.staff_checkin_codes set active = false where active;
  end if;
  v_code := replace(gen_random_uuid()::text, '-', '');
  insert into public.staff_checkin_codes(code, label, valid_from, valid_to, active, created_by)
  values (v_code, nullif(btrim(p_label),''), p_valid_from, p_valid_to, true, auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'code', v_code);
end;
$$;

-- Record the caller's own attendance for today by scanning the school QR.
-- Idempotent per (staff, day). Server clock only; optional geofence.
create or replace function public.fn_staff_check_in(
  p_code text, p_lat double precision default null, p_lng double precision default null, p_device text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff  uuid := public.my_staff_id();
  v_code   record;
  v_today  date := current_date;
  v_exist  record;
  v_geo_on boolean; v_lat double precision; v_lng double precision; v_radius integer; v_dist double precision;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if v_staff is null then
    raise exception 'Your login is not linked to a staff record — ask the principal to link it in Staff.';
  end if;

  select * into v_code from public.staff_checkin_codes where code = p_code and active limit 1;
  if not found then raise exception 'Invalid or inactive check-in code'; end if;
  if v_code.valid_from is not null and v_today < v_code.valid_from then raise exception 'This check-in code is not active yet'; end if;
  if v_code.valid_to  is not null and v_today > v_code.valid_to  then raise exception 'This check-in code has expired'; end if;

  select geofence_enabled, geo_lat, geo_lng, geo_radius_m
    into v_geo_on, v_lat, v_lng, v_radius from public.school_settings where id = 1;
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

  select * into v_exist from public.staff_attendance where staff_id = v_staff and attendance_date = v_today;
  if found then
    return jsonb_build_object('status', 'already', 'checked_at', v_exist.checked_at, 'attendance_status', v_exist.status);
  end if;
  insert into public.staff_attendance(staff_id, attendance_date, status, checked_at, code_id, source, device)
  values (v_staff, v_today, 'present', now(), v_code.id, 'qr', nullif(btrim(p_device),''));
  return jsonb_build_object('status', 'ok', 'checked_at', now());
end;
$$;

-- Admin: manually set/correct a staff member's attendance for a day (leave, absent,
-- or fixing a missed scan). Append/replace one row; audited.
create or replace function public.fn_set_staff_attendance(
  p_staff_id uuid, p_date date, p_status public.attendance_status, p_reason text
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set staff attendance';
  end if;
  insert into public.staff_attendance(staff_id, attendance_date, status, source, reason, marked_by, checked_at)
  values (p_staff_id, p_date, p_status, 'manual', nullif(btrim(p_reason),''), auth.uid(), now())
  on conflict (staff_id, attendance_date) do update
    set status = excluded.status, source = 'manual', reason = excluded.reason,
        marked_by = excluded.marked_by;
end;
$$;

-- Staff attendance summary over a window (same shape as the student summary).
create or replace function public.fn_staff_attendance_summary(
  p_staff_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (public.has_role('owner','principal','admin_clerk') or p_staff_id = public.my_staff_id()) then
    raise exception 'Not permitted';
  end if;
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    'present_pct', case when count(*) = 0 then null else
        round(100.0 * (count(*) filter (where status in ('present','late'))
              + 0.5 * count(*) filter (where status = 'half_day')) / count(*), 1) end
  ) into v
  from public.staff_attendance
  where staff_id = p_staff_id and attendance_date between p_from and p_to;
  return v;
end;
$$;

grant execute on function public.my_staff_id() to authenticated;
grant execute on function public.fn_may_manage_class(uuid, uuid, uuid) to authenticated;
grant execute on function public.fn_my_assignments() to authenticated;
grant execute on function public.fn_generate_checkin_code(text, date, date, boolean) to authenticated;
grant execute on function public.fn_staff_check_in(text, double precision, double precision, text) to authenticated;
grant execute on function public.fn_set_staff_attendance(uuid, date, public.attendance_status, text) to authenticated;
grant execute on function public.fn_staff_attendance_summary(uuid, date, date) to authenticated;
