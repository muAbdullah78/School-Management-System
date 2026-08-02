-- =============================================================================
-- Dashboard rollup — one round-trip for the home tiles. SECURITY DEFINER so the
-- counts are school-wide regardless of the caller's row visibility, but the
-- finance figures (collected / outstanding / defaulters) are returned only to
-- finance-capable roles; teachers get nulls and the UI hides those tiles.
-- =============================================================================

create or replace function public.fn_dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_session uuid := (select current_session_id from public.school_settings where id = 1);
  v_finance boolean := public.has_role('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
begin
  if not public.has_role('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  select count(*) into v_active
  from public.enrollments e
  where e.session_id = v_session and e.status = 'active';

  select
    count(*) filter (where ad.status = 'present'),
    count(*) filter (where ad.status = 'absent'),
    count(*) filter (where ad.status = 'leave'),
    count(*) filter (where ad.status = 'late'),
    count(*) filter (where ad.status = 'half_day'),
    count(*)
  into v_present, v_absent, v_leave, v_late, v_half, v_marked
  from public.attendance_daily ad
  join public.enrollments e on e.id = ad.enrollment_id
  where ad.attendance_date = current_date and e.session_id = v_session;

  select count(*) into v_new_admissions
  from public.students s
  where date_trunc('month', s.created_at) = date_trunc('month', current_date);

  if v_finance then
    select coalesce(sum(amount), 0) into v_today
    from public.payments where status = 'verified' and created_at::date = current_date;

    select coalesce(sum(amount), 0) into v_month
    from public.payments
    where status = 'verified' and date_trunc('month', created_at) = date_trunc('month', current_date);

    -- one student_balance() call per active student, positive balances only
    select coalesce(sum(b.bal), 0), count(*) into v_outstanding, v_defaulters
    from public.enrollments e
    join lateral (select public.student_balance(e.student_id) as bal) b on true
    where e.session_id = v_session and e.status = 'active' and b.bal > 0;
  end if;

  return jsonb_build_object(
    'active_students', coalesce(v_active, 0),
    'new_admissions_month', coalesce(v_new_admissions, 0),
    'attendance', jsonb_build_object(
      'marked', coalesce(v_marked, 0), 'present', coalesce(v_present, 0),
      'absent', coalesce(v_absent, 0), 'leave', coalesce(v_leave, 0),
      'late', coalesce(v_late, 0), 'half_day', coalesce(v_half, 0)),
    'finance_visible', v_finance,
    'collected_today', v_today,
    'collected_month', v_month,
    'outstanding', v_outstanding,
    'defaulters', v_defaulters
  );
end;
$$;

grant execute on function public.fn_dashboard_summary() to authenticated;
