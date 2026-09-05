-- =============================================================================
-- 0099 — "How many children are here" had three answers
--
-- HOW THIS WAS FOUND
--
-- The same way as 0098: one school, seeded to be awkward, and every screen
-- asked the same question in the same transaction.
--
--   Three children enrolled normally
--   One admitted this morning, class not chosen yet
--   One whose record was removed in error, enrolment untouched
--
--   Dashboard tile, "Students"          4
--   Students screen, rows listed        4
--   Plan limit counter                  3
--
-- The two 4s are not agreement. They are two different wrong answers that
-- happen to collide on this fixture: the dashboard counts the removed child and
-- misses the unenrolled one, the Students screen does the exact opposite. On a
-- school with only one of the two situations they differ on screen, and there is
-- nothing anywhere to explain which is right.
--
-- THE THREE DEFINITIONS
--
--   fn_count_students        active enrolment in the current session, student
--   (the plan limit)         active, not removed. Documented in 0026 as "the
--                            same number a principal would say out loud", and
--                            it is the one that decides whether a school can
--                            admit another child, so it is the one that has to
--                            be right.
--
--   fn_dashboard_summary     active enrolment in the current session. Does not
--   (the tile)               look at the student row at all. 0042 fixed exactly
--                            this omission on "New this month" -- it added
--                            `deleted_at is null` there -- and left the tile
--                            beside it counting removed children.
--
--   fn_student_list          active student, not removed, WITH OR WITHOUT an
--   (the Students screen)    enrolment. Correct for a roster: a child admitted
--                            an hour ago has to appear somewhere.
--
-- WHY THE UNENROLLED CHILD IS THE ONE THAT MATTERS
--
-- `fn_admit_student` always creates an enrolment, so this is not a state the
-- admission form can produce. Rollover is. A child not carried into the new
-- session keeps `students.status = 'active'` and has no enrolment in the
-- current one, and from that moment they are invisible to nearly everything:
--
--   * no challan, because billing walks enrolments
--   * no attendance, because the register walks enrolments
--   * no result card, for the same reason
--   * not in the dashboard count, and not in the plan count
--   * NOT in the reconciliation screen's "uninvoiced" list either, because that
--     list also walks active enrolments -- so the one report built to catch a
--     child who is not being billed cannot see this child at all
--
-- They appear on the Students screen with an empty class, which reads as a
-- formatting gap rather than as a child who is about to be forgotten for a
-- term. A school finds out in March when a parent asks why no fee slip ever
-- came.
--
-- WHAT THIS MIGRATION DOES
--
--   1. The dashboard tile IS the plan counter: `fn_dashboard_summary` calls
--      `fn_count_students` rather than carrying a second copy of the rule.
--   2. The dashboard returns `students_without_a_class`, so the difference
--      between the tile and the Students screen is a number the school is shown
--      rather than one they have to notice.
--   3. Today's attendance excludes removed students, so `marked` can never
--      exceed a headcount that now excludes them.
--
-- supabase/tests/one_number.sql asserts all three counts agree, and that a
-- child left out of a rollover is reported rather than lost.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_dashboard_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
  -- may_view, and NOT the plain role check. 0059 rewrote every READ gate in the
  -- schema to go through one helper, programmatically, and warned in its own
  -- header that retyping a function body by hand is how that gets silently
  -- reverted. The first draft of this migration did exactly that on all three
  -- functions it touches; supabase/repair/detect.sql caught it. Uncaught, it
  -- would have shut the observer role out of the money tiles all over again.
  v_finance boolean := public.may_view('owner','principal','admin_clerk','accountant','readonly');
  v_active  int;
  v_no_class int;
  v_present int; v_absent int; v_leave int; v_late int; v_half int; v_marked int;
  v_today numeric; v_month numeric; v_outstanding numeric; v_defaulters int;
  v_new_admissions int;
  v_billed_month int;
  v_classes_no_fee int;
  v_month_start date := date_trunc('month', current_date)::date;
