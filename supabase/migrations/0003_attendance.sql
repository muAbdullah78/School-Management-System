-- =============================================================================
-- Attendance module — daily marking, finalize/lock, and per-student summary,
-- as server-side Postgres functions (SECURITY DEFINER + explicit role guards).
--
-- Model (see docs/02-DATA-MODEL.md):
--   * attendance_daily holds ONE row per (enrollment, date) — unique constraint.
--   * Marking is idempotent: re-marking a date UPSERTs the same row.
--   * Finalizing LOCKS the day's rows (is_locked=true); a locked row is immutable
--     to normal users (RLS blocks the UPDATE) and these functions skip it too.
--   * A status change on an unlocked row snapshots the previous value into
--     corrected_from, for the audit trail.
--
-- Enum gotcha: text taken from jsonb (or a CASE) must be cast explicitly to
-- ::public.attendance_status — Postgres will not do it implicitly.
--
-- All four functions are SECURITY DEFINER (they must read across sections and,
-- for finalize, set is_locked which RLS forbids to normal users), so each one
-- carries its own role guard.
-- =============================================================================

-- Roster for one section on one date: every active enrollment with that day's
-- status (null = unmarked) and whether the day is already locked. Passing a null
-- p_section_id matches enrollments that have no section (small/ungrouped classes).
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
    -- sort by the numeric part of the roll number (so 10 follows 9), then name
    order by coalesce(nullif(regexp_replace(coalesce(e.roll_no, ''), '[^0-9]', '', 'g'), '')::int, 2147483647),
             s.full_name;
end;
$$;

-- Mark (or re-mark) attendance for a set of enrollments on one date. Idempotent
-- per (enrollment, date); LOCKED rows are skipped, never touched. Returns a
-- {marked, skipped, total} tally. p_marks is a jsonb array of objects shaped
-- { "enrollment_id": <uuid>, "status": <attendance_status> }.
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

  select count(distinct (e->>'enrollment_id')) into v_total
  from jsonb_array_elements(p_marks) e;

  with input as (
    -- de-dup defensively: one status per enrollment, even if the client repeats
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
      where not ad.is_locked          -- a locked day is immutable → skip it
    returning 1
  )
  select count(*) into v_marked from upserted;

  return jsonb_build_object('marked', v_marked, 'skipped', v_total - v_marked, 'total', v_total);
end;
$$;

-- Finalize a section's day: lock every attendance row so it can no longer be
-- edited. Returns the number of rows locked. Re-finalizing is harmless.
create or replace function public.fn_finalize_attendance(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_date date
) returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.has_role('owner','principal','admin_clerk','class_teacher','subject_teacher') then
    raise exception 'Not permitted to finalize attendance';
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

-- Per-student attendance summary over a date window, for the profile page.
-- Working-day % = (present + late + ½·half_day) / marked days. Holidays are
-- simply dates with no row, so the % is over MARKED days only (simple for v1).
create or replace function public.fn_attendance_summary(
  p_enrollment_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    'present_pct', case when count(*) = 0 then null else
        round(100.0 * (
          count(*) filter (where status in ('present','late'))
          + 0.5 * count(*) filter (where status = 'half_day')
        ) / count(*), 1) end
  ) into v
  from public.attendance_daily
  where enrollment_id = p_enrollment_id
    and attendance_date between p_from and p_to;
  return v;
end;
$$;

grant execute on function public.fn_section_roster(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_mark_attendance(date, jsonb) to authenticated;
grant execute on function public.fn_finalize_attendance(uuid, uuid, uuid, date) to authenticated;
grant execute on function public.fn_attendance_summary(uuid, date, date) to authenticated;
