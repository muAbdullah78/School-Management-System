-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0105_the_leave_the_school_approved.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0105: The school approved the leave and then printed it as absence
--
-- WHAT A PARENT SEES TODAY
--
-- A day marked `Leave` counts against the attendance percentage in exactly the
-- same way as `Absent`. It is in the denominator, `marked_days`, and it is not
-- in the numerator. That is deliberate and it stays: the percentage answers
-- "how much of the school year was this child here", which is the number a
-- Pakistani school needs for the 75% rule that decides who may sit the board
-- exams. A percentage that quietly forgave approved leave would stop being able
-- to carry that rule, and a child with two months of granted leave would print
-- at 100%.
--
-- What was wrong is not the arithmetic, it is that the two surfaces a PARENT
-- looks at never mentioned the leave at all:
--
--   the portal          "160 present of 180 days marked", 88.9%, and a
--                       day-by-day list. No leave total anywhere.
--   the result card     "Attendance: 88.9%". Nothing about the missing days.
--
-- The office can already see the breakdown on the child's profile, which prints
-- `P 160 · A 5 · L 15 · Lt 2 · ½ 1`. The parent could not, so the school
-- granted fifteen days of leave and then sent home a card that reads as though
-- the child simply did not turn up. Nobody can settle that at the counter from
-- what is printed, and the person who has to try is the clerk.
--
-- So both parent surfaces now carry the leave figure and one sentence saying
-- what the percentage counts.
--
-- WHY A SHARED COUNTS FUNCTION AND NOT THREE MORE COPIES
--
-- 0097 and 0100 exist because this exact rule had been written out in four
-- places and two of them were wrong by the time a parent compared the portal
-- with the result card. Adding three subqueries to fn_generate_result_cards to
-- fetch present, leave and marked would have put the date window -- which is
-- the part that differs between a term card and a profile -- back into more
-- than one place on the same day the formula finally stopped being duplicated.
--
-- fn__attendance_counts is therefore ONE function holding the window and every
-- count, and it takes the percentage from fn__attendance_pct rather than
-- recomputing it, so 0100's assertion that the formula exists in exactly one
-- body still holds.
--
-- fn_portal_child_attendance is restated rather than patched, because its query
-- is genuinely a different one: it spans every enrolment a child has ever had,
-- where the card is one enrolment in one term. Nothing has patched it since
-- 0097, checked, so restating it cannot revert anything.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Every count for one enrolment over one window, in one place
--
-- SECURITY INVOKER, deliberately, and this is the whole argument. It takes a
-- school id as an ARGUMENT, so as a definer function it would read any school's
-- register for anybody who could reach it -- the shape supabase/check-definer-idor.py
-- exists to catch. As an invoker function it runs as whoever called it: inside
-- the definer functions below that is the table owner, so it sees everything it
-- needs, and from a browser session it is not reachable at all because the
-- grant is revoked. The scoping decision stays with the caller that already
-- authorised the request.
-- ---------------------------------------------------------------------------
create or replace function public.fn__attendance_counts(
  p_enrollment_id uuid, p_school_id uuid, p_from date, p_to date
) returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    -- The shared rule, not a fifth copy of it.
    'present_pct', public.fn__attendance_pct(
      (count(*) filter (where status = 'present'))::int,
      (count(*) filter (where status = 'late'))::int,
      (count(*) filter (where status = 'half_day'))::int,
      count(*)::int)
  )
  from public.attendance_daily
  where enrollment_id = p_enrollment_id
    and school_id = p_school_id
    and (p_from is null or attendance_date >= p_from)
    and (p_to   is null or attendance_date <= p_to);
$$;

