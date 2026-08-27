-- =============================================================================
-- 0065 — A parent could make themselves principal
--
-- handle_new_user() decided a new login's SCHOOL and ROLE from
-- new.raw_user_meta_data. That field is whatever the browser passes to
-- auth.signUp({options:{data:{...}}}) using the PUBLIC anon key. 'principal' and
-- 'accountant' were both on its recognised-role whitelist, and a recognised role
-- was created ACTIVE.
--
-- Proven on a real database. Two strangers signed up naming a victim school:
--
--        full_name       |    role    | active
--   ---------------------+------------+--------
--    Real Owner          | owner      | t
--    Totally Normal Pare | accountant | t     <-- self-assigned
--    Also Normal         | principal  | t     <-- self-assigned
--
-- Both then passed has_role() and may_view(), so both could read that school's
-- fees, payments and children.
--
-- Every signed-in user already knows their own school_id, so the floor on this
-- was: ANY parent, teacher or clerk could create a second login and make
-- themselves PRINCIPAL of their own school. Reaching another school needed only
-- its UUID, which leaks through a screenshot or a support chat.
--
-- The whitelist was not the bug. 0059 added it, and it correctly stopped an
-- UNRECOGNISED role landing active. The bug is that a RECOGNISED role was
-- believed at all, because the thing supplying it is the attacker.
--
-- THE RULE THIS ESTABLISHES: authorisation never comes from a field the client
-- can write. Two trusted sources replace it.
--
--   1. raw_app_meta_data — settable only by the service role (the Edge
--      Functions). A browser signUp cannot write it. This is Supabase's own
--      documented split: user_metadata is user-controlled, app_metadata is not.
--   2. public.user_invites — a row an owner or principal created for a specific
--      email, which is an authorised act checked by RLS.
--
-- raw_user_meta_data is still read for ONE thing: the display name. A forged
-- full_name is a cosmetic nuisance, not a privilege.
--
-- DEPLOYMENT ORDER MATTERS. Both Edge Functions must be redeployed with this
-- migration, because they are what supply app_metadata. If the SQL lands first,
-- a brand-new school signup creates a login with NO profile and the app says
-- "this login is not attached to a school" — visible and recoverable. That is
-- the safe direction to fail; the reverse would leave the hole open.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Invitations
--
-- The path that lets a school add a teacher WITHOUT the create-teacher Edge
-- Function being deployed. Creating the invite is the authorised act; the
-- signup that follows merely redeems it.
-- ---------------------------------------------------------------------------
create table if not exists public.user_invites (
  id          uuid primary key default gen_random_uuid(),
  school_id   uuid not null references public.schools(id) on delete cascade,
  -- Stored folded and trimmed, and matched the same way. An invite for
  -- "Ayesha@School.pk" must be redeemable by a login typed "ayesha@school.pk",
  -- or the school raises a support ticket about a working feature.
  email       text not null,
  role        public.user_role not null,
  full_name   text,
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  accepted_by uuid,
  -- An owner is never invited. The first account of a school becomes owner
  -- through provisioning, and later owners are promoted on the Users screen by
  -- an existing owner. Allowing 'owner' here would put the school's top
  -- privilege behind an email address.
  constraint user_invites_not_owner check (role <> 'owner'),
  constraint user_invites_email_folded check (email = lower(btrim(email)))
);

-- One LIVE invite per email per school. Partial, so a redeemed or revoked
-- invite does not block issuing a fresh one.
create unique index if not exists user_invites_pending_key
  on public.user_invites (school_id, email) where accepted_at is null;

create index if not exists idx_user_invites_email
  on public.user_invites (email) where accepted_at is null;

alter table public.user_invites enable row level security;

-- The school's owner or principal manages its own invites. Deliberately NOT
-- may_view(): an observer must not read a list of pending logins, and 'readonly'
-- has no business here at all.
drop policy if exists user_invites_select on public.user_invites;
create policy user_invites_select on public.user_invites
  for select to authenticated
  using (school_id = public.current_school_id() and public.has_role('owner','principal'));

