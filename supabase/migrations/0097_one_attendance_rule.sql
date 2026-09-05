-- =============================================================================
-- 0097  One attendance percentage, not three
--
-- THE PROBLEM. The same fact, "what was attendance", was computed three
-- different ways in this product, and a school could see three different
-- numbers for the same child on the same day:
--
--   the rule, written down in 0003     (present + late + half a half_day) / marked
--   the result card (0005, 0058)       the same. Correct.
--   the student profile (0003)         the same. Correct.
--   the teacher portal (0022)          the same. Correct.
--   THE PARENT PORTAL (0033)           late and half_day both counted as a
--                                      FULL day present
--   THE DASHBOARD (Dashboard.tsx)      half_day counted as a FULL day, and
--                                      `late` not counted AT ALL, so a class
--                                      that all arrived late read as absent
--
-- The two that were wrong are the two most seen: the tile the owner looks at
-- every morning, and the figure a PARENT reads. So a father saw 92% in the
-- portal, the school saw 78% on its dashboard, and the result card in the
-- child's hand printed 85%. Nobody was lying and every number was wrong.
--
-- WHY THIS PARTICULAR RULE. A late child was in school: counting them absent
-- misrepresents the register. A half day is half a day: counting it whole
-- inflates the figure, and a percentage a school quotes to a parent should
-- never be the flattering version by accident. It is also the rule already
-- printed on the result card, which is the copy that leaves the building.
--
-- WHY A SHARED FUNCTION RATHER THAN FIXING THE TWO. Three correct copies and
-- two wrong ones is what happens when a rule is retyped. fn__attendance_pct is
-- now the only place the arithmetic exists, every caller passes it counts, and
-- supabase/tests/attendance_rule.sql asserts that every surface agrees on the
-- same register. A sixth copy would have to work to disagree.
-- =============================================================================

-- The rule, once. IMMUTABLE: it is arithmetic on its arguments and nothing else,
-- so it can be inlined and used in an index if it ever needs to be.
create or replace function public.fn__attendance_pct(
  p_present integer, p_late integer, p_half_day integer, p_marked integer
) returns numeric language sql immutable as $$
  select case
    when coalesce(p_marked, 0) = 0 then null
    else round(
      100.0 * (coalesce(p_present, 0) + coalesce(p_late, 0)
               + 0.5 * coalesce(p_half_day, 0)) / p_marked, 1)
  end
$$;

comment on function public.fn__attendance_pct(integer, integer, integer, integer) is
  'The one attendance percentage. present + late + half of half_day, over marked '
  'days. Every surface must call this: three copies of the arithmetic drifted '
  'into two wrong answers, one of them the figure shown to parents.';

-- ---------------------------------------------------------------------------
-- The parent portal, corrected.
--
-- Was: count(*) filter (where status in ('present','late','half_day')), which
-- makes a half day a whole one. A parent comparing the portal with the result
-- card in their child's hand found two different numbers, and the portal's was
-- always the higher of the two.
--
-- 'present' in the returned object now means what it says: the days the child
-- was actually marked present. The percentage is the rule. Reporting a
-- weighted count as "present" was part of how this went unnoticed.
-- ---------------------------------------------------------------------------
create or replace function public.fn_portal_child_attendance(
  p_student_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_out jsonb;
  v_present integer; v_late integer; v_half integer; v_absent integer; v_total integer;
begin
  perform public.fn__assert_my_child(p_student_id);

  select count(*) filter (where a.status = 'present'),
         count(*) filter (where a.status = 'late'),
         count(*) filter (where a.status = 'half_day'),
         count(*) filter (where a.status = 'absent'),
         count(*)
    into v_present, v_late, v_half, v_absent, v_total
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

-- INTERNAL, and the double underscore is the promise. Every fn__ helper in this
-- schema is callable by nobody from a browser session: not anon, not
-- authenticated. Three separate checks enforce it, and all three caught this
-- one when it was first written with a grant to authenticated, which
-- contradicted the comment sitting directly above it.
--
-- Revoking does not break the callers. fn_portal_child_attendance and the rest
-- are SECURITY DEFINER, so they run as the owner and reach this regardless. The
-- app never calls it: it is handed counts by functions that already hold them.
revoke all on function public.fn__attendance_pct(integer, integer, integer, integer)
  from public, anon, authenticated;