begin
  if not public.may_view('owner','principal','admin_clerk','accountant',
                         'class_teacher','subject_teacher','readonly') then
    raise exception 'Not permitted';
  end if;

  -- ONE definition, shared with the plan limit. Previously this counted
  -- enrolments without looking at the student row, so a record removed in error
  -- stayed in the tile while dropping out of the licence count and off the
  -- Students screen.
  v_active := public.fn_count_students(v_school);

  -- The children the tile cannot see. An active student with no active
  -- enrolment in the current session gets no challan, no register entry and no
  -- result card, and no other screen in the product reports them.
  select count(*) into v_no_class
  from public.students s
  where s.school_id = v_school
    and s.status = 'active'
    and s.deleted_at is null
    and not exists (
      select 1 from public.enrollments e
      where e.student_id = s.id
        and e.session_id = v_session
        and e.status = 'active');

  -- Joined to students so a removed child cannot be marked present against a
  -- headcount that no longer includes them. "42 present of 40 on the roll" is
  -- the kind of arithmetic that makes a school stop trusting the whole page.
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
  join public.students s on s.id = e.student_id
  where ad.school_id = v_school
    and ad.attendance_date = current_date
    and e.session_id = v_session
    and s.deleted_at is null;

  select count(*) into v_new_admissions
  from public.students s
  where s.school_id = v_school
    and s.deleted_at is null
    and s.created_at >= v_month_start
    and s.created_at < (v_month_start + interval '1 month');

  if v_finance then
    select coalesce(sum(p.amount), 0) into v_today
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= date_trunc('day', now())
      and p.created_at <  date_trunc('day', now()) + interval '1 day';

    select coalesce(sum(p.amount), 0) into v_month
    from public.payments p
    where p.school_id = v_school
      and p.status = 'verified'
      and p.created_at >= v_month_start
      and p.created_at <  (v_month_start + interval '1 month');

    select coalesce(sum(b.bal), 0), count(*) into v_outstanding, v_defaulters
    from public.enrollments e
    join lateral (select public.student_balance(e.student_id) as bal) b on true
    where e.school_id = v_school
      and e.session_id = v_session
      and e.status = 'active'
      and b.bal > 0;

    select count(distinct i.student_id) into v_billed_month
    from public.invoices i
    where i.school_id = v_school
      and i.period_month = v_month_start
      and i.status <> 'void'
      and coalesce((select sum(case when l.is_discount then -l.amount else l.amount end)
                      from public.invoice_lines l where l.invoice_id = i.id), 0) > 0;

    select count(*) into v_classes_no_fee
    from public.classes c
    where c.school_id = v_school
      and exists (select 1 from public.enrollments e
                   where e.class_id = c.id and e.session_id = v_session and e.status = 'active')
      and not exists (select 1 from public.fee_structures fs
                       where fs.class_id = c.id and fs.session_id = v_session and fs.amount > 0);
  end if;

  return jsonb_build_object(
    'active_students', coalesce(v_active, 0),
    'students_without_a_class', coalesce(v_no_class, 0),
    'new_admissions_month', coalesce(v_new_admissions, 0),
    'attendance', jsonb_build_object(
      'marked', coalesce(v_marked, 0), 'present', coalesce(v_present, 0),
      'absent', coalesce(v_absent, 0), 'leave', coalesce(v_leave, 0),
      'late', coalesce(v_late, 0), 'half_day', coalesce(v_half, 0)),
    'finance_visible', v_finance,
    'collected_today', coalesce(v_today, 0),
    'collected_month', coalesce(v_month, 0),
    'outstanding', coalesce(v_outstanding, 0),
    'defaulters', coalesce(v_defaulters, 0),
    'billed_students_month', coalesce(v_billed_month, 0),
    'classes_without_fee', coalesce(v_classes_no_fee, 0),
    'session_set', v_session is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- Who they are, not just how many
--
-- A count on a tile is a prompt, not an answer. This is the list behind it, so
-- the office can put each child into a class instead of hunting the Students
-- screen for blank class names.
--
-- `is_staff` rather than the finance roles: a class teacher noticing that a
-- child in their room is on no register is exactly who should be able to see
-- this, and it carries no money.
-- ---------------------------------------------------------------------------
create or replace function public.fn_students_without_a_class()
returns table (
  student_id     uuid,
  full_name      text,
  gr_no          text,
  father_name    text,
  admission_date date,
  last_class     text,
  last_session   text
) language plpgsql stable security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_session uuid := (select current_session_id from public.school_settings
                      where school_id = v_school);
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select s.id, s.full_name, s.gr_no, s.father_name, s.admission_date,
         -- Where they were last seen, which is what tells the office whether
         -- this is a new admission or a child a rollover left behind.
         (select c.name from public.enrollments e
            join public.classes c on c.id = e.class_id
            join public.academic_sessions ses on ses.id = e.session_id
           where e.student_id = s.id and e.school_id = v_school
           order by ses.created_at desc, e.created_at desc limit 1),
         (select ses.name from public.enrollments e
            join public.academic_sessions ses on ses.id = e.session_id
           where e.student_id = s.id and e.school_id = v_school
           order by ses.created_at desc, e.created_at desc limit 1)
  from public.students s
  where s.school_id = v_school
    and s.status = 'active'
    and s.deleted_at is null
    and not exists (
      select 1 from public.enrollments e
      where e.student_id = s.id
        and e.session_id = v_session
        and e.status = 'active')
  order by s.admission_date desc nulls last, s.full_name;
end;
$$;

-- Postgres grants EXECUTE on a new function to PUBLIC, and `anon` is a member
-- of PUBLIC, so a new function is reachable without a login until this line.
revoke all on function public.fn_students_without_a_class() from public, anon;
grant execute on function public.fn_students_without_a_class() to authenticated;
