-- =============================================================================
-- Subscriptions, trial, grace and the student-limit rule.
--
-- The commercial rules this encodes (agreed with the owner):
--
--   Plan          Students      Monthly    Yearly (2 months free)
--   starter       up to 200     Rs 3,500   Rs 35,000
--   growth        201-500       Rs 5,500   Rs 55,000
--   institution   501-1500      Rs 7,500   Rs 75,000
--   custom        1500+         negotiated
--
--   * 14-day free trial on every plan.
--   * When a period ends, the school gets a 14-day GRACE window in which the
--     app keeps working. This is not generosity — activation is manual after a
--     bank transfer, so without a grace window every renewal would take the
--     school offline between paying and being switched back on.
--   * After grace: LOCKED. Daily operations stop. Reads and export keep
--     working, always, so a school can never be held away from its own records.
--   * Going over the student limit NEVER blocks anything — see fn_my_licence.
-- =============================================================================

-- The margin tolerated above a plan's limit before the school is flagged.
-- 10%: 200 -> 220, 500 -> 550, 1500 -> 1650. (The owner's instinct was a
-- 20-student margin on the 200 plan, which is exactly 10% — this is that rule
-- generalised so it scales to every plan.)
create or replace function public.plan_margin_limit(p_limit integer) returns integer
language sql immutable as $$
  select case when p_limit is null then null else p_limit + ceil(p_limit * 0.10)::integer end;
$$;

-- Grace window after a period ends, in days.
create or replace function public.grace_days() returns integer
language sql immutable as $$ select 14 $$;

-- ---------------------------------------------------------------------------
-- Effective status
--
-- Stored status is what the platform last set; effective status is what the
-- calendar says now. Deriving it means a school does not silently stay 'active'
-- because a nightly job failed to run.
-- ---------------------------------------------------------------------------
create or replace function public.fn_effective_status(p_school_id uuid)
returns public.subscription_status
language sql stable security definer set search_path = public as $$
  select case
    when s.status = 'cancelled' then 'cancelled'::public.subscription_status
    -- Trial: live until it ends, then straight to locked (no grace on a trial —
    -- nothing has been paid, so there is no payment in flight to wait for).
    when s.status = 'trialing' then
      case when current_date <= coalesce(s.trial_ends_on, current_date)
           then 'trialing'::public.subscription_status
           else 'locked'::public.subscription_status end
    -- Paid: live to period_end, then grace, then locked.
    when s.period_end is null then s.status
    when current_date <= s.period_end then 'active'::public.subscription_status
    when current_date <= s.period_end + public.grace_days()
      then 'grace'::public.subscription_status
    else 'locked'::public.subscription_status
  end
  from public.subscriptions s
  where s.school_id = p_school_id;
$$;

-- ---------------------------------------------------------------------------
-- Student count
--
-- "Counted student" = an active enrolment in the school's current session.
-- Struck-off, withdrawn, graduated and soft-deleted students do not count.
-- This is deliberately the same number a principal would say out loud if asked
-- how many students they have, so a plan upgrade is never an argument about
-- whose definition applies.
-- ---------------------------------------------------------------------------
create or replace function public.fn_count_students(p_school_id uuid)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::integer
  from public.enrollments e
  join public.students s on s.id = e.student_id
  join public.academic_sessions ses on ses.id = e.session_id
  where e.school_id = p_school_id
    and ses.is_current
    and e.status = 'active'
    and s.status = 'active'
    and s.deleted_at is null;
$$;

