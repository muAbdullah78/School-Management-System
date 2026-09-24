-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0146_the_dashboard_draws_what_it_knows.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0146: the dashboard draws what it knows.
--
-- A school shown the software liked the logic and disliked the screens: every
-- figure was a bare number, and a principal reading "Attendance today 82%" has
-- no way to see which classes are missing from it, or whether June's fees came
-- in. The numbers were right. Nothing showed their shape.
--
-- Two new reads feed the charts. Neither replaces anything.
--
--   fn_dashboard_trends()           today's register class by class, the last
--                                   fourteen school days, the last six billing
--                                   months (paid, overdue, not yet due), where
--                                   the dues sit by class, and the staff room
--                                   today.
--   fn_student_marks_trend(enrol)   every class test of the session for one
--                                   child, as a percentage, for the line on the
--                                   profile.
--
-- WHY A NEW FUNCTION AND NOT A FIELD ON fn_dashboard_summary. That function is
-- reproduced whole by anything that touches it (0042, 0099, 0140), and 0140's
-- own header records a careful fix being silently reverted that way. A chart
-- read that lives on its own cannot revert the tiles, and a tile fix cannot
-- revert the charts.
--
-- EVERY FIGURE AGREES WITH A FIGURE ALREADY ON THE PAGE, by construction:
--
--   * the per-section roll counts active enrolments in the is_current session
--     with the filters fn_count_students uses, so the sections sum to the
--     Active students tile;
--   * the percentages go through fn__attendance_pct, the one attendance rule
--     (0097), so the trend line and the tile cannot disagree about a half day;
--   * dues by class is fn_dashboard_summary's own outstanding query grouped by
--     class, so the bars sum to the Outstanding tile.
--
-- The billing months deliberately do NOT sum to Outstanding: they are what each
-- month's challans raised and what has been paid against them, while
-- Outstanding also carries adjustments and balances brought in from before the
-- software. The screen says so under the chart.
--
-- NOTHING HERE IS INVENTED. A school with no challans gets no months, a day
-- with no register gets no point, and the screen draws an honest empty state.
-- A dashboard that fills its gaps with sample figures is a dashboard somebody
-- will one day make a decision from.
-- =============================================================================

create or replace function public.fn_dashboard_trends()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school      uuid := public.current_school_id();
  v_today       date := (now() at time zone 'Asia/Karachi')::date;
  v_month_start date := date_trunc('month', (now() at time zone 'Asia/Karachi')::date)::date;
  v_session     uuid;
  v_sections    jsonb;
  v_trend       jsonb;
  v_months      jsonb;
  v_dues        jsonb;
  v_staff       jsonb;
