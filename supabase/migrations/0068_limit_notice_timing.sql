-- =============================================================================
-- 0068 — The software told a school it had outgrown its plan the same afternoon
--
-- This is a regression I introduced in 0067 and it is the school-facing half of
-- it, so it goes in on its own rather than waiting for a phase of work.
--
-- WHAT 0067 CHANGED
--
-- Before 0067, subscriptions.student_count only moved when a human pressed
-- "Refresh counts" in the operator console. So the school's own licence banner
-- said "you have N students, above the M your plan covers" whenever the
-- operator happened to have clicked recently — which was rarely, and by then
-- the renewal was usually the reason they had clicked.
--
-- 0067 put statement-level triggers on students and enrollments. That was
-- right: a school on Starter (Rs 9,500) that had quietly grown to 420 pupils
-- was Rs 25,500/year of revenue nobody could see. But it also means the count
-- now moves the instant a child is admitted.
--
-- And LicenceBanner.tsx shows fn_my_licence's `limit_notice` to the owner and
-- principal. So after 0067:
--
--   A principal admits the 101st child in October. Before the admission form
--   has closed, a banner appears telling them they have outgrown the plan they
--   paid for in April.
--
-- That does not read as a helpful notice. It reads as a meter running, on the
-- one screen where the school is earning money, at the moment it is earning it.
-- The comment in 0026 already says admission must never be where we apply
-- pressure — "putting a locked door there would make us the reason a parent
-- walked out". A banner is a softer door but it is a door.
--
-- WHAT THIS CHANGES
--
-- Split what the OPERATOR sees from what the SCHOOL sees. They need different
-- timing, not different truth:
--
--   * The operator keeps everything, immediately. fn_platform_schools still
--     returns limit_state, needs_upgrade and suggested_plan the moment the count
--     crosses, and over_limit_flagged_at still records since when. Catching
--     growth early is the entire point of 0067 and none of it is touched.
--
--   * The school is told when the renewal conversation is actually live —
--     inside 30 days of expiry, or already in grace / locked / cancelled. Then
--     the number is a fact about a decision being made this week rather than an
--     accusation about one made in April.
--
-- Two further points, both deliberate:
--
--   * The 'within_margin' notice is now never shown to the school at all. Its
--     own text was "You are still inside the allowance — nothing to do today."
--     A banner whose content is "nothing to do" is noise, and noise is how a
--     banner that will one day matter gets ignored. The operator still sees the
--     state.
--
--   * Nothing is being hidden that would otherwise explain a failure. The
--     student limit is advisory in this schema — 0026 blocks no INSERT on
--     students at any count, and 0068 does not change that. There is no case
--     where a school hits a refused Save and needs this banner to understand
--     why. If a hard limit is ever added, this rule must be revisited, and the
--     test below is where that will show up.
--
-- limit_state stays truthful in every response. Only limit_notice — which
-- exists solely to be rendered to the school — is gated. So anything that reads
-- the state programmatically is unaffected.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_my_licence()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_sub    record;
  v_plan   record;
  v_status public.subscription_status;
  v_margin integer;
  v_state  text;
  v_expiry date;
  v_days   integer;
  v_tell   boolean;
begin
  if v_school is null then
    return jsonb_build_object('ok', false, 'reason', 'no_school');
  end if;

  select * into v_sub from public.subscriptions where school_id = v_school;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_subscription');
  end if;

  select * into v_plan from public.plans where code = v_sub.plan_code;
  v_status := public.fn_effective_status(v_school);
  v_margin := public.plan_margin_limit(v_plan.student_limit);

  -- Days remaining against whichever clock is running.
  v_expiry := case
    when v_status = 'trialing' then v_sub.trial_ends_on
    when v_status = 'active'   then v_sub.period_end
    when v_status = 'grace'    then v_sub.period_end + public.grace_days()
    else null end;
  v_days := case when v_expiry is null then null else (v_expiry - current_date) end;

  v_state := case
    when v_plan.student_limit is null then 'ok'          -- custom: no limit
    when v_sub.student_count <= v_plan.student_limit then 'ok'
    when v_sub.student_count <= v_margin then 'within_margin'
    else 'over' end;

  -- Is the renewal conversation live? Only then does the school hear about the
  -- limit. grace/locked/cancelled qualify because in those states the school and
  -- the operator are already talking about money; a trial or an active licence
  -- more than 30 days from expiry does not.
  v_tell := v_status in ('grace', 'locked', 'cancelled')
         or (v_days is not null and v_days <= 30);

  return jsonb_build_object(
    'ok',             true,
    'school_id',      v_school,
    'status',         v_status,
    'locked',         v_status = 'locked',
    -- Reading and exporting are never withdrawn, in any state.
    'can_read',       true,
    'can_export',     true,
    'can_operate',    v_status in ('trialing', 'active', 'grace'),
    'plan_code',      v_plan.code,
    'plan_name',      v_plan.name,
    'cycle',          v_sub.cycle,
    'price_monthly',  v_plan.price_monthly,
    'price_yearly',   v_plan.price_yearly,
    'expires_on',     v_expiry,
    'days_left',      v_days,
    'student_count',  v_sub.student_count,
    'student_limit',  v_plan.student_limit,
    'margin_limit',   v_margin,
    -- The truth, always, whatever we choose to say out loud. The operator
    -- console reads its own copy of this from fn_platform_schools and is never
    -- gated.
    'limit_state',    v_state,
    -- Advisory, and only while the renewal is actually being discussed. Null at
    -- every other moment, so no consumer can render it early by accident — the
    -- rule lives here rather than in the banner, because a rule in one screen is
    -- a rule the next screen will not have.
    'limit_notice',   case
      when not v_tell then null
      when v_state = 'over' then
        format('You have %s students, above the %s your plan covers. We will move you to the right plan at your next renewal — nothing stops working.',
               v_sub.student_count, v_plan.student_limit)
      -- 'within_margin' says nothing worth a banner. Its old text was
      -- literally "nothing to do today".
      else null end
  );
end;
$$;

grant execute on function public.fn_my_licence() to authenticated;
