-- =============================================================================
-- 0074 — The operator could not see what a school was seeing
--
-- Phase 2b of docs/SUPER-ADMIN-DESIGN.md. When a principal phones and says "the
-- fee will not save", there was no way to look. This adds read-only support
-- access into any school, with every visit recorded and the record shown to the
-- school itself.
--
-- THE OWNER CHOSE FULL PERMANENT READ, over my recommendation of consented,
-- time-boxed access. That decision is built here as chosen: no consent step, no
-- approval, any school at any time. §2.1 of the design doc carries the argument
-- they overrode — the risk is commercial rather than legal, and it lands in the
-- sales meeting — and the one mitigation that costs nothing is the school-facing
-- visit log in section 6, which restricts the operator not at all and turns the
-- access into something to volunteer rather than hope is not asked about.
--
-- HOW IT WORKS, AND A CORRECTION TO THE DESIGN DOC
--
-- The doc claimed overriding current_school_id() was "the whole trick — ONE
-- function grants reach where 40 new policies would have been needed". That is
-- wrong, and measuring the policy census is what showed it. Every read policy on
-- a tenant table has one of two shapes:
--
--     school_id = current_school_id() AND is_staff()          -- 25 tables
--     school_id = current_school_id() AND may_view(…roles…)   -- 20 tables
--
-- and is_staff(), may_view() and has_role() all read public.profiles by
-- auth.uid(). An operator has NO profiles row in the target school, so all three
-- return false and the override alone would have shown them an empty console.
--
-- So three functions change, not one:
--
--     current_school_id()  falls back to the active session's school
--     is_staff()           or is_operator_session()
--     may_view(…)          or is_operator_session()
--     has_role(…)          UNTOUCHED  <-- this is the entire write refusal
--
-- That last line is the good news and it fell out of the census rather than
-- being designed: ALL 43 WRITE POLICIES gate on has_role(). Not one relies on
-- current_school_id() alone. So leaving has_role() alone refuses every operator
-- write through RLS with no new code, no new trigger, and nothing to forget.
--
-- The SECURITY DEFINER write path is covered too, and was already: 0059 built
-- the `readonly` observer on exactly this split, and check-readonly-writes.py
-- fails CI if any write policy or any VOLATILE function so much as mentions
-- may_view or readonly. That guard's pattern now includes is_operator_session,
-- so the operator inherits a boundary that already has a suite defending it.
-- Impersonation is therefore not a new security boundary — it is the observer
-- role, pointed at a school the operator has no profile in.
--
-- WHY A TABLE AND NOT A SESSION VARIABLE
--
-- The obvious implementation is set_config('app.operator_school', …). It is
-- unsafe here. Supabase pools connections through pgbouncer, so a session-level
-- GUC can outlive the request that set it and be read by whoever gets that
-- connection next — a cross-tenant leak with no attacker involved. A
-- transaction-local GUC is safe but cannot survive between the separate requests
-- a browser makes. So the active session is a row, which is also the only form
-- that can be audited.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The sessions
--
-- RLS on, and TWO read policies, which is deliberate: the operator sees every
-- visit, and a school sees the visits to itself. The second is the point of
-- section 6 and it must not be reachable through anything the operator controls.
--
-- No write policy at all. Rows arrive only through fn_operator_enter, which
-- checks is_platform_admin() — so a school user cannot manufacture a session
-- and read another school, which would be the catastrophic failure of this
-- design.
-- ---------------------------------------------------------------------------
create table if not exists public.operator_sessions (
  id         uuid primary key default gen_random_uuid(),
  admin_id   uuid not null,
  school_id  uuid not null references public.schools(id),
  -- Required, and free text. A log with no reason is a log nobody can use,
  -- including the operator reading their own six months later.
  reason     text not null,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  ended_at   timestamptz,
  constraint operator_sessions_reason_chk check (btrim(reason) <> ''),
  constraint operator_sessions_window_chk check (expires_at > started_at)
);

-- The index current_school_id() and is_operator_session() hit on every call.
-- Partial on the open sessions, which is the only set either one looks at.
create index if not exists operator_sessions_open_idx
  on public.operator_sessions (admin_id) where ended_at is null;