begin
  if v_school is null
     or not public.may_view('owner', 'principal', 'admin_clerk', 'accountant', 'readonly') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- The session the Active students tile counts. fn_count_students joins on
  -- academic_sessions.is_current, so this does too: the sections below then
  -- sum to that tile exactly.
  select ses.id into v_session
    from public.academic_sessions ses
   where ses.school_id = v_school and ses.is_current
   limit 1;

  -- ---- today's register, one row per class and section ---------------------
  -- Unmarked sections first: the principal's question at 09:30 is "who has not
  -- done the register", and the answer should be at the top, not the bottom.
  select coalesce(jsonb_agg(jsonb_build_object(
           'class_id', x.class_id, 'class_name', x.class_name,
           'level_order', x.level_order,
           'section_id', x.section_id, 'section_name', x.section_name,
           'on_roll', x.on_roll, 'marked', x.marked,
           'present', x.present, 'late', x.late, 'half_day', x.half_day,
           'leave', x.leave, 'absent', x.absent)
         order by (x.marked = 0) desc, x.level_order, x.class_name, x.section_name nulls first),
         '[]'::jsonb)
    into v_sections
    from (
      select c.id as class_id, c.name as class_name, c.level_order,
             sec.id as section_id, sec.name as section_name,
             count(*)::int as on_roll,
             count(ad.id)::int as marked,
             count(*) filter (where ad.status = 'present')::int  as present,
             count(*) filter (where ad.status = 'late')::int     as late,
             count(*) filter (where ad.status = 'half_day')::int as half_day,
             count(*) filter (where ad.status = 'leave')::int    as leave,
             count(*) filter (where ad.status = 'absent')::int   as absent
        from public.enrollments e
        join public.students s on s.id = e.student_id
                              and s.school_id = v_school
                              and s.status = 'active' and s.deleted_at is null
        join public.classes c on c.id = e.class_id and c.school_id = v_school
        left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
        left join public.attendance_daily ad on ad.enrollment_id = e.id
                                            and ad.school_id = v_school
                                            and ad.attendance_date = v_today
       where e.school_id = v_school
         and e.session_id = v_session
         and e.status = 'active'
       group by c.id, c.name, c.level_order, sec.id, sec.name
    ) x;

  -- ---- the last fourteen school days ----------------------------------------
  -- A "school day" is a date on which any register was marked. Calendar days
  -- would put Sundays and holidays on the line as zeros, and a line that dips
  -- to nothing every weekend reads as an attendance crisis every Monday.
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d.attendance_date, 'marked', d.marked,
           'present', d.present, 'late', d.late, 'half_day', d.half_day,
           'leave', d.leave, 'absent', d.absent,
           'pct', public.fn__attendance_pct(d.present, d.late, d.half_day, d.marked))
         order by d.attendance_date), '[]'::jsonb)
    into v_trend
    from (
      select ad.attendance_date,
             count(*)::int as marked,
             count(*) filter (where ad.status = 'present')::int  as present,
             count(*) filter (where ad.status = 'late')::int     as late,
             count(*) filter (where ad.status = 'half_day')::int as half_day,
             count(*) filter (where ad.status = 'leave')::int    as leave,
             count(*) filter (where ad.status = 'absent')::int   as absent
        from public.attendance_daily ad
        join public.enrollments e on e.id = ad.enrollment_id
                                 and e.school_id = v_school
                                 and e.session_id = v_session
       where ad.school_id = v_school
         and ad.attendance_date <= v_today
       group by ad.attendance_date
       order by ad.attendance_date desc
       limit 14
    ) d;

  -- ---- the last six billing months -------------------------------------------
  -- Per challan: what it raised (lines net of discount, plus any fine) and what
  -- verified payments have been allocated to it. What is still owed is split
  -- by the challan's own due date, because Rs 8,000 not yet paid on the 3rd of
  -- the month is not the same fact as Rs 8,000 not paid two months late, and a
  -- chart that paints both red teaches the principal to ignore the red.
  select coalesce(jsonb_agg(jsonb_build_object(
           'month', m.period_month, 'challans', m.challans,
           'billed', m.billed, 'paid', m.paid,
           'overdue', m.overdue, 'not_due', m.not_due)
         order by m.period_month), '[]'::jsonb)
    into v_months
    from (
      with inv as (
        select i.id, i.period_month, i.due_date, coalesce(i.fine, 0) as fine
          from public.invoices i
         where i.school_id = v_school
           and i.status <> 'void'
           and i.period_month is not null
           and i.period_month >= (v_month_start - interval '5 months')::date
           and i.period_month <= v_month_start
      ),
      net as (
        select l.invoice_id,
               sum(case when l.is_discount then -l.amount else l.amount end) as net
          from public.invoice_lines l
          join inv on inv.id = l.invoice_id
         where l.school_id = v_school
         group by l.invoice_id
      ),
      alloc as (
        select al.invoice_id, sum(al.amount) as paid
          from public.payment_allocations al
          join public.payments p on p.id = al.payment_id
                                and p.school_id = v_school
                                and p.status = 'verified'
          join inv on inv.id = al.invoice_id
         where al.school_id = v_school
         group by al.invoice_id
      ),
      per as (
        select inv.period_month, inv.due_date,
               greatest(coalesce(net.net, 0) + inv.fine, 0) as billed,
               coalesce(alloc.paid, 0) as paid
          from inv
          left join net on net.invoice_id = inv.id
          left join alloc on alloc.invoice_id = inv.id
      )
      select per.period_month,
             count(*)::int as challans,
             sum(per.billed) as billed,
             -- An over-allocated challan counts as fully paid, never as more
             -- than it raised: the surplus is the family's advance, which is
             -- not this month's collection.
             sum(least(per.paid, per.billed)) as paid,
             coalesce(sum(greatest(per.billed - per.paid, 0))
               filter (where per.due_date is not null and per.due_date < v_today), 0) as overdue,
             coalesce(sum(greatest(per.billed - per.paid, 0))
               filter (where per.due_date is null or per.due_date >= v_today), 0) as not_due
        from per
       group by per.period_month
    ) m;

  -- ---- where the dues sit, by class ------------------------------------------
  -- fn_dashboard_summary's outstanding query, grouped. Same rows, same
  -- student_balance, so the bars add up to the Outstanding tile to the rupee.
  select coalesce(jsonb_agg(jsonb_build_object(
           'class_id', y.class_id, 'class_name', y.class_name,
           'level_order', y.level_order,
           'students', y.students, 'amount', y.amount)
         order by y.amount desc, y.level_order), '[]'::jsonb)
    into v_dues
    from (
      select c.id as class_id, c.name as class_name, c.level_order,
             count(*)::int as students, sum(b.bal) as amount
        from public.enrollments e
        join public.classes c on c.id = e.class_id and c.school_id = v_school
        join lateral (select public.student_balance(e.student_id) as bal) b on true
       where e.school_id = v_school
         and e.session_id = (select current_session_id from public.school_settings
                              where school_id = v_school)
         and e.status = 'active'
         and b.bal > 0
       group by c.id, c.name, c.level_order
    ) y;

  -- ---- the staff room today --------------------------------------------------
  select jsonb_build_object(
           'on_books', count(*)::int,
           'marked',   count(sa.id)::int,
           'present',  count(*) filter (where sa.status = 'present')::int,
           'late',     count(*) filter (where sa.status = 'late')::int,
           'half_day', count(*) filter (where sa.status = 'half_day')::int,
           'leave',    count(*) filter (where sa.status = 'leave')::int,
           'absent',   count(*) filter (where sa.status = 'absent')::int)
    into v_staff
    from public.staff st
    left join public.staff_attendance sa on sa.staff_id = st.id
                                        and sa.school_id = v_school
                                        and sa.attendance_date = v_today
   where st.school_id = v_school
     and st.deleted_at is null
     and st.status = 'active';

  return jsonb_build_object(
    'today', v_today,
    'session_set', v_session is not null,
    'sections', v_sections,
    'trend', v_trend,
    'months', v_months,
    'dues_by_class', v_dues,
    'staff', v_staff);
