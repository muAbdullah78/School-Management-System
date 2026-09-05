-- =============================================================================
-- 0100 — Finishing 0097: the attendance rule now exists in one place
--
-- 0097 was written because the same register produced three different
-- percentages: the parent portal read 92% where the result card in the child's
-- hand printed 83.3%, because the portal counted a late arrival and a half day
-- as whole days present, and the dashboard did not count a late arrival at all.
-- It created `fn__attendance_pct` as the single rule and pointed the two broken
-- callers at it.
--
-- It left the three CORRECT copies alone, and that was the wrong call.
--
--   fn_attendance_summary          the student profile
--   fn_staff_attendance_summary    the staff record
--   fn_generate_result_cards       the printed card
--
-- All three carry the arithmetic inline, all three are byte-identical in effect
-- today, and being correct today is exactly what the two broken ones were until
-- somebody edited one of them. Four copies of a rule is not four checks on it,
-- it is four chances to diverge, and this rule has already diverged twice on
-- the two surfaces a school and a parent look at most.
--
-- The check at the bottom is the part that lasts: after this migration, the
-- formula appears in exactly ONE function body, and a future migration that
-- writes it out again fails here rather than in front of a family.
--
-- WHY fn_generate_result_cards IS REWRITTEN PROGRAMMATICALLY
--
-- It is 287 lines. Retyping it into this file to change two of them is how a
-- stack of earlier fixes gets silently reverted, which 0059's header records
-- happening in this repository once already, and which the first draft of 0098
-- did again to three read gates. So its own definition is read back from the
-- catalogue, the formula is substituted, and the result is executed. Nothing
-- else in it can change, because nothing else in it is touched.
--
-- Re-runnable: the substitution matches nothing on a second run, and the do
-- block skips out.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The student profile
-- ---------------------------------------------------------------------------
create or replace function public.fn_attendance_summary(
  p_enrollment_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  perform public.assert_own('enrollments', p_enrollment_id);
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    -- The shared rule. It returns null on an unmarked register itself, so the
    -- `case when count(*) = 0` that used to wrap this is gone rather than
    -- duplicated: two places deciding what an empty register means is the same
    -- mistake one size smaller.
    'present_pct', public.fn__attendance_pct(
      (count(*) filter (where status = 'present'))::int,
      (count(*) filter (where status = 'late'))::int,
      (count(*) filter (where status = 'half_day'))::int,
      count(*)::int)
  ) into v
  from public.attendance_daily
  where enrollment_id = p_enrollment_id
    and attendance_date between p_from and p_to;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The staff record
--
-- A different table, the same rule. A school that docks pay on attendance will
-- compare a teacher's percentage against a pupil's and expect them to be
-- computed the same way, and there is no argument for them not to be.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_attendance_summary(
  p_staff_id uuid, p_from date, p_to date
) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (public.may_view('owner','principal','admin_clerk') or p_staff_id = public.my_staff_id()) then
    raise exception 'Not permitted';
  end if;
  perform public.assert_own('staff', p_staff_id);
  select jsonb_build_object(
    'present',     count(*) filter (where status = 'present'),
    'absent',      count(*) filter (where status = 'absent'),
    'leave',       count(*) filter (where status = 'leave'),
    'late',        count(*) filter (where status = 'late'),
    'half_day',    count(*) filter (where status = 'half_day'),
    'marked_days', count(*),
    'present_pct', public.fn__attendance_pct(
      (count(*) filter (where status = 'present'))::int,
      (count(*) filter (where status = 'late'))::int,
      (count(*) filter (where status = 'half_day'))::int,
      count(*)::int)
  ) into v
  from public.staff_attendance
  where staff_id = p_staff_id and attendance_date between p_from and p_to;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The printed card, rewritten from its own definition
-- ---------------------------------------------------------------------------
do $rewrite$
declare
  v_src text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'fn_generate_result_cards';

  if v_src is null then
    raise notice '0100: fn_generate_result_cards is not present, nothing to rewrite';
    return;
  end if;

  -- Whitespace-tolerant, because the same expression is laid out differently in
  -- 0005 and 0058 and a school may be on either.
  v_new := regexp_replace(
    v_src,
    'round\(100\.0 \* \(count\(\*\) filter \(where status in \(''present'',''late''\)\)\s*'
      || '\+ 0\.5 \* count\(\*\) filter \(where status = ''half_day''\)\) / count\(\*\), 1\)',
    'public.fn__attendance_pct('
      || '(count(*) filter (where status = ''present''))::int, '
      || '(count(*) filter (where status = ''late''))::int, '
      || '(count(*) filter (where status = ''half_day''))::int, '
      || 'count(*)::int)',
    'g');

  if v_new = v_src then
    -- Either already done, or the expression has been reworded. Those are very
    -- different situations, so they are told apart rather than both passing
    -- quietly: a rewording means this migration silently stopped working.
    if v_src like '%fn__attendance_pct%' then
      raise notice '0100: fn_generate_result_cards already uses the shared rule';
      return;
    end if;
    -- Adjacent string literals, not `||`. RAISE takes a literal format string
    -- and a concatenation expression is a syntax error there, which is how the
    -- first version of this file failed to apply at all.
    raise exception '0100: could not find the attendance formula in '
      'fn_generate_result_cards. It has been reworded, so this substitution '
      'no longer matches and the card would keep its own copy of the rule. '
      'Update the pattern in this migration.';
  end if;

  execute v_new;
end $rewrite$;

-- ---------------------------------------------------------------------------
-- 4. Did this migration actually do its job?
--
-- Narrower than it looks, and worth being exact about rather than claiming to
-- be the permanent guard. It runs AFTER the three rewrites above, so what it
-- catches is THIS FILE failing: a school on a variant wording the substitution
-- in section 3 did not match, or a fourth copy nobody knew about. It cannot
-- catch a migration written next year that spells the formula out again,
-- because that one runs after this file on every install.
--
-- The permanent guard is in supabase/tests/attendance_rule.sql, which asks the
-- same catalogue question on the finished database and fails CI. Both exist
-- because they answer different questions: this one protects the deployment,
-- that one protects the next change.
-- ---------------------------------------------------------------------------
do $assert$
declare v_bad text;
begin
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname <> 'fn__attendance_pct'
    and p.prosrc like '%0.5 * count(*) filter (where status = ''half_day'')%';

  if v_bad is not null then
    raise exception '0100: the attendance rule is written out inside: %. '
      'It must exist only in fn__attendance_pct, because the last time it '
      'existed in four places two of them were wrong and a parent read 92%% '
      'where the result card printed 83.3%%.', v_bad;
  end if;
end $assert$;