-- Refresh the cached count and record a dated snapshot. Called nightly by the
-- platform (service role) and on demand. One snapshot per school per day.
create or replace function public.fn_refresh_student_count(p_school_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_count  integer;
  v_plan   text;
  v_limit  integer;
  v_margin integer;
begin
  v_count := public.fn_count_students(p_school_id);

  select sub.plan_code, p.student_limit into v_plan, v_limit
  from public.subscriptions sub
  join public.plans p on p.code = sub.plan_code
  where sub.school_id = p_school_id;

  if v_plan is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;

  v_margin := public.plan_margin_limit(v_limit);

  update public.subscriptions
     set student_count = v_count,
         counted_at    = now(),
         -- Flag on first crossing only, so the platform panel shows since when.
         over_limit_flagged_at = case
           when v_margin is not null and v_count > v_margin
             then coalesce(over_limit_flagged_at, now())
           else null
         end
   where school_id = p_school_id;

  insert into public.student_count_snapshots
    (school_id, counted_on, student_count, plan_code, student_limit)
  values (p_school_id, current_date, v_count, v_plan, v_limit)
  on conflict (school_id, counted_on) do update
    set student_count = excluded.student_count,
        plan_code     = excluded.plan_code,
        student_limit = excluded.student_limit;

  return v_count;
end;
$$;

-- Every school at once — the nightly job.
create or replace function public.fn_refresh_all_student_counts()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n integer := 0;
begin
  for r in select school_id from public.subscriptions loop
    perform public.fn_refresh_student_count(r.school_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- The one call the app makes on startup.
--
-- Returns everything the UI needs to decide what to show: whether to run at
-- all, how long is left, and whether to show a limit notice. Note limit_state
-- is advisory ONLY — nothing in this file blocks adding a student. Admission is
-- when a school earns money; putting a locked door there would make us the
-- reason a parent walked out, which is not a position to negotiate a renewal
-- from.
-- ---------------------------------------------------------------------------
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
    'limit_state',    v_state,
    -- Advisory only. The UI shows this to owner/principal, not to the clerk
    -- doing admissions, who can do nothing about it.
    'limit_notice',   case v_state
      when 'within_margin' then
        format('You have %s students. Your plan covers %s. You are still inside the allowance — nothing to do today.',
               v_sub.student_count, v_plan.student_limit)
      when 'over' then
        format('You have %s students, above the %s your plan covers. We will move you to the right plan at your next renewal — nothing stops working.',
               v_sub.student_count, v_plan.student_limit)
      else null end
  );
end;
$$;

grant execute on function public.fn_my_licence() to authenticated;
grant execute on function public.fn_effective_status(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Enforcement
--
-- Locking is enforced in enforce_school_id(), which already runs BEFORE INSERT
-- OR UPDATE on every tenant table — so there is exactly one place where "is
-- this school allowed to write?" is decided, and no table can be forgotten.
--
-- What a locked school can still do: read everything, and export everything.
-- Those are SELECTs and never reach this trigger.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_school_id() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_status public.subscription_status;
begin
  if tg_op = 'INSERT' then
    if new.school_id is null then
      new.school_id := v_school;
    elsif v_school is not null and new.school_id <> v_school then
      raise exception 'Cross-tenant write refused on %: row addressed to school %, caller belongs to %',
        tg_table_name, new.school_id, v_school;
    end if;
    if new.school_id is null then
      raise exception 'Cannot write to % : no school context for this user', tg_table_name;
    end if;
  else
    if new.school_id is distinct from old.school_id then
      raise exception 'A % row cannot be moved between schools', tg_table_name;
    end if;
  end if;

  -- Subscription gate. Only applies to writes made by a signed-in user: the
  -- platform's own service-role paths have no school context and must keep
  -- working (that is how a school gets REACTIVATED after paying).
  if v_school is not null then
    v_status := public.fn_effective_status(new.school_id);
    if v_status in ('locked', 'cancelled') then
      raise exception
        'This school''s subscription has ended. Your records are safe and can still be viewed and exported — renew to start entering data again.'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Provisioning (service role only — no grant to authenticated).
-- Creates the school, its subscription and its 14-day trial in one step.
-- ---------------------------------------------------------------------------
create or replace function public.fn_provision_school(
  p_name text, p_plan_code text default 'starter', p_city text default null,
  p_contact_name text default null, p_contact_phone text default null,
  p_contact_email text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'School name is required';
  end if;
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email)
  values (btrim(p_name), p_city, p_contact_name, p_contact_phone, p_contact_email)
  returning id into v_id;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_id, p_plan_code, 'trialing', current_date + 14);

  return jsonb_build_object('school_id', v_id, 'trial_ends_on', current_date + 14);
end;
$$;

-- Activate or renew after a bank transfer clears. p_months: 1 or 12.
create or replace function public.fn_activate_subscription(
  p_school_id uuid, p_plan_code text, p_months integer default 12
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date;
begin
  if not exists (select 1 from public.plans where code = p_plan_code) then
    raise exception 'Unknown plan %', p_plan_code;
  end if;
  if p_months is null or p_months < 1 then
    raise exception 'Months must be at least 1';
  end if;

  -- Renewing early extends from the existing end date rather than from today,
  -- so a school that pays a week ahead does not lose that week.
  select case
    when period_end is not null and period_end >= current_date
      then period_end + 1 else current_date end
  into v_start
  from public.subscriptions where school_id = p_school_id;

  if v_start is null then
    raise exception 'No subscription for school %', p_school_id;
  end if;
  v_end := (v_start + (p_months || ' months')::interval)::date - 1;

  update public.subscriptions
     set plan_code     = p_plan_code,
         status        = 'active',
         cycle         = case when p_months >= 12 then 'yearly' else 'monthly' end::public.billing_cycle,
         period_start  = v_start,
         period_end    = v_end,
         grace_ends_on = v_end + public.grace_days()
   where school_id = p_school_id;

  perform public.fn_refresh_student_count(p_school_id);

  return jsonb_build_object(
    'school_id', p_school_id, 'plan_code', p_plan_code,
    'period_start', v_start, 'period_end', v_end,
    'grace_ends_on', v_end + public.grace_days());
end;
$$;

-- The platform panel's worklist: who is expiring, who is over their limit, and
-- what plan each school should be on at renewal given its real student count.
create or replace function public.fn_platform_schools()
returns table(
  school_id uuid, school_name text, city text, contact_phone text,
  plan_code text, status public.subscription_status, expires_on date,
  days_left integer, student_count integer, student_limit integer,
  limit_state text, suggested_plan text
) language sql stable security definer set search_path = public as $$
  select
    s.id, s.name, s.city, s.contact_phone,
    sub.plan_code,
    public.fn_effective_status(s.id),
    case
      when sub.status = 'trialing' then sub.trial_ends_on
      else sub.period_end end,
    case
      when sub.status = 'trialing' then sub.trial_ends_on - current_date
      else sub.period_end - current_date end,
    sub.student_count,
    p.student_limit,
    case
      when p.student_limit is null then 'ok'
      when sub.student_count <= p.student_limit then 'ok'
      when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
      else 'over' end,
    (select p2.code from public.plans p2
      where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
      order by p2.sort_order limit 1)
  from public.schools s
  join public.subscriptions sub on sub.school_id = s.id
  join public.plans p on p.code = sub.plan_code
  order by s.name;
$$;