end;
$$;

revoke all on function public.fn_dashboard_trends() from public, anon;
grant execute on function public.fn_dashboard_trends() to authenticated;

-- -----------------------------------------------------------------------------
-- fn_student_marks_trend: every class test of the session for one child.
--
-- SECURITY INVOKER, exactly like fn_student_month_tests (0021), whose rules it
-- follows line for line with the month bound taken off. Row-level security on
-- assessments and mark_entries therefore decides who sees what, so a parent or
-- a teacher gets the same marks here that they already get month by month, and
-- no new door is opened. Future-dated tests are left out: a test scheduled for
-- next week is not a mark.
-- -----------------------------------------------------------------------------
create or replace function public.fn_student_marks_trend(p_enrollment_id uuid)
returns table(
  assessment_id uuid, title text, subject_name text, assessment_date date,
  max_marks numeric, marks numeric, is_absent boolean,
  pct numeric, class_avg_pct numeric, pass_pct numeric, passed boolean
) language plpgsql stable security invoker set search_path = public as $$
declare
  v_pass numeric;
begin
  select pass_percent into v_pass from public.school_settings
   where school_id = public.current_school_id();
  v_pass := coalesce(v_pass, 33);

  return query
  select a.id, a.title, subj.name, a.assessment_date, a.max_marks,
         me.marks, coalesce(me.is_absent, false),
         case when me.marks is null or coalesce(me.is_absent, false) or a.max_marks <= 0
              then null
              else round(100.0 * me.marks / a.max_marks, 1) end,
         (select round(100.0 * avg(m2.marks) / nullif(a.max_marks, 0), 1)
            from public.mark_entries m2
           where m2.assessment_id = a.id and not m2.is_absent and m2.marks is not null),
         v_pass,
         case when coalesce(me.is_absent, false) or me.marks is null then false
              else me.marks >= a.max_marks * v_pass / 100.0 end
    from public.assessments a
    left join public.subjects subj on subj.id = a.subject_id
    join public.enrollments e on e.id = p_enrollment_id
    left join public.mark_entries me on me.assessment_id = a.id
                                    and me.enrollment_id = p_enrollment_id
   where a.session_id = e.session_id
     and a.class_id = e.class_id
     and (a.section_id is null or a.section_id = e.section_id)
     and a.assessment_date is not null
     and a.assessment_date <= (now() at time zone 'Asia/Karachi')::date
   order by a.assessment_date, a.title;
end;
$$;

revoke all on function public.fn_student_marks_trend(uuid) from public, anon;
grant execute on function public.fn_student_marks_trend(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0146_the_dashboard_draws_what_it_knows.sql', '47_the_dashboard_draws_what_it_knows.sql');
end $ledger$;