revoke all on function public.fn__attendance_counts(uuid, uuid, date, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The printed card carries the counts, not only the percentage
--
-- Patched from its own definition: fn_generate_result_cards is 287 lines and
-- retyping it to add one key is how a stack of earlier fixes gets silently
-- reverted, which this repository has recorded happening twice.
--
-- The counts go into the FROZEN payload and not into a new column on
-- result_cards. The payload is a snapshot of what was printed, and every reader
-- of it already tolerates missing keys by contract, so last term's reprint is
-- unaffected. A column would need a backfill for rows nobody will reprint.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_src text; v_new text;
begin
  begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_generate_result_cards';

    if v_src is null then
      raise warning '0105: fn_generate_result_cards is not present, so the card '
        'carries no leave figure. Apply the earlier bundles first.';
    elsif v_src like '%fn__attendance_counts%' then
      raise notice '0105: the result card already carries the attendance counts';
    else
      -- Whitespace-blind, per supabase/check-patch-anchors.py: the gap is `\s*`
      -- so indentation and line endings cannot decide whether a card shows the
      -- leave a school granted.
      v_new := regexp_replace(
        v_src,
        '(''attendance_pct'',\s*v_att,)',
        '\1' || chr(10) ||
        '      ''attendance'', public.fn__attendance_counts(' ||
        'r.enrollment_id, v_school, v_from, v_to),');
      if v_new = v_src or v_new not like '%fn__attendance_counts%' then
        raise warning '0105: could not find the attendance key in '
          'fn_generate_result_cards, so nothing was changed and the card keeps '
          'showing a percentage with no explanation. The rest of this bundle '
          'still applied. Run supabase/verify.sql.';
      else
        execute v_new;
      end if;
    end if;
  exception when others then
    raise warning '0105: fn_generate_result_cards was left as it was: %. The '
      'rest of this bundle still applied.', sqlerrm;
  end;
end $patch$;

-- ---------------------------------------------------------------------------
-- 3. The portal says how many of the missing days were granted
--
-- `leave` was the one status the parent's own view never reported, while
-- present, absent, late and half_day were all already in this object. Restated
-- in full because the object is short and nothing has patched this function
-- since 0097.
-- ---------------------------------------------------------------------------
create or replace function public.fn_portal_child_attendance(
  p_student_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_out jsonb;
  v_present integer; v_late integer; v_half integer; v_absent integer;
  v_leave integer; v_total integer;
begin
  perform public.fn__assert_my_child(p_student_id);

  select count(*) filter (where a.status = 'present'),
         count(*) filter (where a.status = 'late'),
         count(*) filter (where a.status = 'half_day'),
         count(*) filter (where a.status = 'absent'),
         count(*) filter (where a.status = 'leave'),
         count(*)
    into v_present, v_late, v_half, v_absent, v_leave, v_total
  from public.attendance_daily a
  join public.enrollments e on e.id = a.enrollment_id
  where e.student_id = p_student_id
    and a.attendance_date between p_from and p_to;

  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'present', coalesce(v_present, 0),
    'late', coalesce(v_late, 0),
    'half_day', coalesce(v_half, 0),
    'absent', coalesce(v_absent, 0),
    -- 0105. The school granted these days. A parent reading a percentage with
    -- no way to see that is being shown a number they cannot check.
    'leave', coalesce(v_leave, 0),
    'marked', coalesce(v_total, 0),
    'percent', public.fn__attendance_pct(v_present, v_late, v_half, v_total),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', a.attendance_date, 'status', a.status)
             order by a.attendance_date desc)
      from public.attendance_daily a
      join public.enrollments e on e.id = a.enrollment_id
      where e.student_id = p_student_id
        and a.attendance_date between p_from and p_to
    ), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

grant  execute on function public.fn_portal_child_attendance(uuid, date, date) to authenticated;
revoke execute on function public.fn_portal_child_attendance(uuid, date, date) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. Did it take?
--
-- A WARNING and not an exception, for the reason recorded in 0100, 0101 and
-- 0102: this file is pasted as part of a bundle the SQL editor runs as ONE
-- transaction, and raising here would revert everything else in it.
-- supabase/verify.sql names what is outstanding, and
-- supabase/tests/attendance_rule.sql proves the counts are actually returned.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.fn__attendance_counts(uuid,uuid,date,date)') is null then
    v_bad := v_bad || 'fn__attendance_counts is missing';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_generate_result_cards'
      and p.prosrc like '%fn__attendance_counts%') then
    v_bad := v_bad || 'the result card still prints a percentage with no counts';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_portal_child_attendance'
      and p.prosrc like '%''leave''%') then
    v_bad := v_bad || 'the portal still does not report leave';
  end if;

  if array_length(v_bad, 1) is null then
    raise notice '0105: both parent surfaces now report the leave the school approved';
  else
    raise warning '0105: %. Everything else in this bundle applied. Send the '
      'output of supabase/verify.sql.', array_to_string(v_bad, '; ');
  end if;
end $assert$;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0105_the_leave_the_school_approved.sql', '13_the_leave_the_school_approved.sql');
end $ledger$;