-- No INSERT/UPDATE/DELETE policy on purpose. Every write goes through the
-- definer functions below, so one place decides what a valid invite is — the
-- same rule 0064's platform tables follow.

-- ---------------------------------------------------------------------------
-- 2. The trigger, rewritten
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  -- TRUSTED. app_metadata can only be written by the service role, so these
  -- came from an Edge Function and not from a browser.
  v_school   uuid := nullif(new.raw_app_meta_data->>'school_id', '')::uuid;
  v_asked    text := nullif(new.raw_app_meta_data->>'role', '');
  -- UNTRUSTED, and used only for the display name.
  v_name     text := coalesce(
                       nullif(new.raw_user_meta_data->>'full_name', ''),
                       split_part(coalesce(new.email, ''), '@', 1));
  v_email    text := lower(btrim(coalesce(new.email, '')));
  v_inv      public.user_invites;
  v_matches  integer;
  v_is_first boolean;
  v_role     public.user_role;
  -- Still a whitelist even though the source is trusted: a typo in an Edge
  -- Function must not crash a signup on an enum cast, and defence in depth here
  -- costs one expression.
  v_known    boolean := coalesce(v_asked in ('principal','admin_clerk','accountant',
                                             'class_teacher','subject_teacher',
                                             'readonly','parent'), false);
begin
  -- ---- path A: an invitation, redeemed by email --------------------------
  -- Checked FIRST, so a school that invited someone gets the role it chose even
  -- if a stale client also sent metadata.
  if v_school is null and v_email <> '' then
    -- Deliberately NOT "order by created_at desc limit 1". Two schools can
    -- invite the same address — a teacher moonlighting at both is ordinary in
    -- Pakistan — and there is no honest way to choose between them: a profile
    -- carries ONE school_id, so picking either silently puts that person inside
    -- one school's children's records while the other school believes they are
    -- in. Ordering by created_at also ties when both invites are written in one
    -- transaction, where now() is identical, making the choice arbitrary rather
    -- than merely debatable. Caught by assertion 23 of tests/provisioning.sql.
    --
    -- So: exactly one live invitation is redeemed. More than one creates
    -- NOTHING and leaves them all pending, which is a state a human can see and
    -- resolve — the schools revoke one, or issue a second address.
    select count(*) into v_matches
      from public.user_invites
     where email = v_email and accepted_at is null and expires_at > now();

    if v_matches = 1 then
      select * into v_inv
        from public.user_invites
       where email = v_email and accepted_at is null and expires_at > now();

      insert into public.profiles (id, full_name, role, school_id, active)
      values (new.id, coalesce(nullif(btrim(coalesce(v_inv.full_name,'')),''), v_name),
              v_inv.role, v_inv.school_id, true)
      on conflict (id) do nothing;

      update public.user_invites
         set accepted_at = now(), accepted_by = new.id
       where id = v_inv.id;

      return new;
    elsif v_matches > 1 then
      -- Ambiguous. Create nothing and leave every invitation pending.
      return new;
    end if;
  end if;

  -- ---- path B: provisioned by an Edge Function ---------------------------
  -- No trusted school means we create NOTHING. A login with no profile is
  -- inert: the app tells the person their login is not attached to a school,
  -- and an owner can attach it on the Users screen. That is the correct
  -- outcome for an uninvited stranger, and it is what closes the hole.
  if v_school is null then
    return new;
  end if;

  select count(*) = 0 into v_is_first
  from public.profiles where school_id = v_school;

  -- First account of a school is its owner. Safe now in a way it was not
  -- before: v_school came from app_metadata, so only the signup Edge Function
  -- that just created this school can name it.
  v_role := (case when v_is_first then 'owner'
                  when v_known   then v_asked
                  else 'readonly' end)::public.user_role;

  insert into public.profiles (id, full_name, role, school_id, active)
  values (new.id, v_name, v_role, v_school,
          -- Active only when we know who this is. An Edge Function that names a
          -- school but no recognised role lands the account INERT rather than
          -- quietly giving it sight of the whole school — the defect 0059 fixed
          -- and this keeps fixed.
          (v_is_first or v_known))
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Managing invitations
-- ---------------------------------------------------------------------------
create or replace function public.fn_invite_user(
  p_email text,
  p_role public.user_role,
  p_full_name text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_id     uuid;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only an owner or principal may invite a user'
      using errcode = '42501';
  end if;
  if v_email = '' or position('@' in v_email) = 0 then
    raise exception 'A valid email address is required';
  end if;
  if p_role = 'owner' then
    raise exception 'An owner cannot be invited. Create the account with '
                    'another role, then promote it on the Users screen.';
  end if;

  -- Somebody already signed in with this address. Inviting them again would
  -- create a second profile for one person, which is how a school ends up with
  -- two logins for the same teacher and no idea which is live.
  if exists (select 1 from auth.users u
              join public.profiles p on p.id = u.id
             where lower(btrim(u.email)) = v_email and p.school_id = v_school) then
    raise exception '% already has a login at this school', v_email;
  end if;

  insert into public.user_invites (school_id, email, role, full_name, created_by)
  values (v_school, v_email, p_role,
          nullif(btrim(coalesce(p_full_name, '')), ''), auth.uid())
  on conflict (school_id, email) where accepted_at is null
    do update set role       = excluded.role,
                  full_name  = excluded.full_name,
                  created_by = excluded.created_by,
                  created_at = now(),
                  expires_at = now() + interval '7 days'
  returning id into v_id;

  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_school, auth.uid(), 'user_invited', 'user_invites', v_id::text,
          jsonb_build_object('email', v_email, 'role', p_role));

  return jsonb_build_object('id', v_id, 'email', v_email, 'role', p_role,
                            'expires_at', now() + interval '7 days');