create index if not exists operator_sessions_school_idx
  on public.operator_sessions (school_id, started_at desc);

alter table public.operator_sessions enable row level security;

drop policy if exists operator_sessions_read_operator on public.operator_sessions;
create policy operator_sessions_read_operator on public.operator_sessions
  for select using (public.is_platform_admin());

-- The school's own view. Leadership only: a clerk can do nothing about it, and
-- "the software company looked at your records" is a governance fact for whoever
-- signed the contract.
--
-- has_role, NOT may_view — and that is not an oversight. may_view is true during
-- an operator session, so using it here would be circular in a confusing way;
-- more importantly this list is about accountability to the school, and the
-- readonly observer role has no business in it. Same category as
-- fn_pending_invites, which 0065 put on has_role for the same reason.
drop policy if exists operator_sessions_read_school on public.operator_sessions;
create policy operator_sessions_read_school on public.operator_sessions
  for select using (
    school_id = public.current_school_id()
    and public.has_role('owner', 'principal')
  );

-- ---------------------------------------------------------------------------
-- 2. Is there an active support session?
--
-- ONE indexed probe. The platform_admins join is not belt-and-braces: an admin
-- removed from platform_admins with a session still open would otherwise keep
-- their reach until it expired, and revoking access has to be immediate.
--
-- STABLE, and it must stay STABLE. check-readonly-writes.py asserts that of
-- may_view for the same reason: a VOLATILE predicate can be called from a write
-- path without the guard noticing.
-- ---------------------------------------------------------------------------
create or replace function public.is_operator_session()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.operator_sessions os
      join public.platform_admins pa on pa.user_id = os.admin_id
     where os.admin_id = auth.uid()
       and os.ended_at is null
       and os.expires_at > now()
  );
$$;

grant  execute on function public.is_operator_session() to authenticated;
revoke execute on function public.is_operator_session() from public, anon;

-- ---------------------------------------------------------------------------
-- 3. current_school_id() learns about support sessions
--
-- plpgsql rather than SQL, for a reason that is about cost. This function is
-- called from 93 RLS policies and 109 other functions; it is the hottest thing
-- in the schema. Written as
--
--     select coalesce((select … from profiles …), (select … from operator_sessions …))
--
-- Postgres may evaluate BOTH subqueries, so every school user would pay an extra
-- index probe on a table that concerns only the operator. plpgsql guarantees the
-- short circuit: a school user has a profiles row, returns on the first
-- statement, and never touches operator_sessions at all.
--
-- Nothing is lost by leaving SQL behind: the function is SECURITY DEFINER, and
-- Postgres does not inline those, so it was already a real call in every plan.
-- ---------------------------------------------------------------------------
create or replace function public.current_school_id()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select school_id into v from public.profiles where id = auth.uid() and active;
  if v is not null then
    return v;
  end if;

  -- No profile: either nobody, or an operator who has entered a school.
  select os.school_id into v
    from public.operator_sessions os
    join public.platform_admins pa on pa.user_id = os.admin_id
   where os.admin_id = auth.uid()
     and os.ended_at is null
     and os.expires_at > now()
   order by os.started_at desc
   limit 1;
  return v;
end;
$$;

grant execute on function public.current_school_id() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The two READ predicates, and only those
--
-- is_staff() carries 25 read policies, may_view() carries 20. has_role() carries
-- all 43 write policies and is deliberately not touched here — that is what
-- makes every operator write fail without a line of new code.
-- ---------------------------------------------------------------------------
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.active and p.role <> 'parent' from public.profiles p where p.id = auth.uid()),
    false)
  or public.is_operator_session();
$$;

create or replace function public.may_view(variadic p_roles public.user_role[])
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role(variadic p_roles)
      or public.has_role('readonly')
      or public.is_operator_session();
$$;

