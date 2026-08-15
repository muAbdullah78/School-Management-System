-- =============================================================================
-- Platform administration — the product owner's side of the system.
--
-- A platform admin manages SCHOOLS (who exists, who has paid, who is over their
-- limit). They deliberately get NO access to tenant data: no student records,
-- no fee ledgers, no marks. Running the business does not require reading a
-- child's records, and a "god mode" that could is a permanent hole — one
-- compromised platform login would otherwise expose every school at once.
--
-- So the policies added here are on PLATFORM tables only. Nothing in this file
-- widens access to a tenant table, and tenant_isolation.sql fails the build if
-- anything ever does.
-- =============================================================================

create table public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  note       text,
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;

-- SECURITY DEFINER so a policy calling it does not recurse through this table's
-- own RLS — same reasoning as has_role() and current_school_id().
create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

grant execute on function public.is_platform_admin() to authenticated;
grant select on public.platform_admins to authenticated;

-- An admin may see that they are one. Membership is granted only by service
-- role — there is no way to make yourself a platform admin from the app.
create policy platform_admins_self on public.platform_admins for select to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Platform reach over the platform tables (not tenant tables)
-- ---------------------------------------------------------------------------
create policy schools_select_platform on public.schools for select to authenticated
  using (public.is_platform_admin());
create policy schools_update_platform on public.schools for update to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());

create policy subscriptions_select_platform on public.subscriptions for select to authenticated
  using (public.is_platform_admin());

create policy snapshots_select_platform on public.student_count_snapshots for select to authenticated
  using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Guard the platform functions, then expose them.
--
-- These were service-role only. Gating each on is_platform_admin() lets the
-- admin panel call them directly with the caller's own JWT, so the service_role
-- key stays out of anything a browser can reach. Only user CREATION still needs
-- an Edge Function, because minting an auth user requires the service key.
-- ---------------------------------------------------------------------------

create or replace function public.fn_provision_school(
  p_name text, p_plan_code text default 'starter', p_city text default null,
  p_contact_name text default null, p_contact_phone text default null,
  p_contact_email text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
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

create or replace function public.fn_activate_subscription(
  p_school_id uuid, p_plan_code text, p_months integer default 12
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_start date; v_end date;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
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

-- Give a school that is genuinely mid-setup more trial. Deliberately capped:
-- an unbounded "extend" button turns into a free tier by accident.
create or replace function public.fn_extend_trial(p_school_id uuid, p_days integer default 14)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_new date;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 or p_days > 30 then
    raise exception 'Extension must be between 1 and 30 days';
  end if;

  update public.subscriptions
     set trial_ends_on = greatest(coalesce(trial_ends_on, current_date), current_date) + p_days,
         status = 'trialing'
   where school_id = p_school_id
     and status in ('trialing', 'locked')
  returning trial_ends_on into v_new;

  if v_new is null then
    raise exception 'Only a school still on trial can have its trial extended';
  end if;
  return jsonb_build_object('school_id', p_school_id, 'trial_ends_on', v_new);
end;
$$;

-- Dropped first: 0026's version returned a different column set, and Postgres
-- will not replace a set-returning function whose OUT parameters changed.
drop function if exists public.fn_platform_schools();

create or replace function public.fn_platform_schools()
returns table(
  school_id uuid, school_name text, city text, contact_name text, contact_phone text,
  plan_code text, status public.subscription_status, expires_on date,
  days_left integer, student_count integer, student_limit integer,
  limit_state text, suggested_plan text, needs_upgrade boolean
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
    select
      s.id, s.name, s.city, s.contact_name, s.contact_phone,
      sub.plan_code,
      public.fn_effective_status(s.id),
      case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end,
      (case when sub.status = 'trialing' then sub.trial_ends_on else sub.period_end end
        - current_date)::integer,
      sub.student_count,
      p.student_limit,
      case
        when p.student_limit is null then 'ok'
        when sub.student_count <= p.student_limit then 'ok'
        when sub.student_count <= public.plan_margin_limit(p.student_limit) then 'within_margin'
        else 'over' end,
      sug.code,
      sug.code is distinct from sub.plan_code
    from public.schools s
    join public.subscriptions sub on sub.school_id = s.id
    join public.plans p on p.code = sub.plan_code
    cross join lateral (
      select p2.code from public.plans p2
       where p2.active and (p2.student_limit is null or p2.student_limit >= sub.student_count)
       order by p2.sort_order limit 1
    ) sug
    order by s.name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Public signup path.
--
-- The unguarded twin of fn_provision_school, for the signup-school Edge
-- Function. It is NEVER granted to anon or authenticated — only the service
-- role can reach it — so a school can be created by the signup flow but not by
-- anything a browser can call directly.
-- ---------------------------------------------------------------------------
create or replace function public.fn_signup_school(
  p_name text, p_city text default null, p_contact_name text default null,
  p_contact_phone text default null, p_contact_email text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if nullif(btrim(p_name), '') is null then
    raise exception 'School name is required';
  end if;

  insert into public.schools (name, city, contact_name, contact_phone, contact_email)
  values (btrim(p_name), p_city, p_contact_name, p_contact_phone, p_contact_email)
  returning id into v_id;

  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
  values (v_id, 'starter', 'trialing', current_date + 14);

  return jsonb_build_object('school_id', v_id, 'trial_ends_on', current_date + 14);
end;
$$;

revoke execute on function public.fn_signup_school(text, text, text, text, text) from public, anon, authenticated;

-- Recount every school on demand (the panel's refresh button). Deliberately a
-- separate guarded entry point rather than granting fn_refresh_student_count
-- itself: that one takes a school_id and returns a count, so exposing it would
-- let any signed-in user probe for valid school ids and read their sizes.
create or replace function public.fn_platform_refresh_counts()
returns integer language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return public.fn_refresh_all_student_counts();
end;
$$;

grant execute on function public.fn_provision_school(text, text, text, text, text, text) to authenticated;
grant execute on function public.fn_activate_subscription(uuid, text, integer) to authenticated;
grant execute on function public.fn_extend_trial(uuid, integer) to authenticated;
grant execute on function public.fn_platform_schools() to authenticated;
grant execute on function public.fn_platform_refresh_counts() to authenticated;