end;
$$;

create or replace function public.fn_revoke_invite(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_email text;
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only an owner or principal may revoke an invitation'
      using errcode = '42501';
  end if;
  delete from public.user_invites
   where id = p_id and school_id = v_school and accepted_at is null
   returning email into v_email;
  if v_email is null then
    raise exception 'That invitation was not found, or it has already been used';
  end if;
  insert into public.audit_log(school_id, actor, action, entity, entity_id, after)
  values (v_school, auth.uid(), 'invite_revoked', 'user_invites', p_id::text,
          jsonb_build_object('email', v_email));
end;
$$;

drop function if exists public.fn_pending_invites();
create function public.fn_pending_invites()
returns table (id uuid, email text, role text, full_name text,
               invited_by text, created_at timestamptz, expires_at timestamptz,
               expired boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner','principal') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  return query
  select i.id, i.email, i.role::text, i.full_name, p.full_name,
         i.created_at, i.expires_at, i.expires_at <= now()
    from public.user_invites i
    left join public.profiles p on p.id = i.created_by and p.school_id = v_school
   where i.school_id = v_school and i.accepted_at is null
   order by i.created_at desc;
end;
$$;

grant execute on function public.fn_invite_user(text, public.user_role, text) to authenticated;
grant execute on function public.fn_revoke_invite(uuid) to authenticated;
grant execute on function public.fn_pending_invites() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Forensics for a database that was already exposed
--
-- The hole leaves a fingerprint: a login whose raw_user_meta_data carries a
-- 'role' key was created by the client path, because neither Edge Function ever
-- put a role there. Not proof of abuse — the old createTeacherLogin fallback did
-- exactly this legitimately — but it is the list worth reading by eye.
--
-- Run it, and check every row against the staff you actually hired:
--
--   select u.email, p.role, p.active, p.created_at, s.name
--     from auth.users u
--     join public.profiles p on p.id = u.id
--     join public.schools s on s.id = p.school_id
--    where u.raw_user_meta_data ? 'role'
--    order by p.created_at desc;
--
-- Deactivate anything you do not recognise:
--   update public.profiles set active = false where id = '<uuid>';
-- ---------------------------------------------------------------------------