grant execute on function public.is_staff() to authenticated;
grant execute on function public.may_view(public.user_role[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Entering and leaving
-- ---------------------------------------------------------------------------
create or replace function public.fn_operator_enter(
  p_school_id uuid, p_reason text, p_minutes integer default 60
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_name text;
  v_mins integer := greatest(5, least(coalesce(p_minutes, 60), 480));
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to enter a school';
  end if;

  select name into v_name from public.schools where id = p_school_id;
  if v_name is null then
    raise exception 'School not found';
  end if;

  -- One session at a time. Two open sessions would make current_school_id()
  -- depend on started_at ordering, which is a coin toss dressed up as a rule.
  update public.operator_sessions
     set ended_at = now()
   where admin_id = auth.uid() and ended_at is null;

  insert into public.operator_sessions (admin_id, school_id, reason, expires_at)
  values (auth.uid(), p_school_id, btrim(p_reason),
          now() + make_interval(mins => v_mins))
  returning id into v_id;

  perform public.fn__log_operator_action('school_entered', p_school_id,
    jsonb_build_object('session_id', v_id, 'reason', btrim(p_reason),
                       'minutes', v_mins));

  return jsonb_build_object(
    'session_id', v_id, 'school_id', p_school_id, 'school_name', v_name,
    'expires_at', now() + make_interval(mins => v_mins), 'read_only', true);
end;
$$;

create or replace function public.fn_operator_leave()
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer; r record;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  for r in
    select id, school_id from public.operator_sessions
     where admin_id = auth.uid() and ended_at is null
  loop
    perform public.fn__log_operator_action('school_left', r.school_id,
      jsonb_build_object('session_id', r.id));
  end loop;

  update public.operator_sessions set ended_at = now()
   where admin_id = auth.uid() and ended_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- What the banner reads. Safe for anyone to call: it returns the CALLER's own
-- session or nothing, so it cannot be used to discover that somebody else is in
-- a school.
create or replace function public.fn_operator_current()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object(
       'session_id', os.id, 'school_id', os.school_id,
       'school_name', s.name, 'reason', os.reason,
       'started_at', os.started_at, 'expires_at', os.expires_at,
       'read_only', true)
       from public.operator_sessions os
       join public.schools s on s.id = os.school_id
       join public.platform_admins pa on pa.user_id = os.admin_id
      where os.admin_id = auth.uid() and os.ended_at is null and os.expires_at > now()
      order by os.started_at desc limit 1),
    'null'::jsonb);
$$;

-- Granted to `authenticated` for the operator's browser, and revoked from
-- public and anon because Postgres gives PUBLIC EXECUTE on every new function.
-- 0071 explains why ALTER DEFAULT PRIVILEGES cannot do this for us, and
-- check-definer-idor.py fails CI if any of these lines goes missing.
grant  execute on function public.fn_operator_enter(uuid, text, integer) to authenticated;
grant  execute on function public.fn_operator_leave() to authenticated;
grant  execute on function public.fn_operator_current() to authenticated;
revoke execute on function public.fn_operator_enter(uuid, text, integer) from public, anon;
revoke execute on function public.fn_operator_leave() from public, anon;
revoke execute on function public.fn_operator_current() from public, anon;

-- ---------------------------------------------------------------------------
-- 6. What the SCHOOL sees
--
-- The mitigation §2.1 argues for, and the reason it is worth having: it
-- restricts the operator in no way at all — they still enter any school at any
-- time without asking — it only means they cannot do it invisibly. "If you call
-- us with a problem we can enter your account to see what you are seeing, and
-- every single time we do it is recorded and you can read that record yourself"
-- is a stronger thing to say in a sales meeting than silence.
--
-- Deliberately does NOT name the individual operator. The school needs to know
-- that the vendor looked, when, and why. Which employee of the vendor is not
-- their business and publishing it invites a different argument.
-- ---------------------------------------------------------------------------
create or replace function public.fn_support_visits(p_limit integer default 50)
returns table (
  started_at timestamptz, ended_at timestamptz, reason text, minutes integer
) language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if v_school is null then
    raise exception 'No school context for this user' using errcode = '42501';
  end if;
  -- has_role, not may_view: see the policy comment in section 1.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may see support visits'
      using errcode = '42501';
  end if;
  return query
    select os.started_at,
           os.ended_at,
           os.reason,
           (extract(epoch from (coalesce(os.ended_at, least(now(), os.expires_at))
                                - os.started_at)) / 60)::integer
      from public.operator_sessions os
     where os.school_id = v_school
     order by os.started_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

grant  execute on function public.fn_support_visits(integer) to authenticated;
revoke execute on function public.fn_support_visits(integer) from public, anon;
