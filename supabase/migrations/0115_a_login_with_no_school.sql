-- =============================================================================
-- 0115 - A school signed up and its owner could not get in
--
-- WHAT HAPPENED, IN THE ORDER IT HAPPENED
--
-- A real school filled in the signup form. The school row was created, the trial
-- was created, the login was created and the password worked. Then the owner was
-- shown "Not available. This area is for the system operator." and a Sign out
-- button, and signing in again showed the same thing. Twice, with two different
-- schools, both of which are sitting in the operator console looking like
-- ordinary trialing customers with nobody able to open them.
--
-- The missing piece was the profiles row. Without it current_school_id() returns
-- null, the browser reads no profile, and the app concludes the only thing a
-- signed-in user with no school can be: the operator. So it sent a school owner
-- to the operator's console, which then correctly refused them.
--
-- WHY THE PROFILE WAS MISSING
--
-- Since 0065 the profile is created by handle_new_user(), an AFTER INSERT
-- trigger on auth.users that reads the school out of raw_app_meta_data. Only the
-- service role can write app metadata, which is exactly why the trigger trusts
-- it and trusts nothing else.
--
-- The auth service does not always write it in the same statement that inserts
-- the row. Some versions INSERT the user and then UPDATE app_metadata onto it a
-- moment later, in the same transaction. An AFTER INSERT trigger sees the first
-- statement and nothing else, so it reads app metadata that contains only
-- {"provider":"email"}, finds no school, and by design creates nothing.
--
-- Reproduced on a fresh database with the whole migration set applied. Two
-- signups, identical except for how app metadata arrives:
--
--     name    |  email   | has_profile | role  | active
--   ----------+----------+-------------+-------+--------
--    Repro A  | a@x.test | t           | owner | t      <- written in the insert
--    Repro B  | b@x.test | f           |       |        <- written in an update
--
-- Repro B is the school in the console that nobody can open.
--
-- THIS WAS ALREADY KNOWN AND ONLY HALF FIXED. create-teacher stopped depending
-- on the trigger and writes the profile itself, after a school reported exactly
-- this for a teacher and then for a parent. The comment left there says, in
-- plain words, "public signup goes through the same trigger and has no such
-- fallback". That was correct, and it was left standing.
--
-- WHAT THIS MIGRATION CHANGES
--
--   1. The decision moves out of the trigger into fn__attach_login(uuid), so
--      there is ONE implementation of "which school and which role does this
--      login belong to". The trigger calls it, the repair sweep at the bottom of
--      this file calls it, and the operator's repair button calls it. Three
--      callers, one rule, nothing to drift.
--   2. The trigger now fires on INSERT and on UPDATE OF raw_app_meta_data. So it
--      no longer matters which way the auth service writes it: whichever
--      statement carries the school is the statement that attaches the profile.
--   3. It is idempotent. A login that already has a profile returns immediately
--      and nothing is touched, so firing twice, or on an unrelated metadata
--      edit years later, cannot move somebody between schools or reopen a
--      closed account.
--   4. Two things that could abort a signup no longer can: a malformed uuid in
--      app metadata, and a school_id naming a school that no longer exists.
--      Both now create nothing and say so, instead of raising inside a trigger
--      on auth.users.
--   5. The operator can see it and fix it. fn_platform_unattached_logins() lists
--      every login whose app metadata names a real school but which has no
--      profile, and fn_platform_attach_login() attaches one. A tab appears in
--      the console only when the list is not empty, because this is meant to be
--      permanently empty and a tab that is always there teaches people to stop
--      reading the nav.
--   6. The sweep at the bottom repairs the logins already stranded, which is the
--      two schools now in the console.
--
-- THE EDGE FUNCTIONS ARE FIXED TOO, IN THE SAME COMMIT, and deliberately do not
-- depend on this file. signup-school and create-school-owner now read the
-- profile back and write it themselves if it is absent, the way create-teacher
-- already does. So redeploying them fixes new signups with no SQL at all, and
-- this migration fixes the ones already broken and stops the class of fault
-- rather than the instance.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The one decision
--
-- Ordinary text return values, not raises. Every caller wants to know what
-- happened and only one of them is a trigger, and a raise inside a trigger on
-- auth.users fails the signup that was otherwise about to succeed.
--
-- SECURITY DEFINER and revoked from every client role: it decides which school
-- a login belongs to, which is the whole tenancy boundary.
-- ---------------------------------------------------------------------------
create or replace function public.fn__attach_login(p_user uuid)
returns text language plpgsql security definer set search_path = public, auth as $$
declare
  v_email_raw  text;
  v_name_raw   text;
  v_school_txt text;
  v_school     uuid;
  v_asked      text;
  v_name       text;
  v_email      text;
  v_inv        public.user_invites;
  v_matches    integer;
  v_is_first   boolean;
  v_role       public.user_role;
  v_known      boolean;
begin
  if p_user is null then
    return 'no login given';
  end if;

  -- IDEMPOTENT, AND THIS LINE IS WHY THE UPDATE PATH IS SAFE TO ADD. The
  -- trigger now fires whenever app metadata is written, which includes edits
  -- made years later for reasons that have nothing to do with provisioning.
  -- This function supplies a profile that is missing; it never revisits one
  -- that exists. So a metadata edit cannot move a teacher into another school,
  -- cannot promote anybody, and cannot reactivate a closed login.
  if exists (select 1 from public.profiles where id = p_user) then
    return 'already attached';
  end if;

  -- EACH KEY READ BY NAME, not by pulling the whole jsonb document into a
  -- variable and reading keys off that. Both work; only one of them can be
  -- audited. supabase/check-metadata-trust.py greps every function body for
  -- reads of raw_user_meta_data and fails on any key that is not on its
  -- display-only allow-list, and that guard is the thing standing between this
  -- function and the defect 0065 fixed. A read spelled through a variable is
  -- invisible to it, so the guard would go quietly vacuous exactly here.
  --
  -- school_id is taken as TEXT and cast further down, inside a block that can
  -- catch it. Casting in this SELECT would put the exception outside any
  -- handler and back inside a trigger on auth.users, which is the failure this
  -- migration exists to remove.
  select u.email,
         nullif(u.raw_user_meta_data->>'full_name', ''),
         nullif(u.raw_app_meta_data->>'school_id', ''),
         nullif(u.raw_app_meta_data->>'role', '')
    into v_email_raw, v_name_raw, v_school_txt, v_asked
    from auth.users u where u.id = p_user;
  if not found then
    return 'no such login';
  end if;

  -- The operator belongs to no school and must not be given one. Their console
  -- works BECAUSE they have no profile, so an invitation sent to the vendor's
  -- own address must not quietly attach them to a customer and take their
  -- console away.
  if exists (select 1 from public.platform_admins where user_id = p_user) then
    return 'platform operator';
  end if;

  -- TRUSTED. app metadata is writable only by the service role, so both values
  -- came from an Edge Function and not from a browser.
  begin
    v_school := v_school_txt::uuid;
  exception when others then
    return 'app metadata names something that is not a school id';
  end;
  -- UNTRUSTED, and used for the display name only. A forged name is cosmetic;
  -- a forged role or school is a tenant breach, which is why neither is read
  -- from here.
  v_name  := coalesce(v_name_raw, split_part(coalesce(v_email_raw, ''), '@', 1));
  v_email := lower(btrim(coalesce(v_email_raw, '')));
  -- Still a whitelist even though the source is trusted. A typo in an Edge
  -- Function must not crash a signup on an enum cast.
  v_known := coalesce(v_asked in ('principal','admin_clerk','accountant',
                                  'class_teacher','subject_teacher',
                                  'readonly','parent'), false);

  -- ---- path A: an invitation, redeemed by email --------------------------
  -- Checked first, so a school that invited somebody gets the role it chose
  -- even if a stale client also sent metadata.
  if v_school is null and v_email <> '' then
    -- Deliberately not "order by created_at desc limit 1". Two schools can
    -- invite the same address, a teacher working at both is ordinary here, and
    -- a profile carries ONE school_id, so picking either silently puts that
    -- person inside one school's children's records while the other believes
    -- they are in. Exactly one live invitation is redeemed; more than one
    -- creates nothing and leaves them all pending, which a human can see and
    -- resolve.
    select count(*) into v_matches
      from public.user_invites
     where email = v_email and accepted_at is null and expires_at > now();

    if v_matches = 1 then
      select * into v_inv
        from public.user_invites
       where email = v_email and accepted_at is null and expires_at > now();

      insert into public.profiles (id, full_name, role, school_id, active)
      values (p_user,
              coalesce(nullif(btrim(coalesce(v_inv.full_name, '')), ''), v_name),
              v_inv.role, v_inv.school_id, true)
      on conflict (id) do nothing;

      update public.user_invites
         set accepted_at = now(), accepted_by = p_user
       where id = v_inv.id;

      return 'invitation redeemed';
    elsif v_matches > 1 then
      return 'more than one invitation for that address';
    end if;
  end if;

  -- ---- path B: provisioned by an Edge Function ---------------------------
  -- No trusted school means nothing is created. A login with no profile is
  -- inert, the app now says so in plain words instead of showing the operator's
  -- gate, and an owner can attach it on the Users screen. That is the correct
  -- outcome for an uninvited stranger and it is what 0065 closed.
  if v_school is null then
    return 'no school named';
  end if;

  -- A school that has been purged since the login was minted. The profiles
  -- foreign key would refuse the row, and refusing it inside a trigger on
  -- auth.users fails a signup with a constraint message. Say it instead.
  if not exists (select 1 from public.schools where id = v_school) then
    return 'app metadata names a school that no longer exists';
  end if;

  select count(*) = 0 into v_is_first
    from public.profiles where school_id = v_school;

  -- First account of a school is its owner. Safe because v_school came from app
  -- metadata, so only the Edge Function that just created this school can name
  -- it.
  v_role := (case when v_is_first then 'owner'
                  when v_known   then v_asked
                  else                'readonly' end)::public.user_role;

  insert into public.profiles (id, full_name, role, school_id, active)
  values (p_user, v_name, v_role, v_school,
          -- Active only when we know who this is. An Edge Function that names a
          -- school but no recognised role lands the account inert rather than
          -- quietly giving it sight of the whole school.
          (v_is_first or v_known))
  on conflict (id) do nothing;

  return case when v_is_first then 'attached as the school owner'
              else 'attached as ' || replace(v_role::text, '_', ' ')
                   || case when v_known then '' else ' (closed until an owner opens it)' end
         end;
end;
$$;

revoke all on function public.fn__attach_login(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The trigger, now a wrapper
--
-- Kept named on_auth_user_created even though it fires on updates too, because
-- renaming it would leave bundle 1's copy in place beside this one on any
-- database that re-pastes bundle 1, and two triggers doing the same idempotent
-- work is a thing nobody would ever look for. verify.sql asserts the UPDATE
-- event is present, so a stale re-paste of bundle 1 is reported rather than
-- silently undoing this.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  perform public.fn__attach_login(new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of raw_app_meta_data on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- 3. What the operator can see, and what they can do about it
--
-- This list is meant to be empty for ever. It exists because it was NOT empty
-- and nothing in the product could show it: a school with a login and no
-- profile looks, in the console, exactly like a school that signed up this
-- morning and has not logged in yet. Three weeks of that is a lost customer who
-- never told anybody why.
-- ---------------------------------------------------------------------------
create or replace function public.fn_platform_unattached_logins()
returns table (user_id uuid, email text, school_id uuid, school_name text,
               asked_role text, created_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  -- JOINED ON TEXT, NOT ON A CAST. app metadata is a jsonb document, so
  -- school_id there is whatever was written into it, and (…)::uuid on a
  -- malformed value fails the WHOLE listing rather than skipping one row.
  -- Comparing s.id::text instead cannot fail: every writer of this field takes
  -- the value from the database, so it is already canonical uuid text.
  --
  -- The join is also the DEFINITION of what belongs on this list. A login whose
  -- metadata names nothing, or names a school that has since been purged,
  -- cannot be attached to anything and does not appear: it is a login with no
  -- school in the ordinary way, which is what a departed member of staff is.
  return query
    select u.id, u.email::text, s.id, s.name::text,
           nullif(u.raw_app_meta_data->>'role', '')::text, u.created_at
      from auth.users u
      join public.schools s on s.id::text = u.raw_app_meta_data->>'school_id'
     where not exists (select 1 from public.profiles p where p.id = u.id)
     order by u.created_at;
end;
$$;

grant  execute on function public.fn_platform_unattached_logins() to authenticated;
revoke execute on function public.fn_platform_unattached_logins() from public, anon;

create or replace function public.fn_platform_attach_login(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_outcome text; v_school uuid; v_role text;
begin
  if not public.is_platform_admin() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  v_outcome := public.fn__attach_login(p_user);
  select p.school_id, p.role::text into v_school, v_role
    from public.profiles p where p.id = p_user;

  -- Written to the SCHOOL's own audit trail, not just ours. A login inside a
  -- customer's data created by the vendor is exactly the kind of thing the
  -- school is entitled to see a record of.
  if v_school is not null then
    perform public.fn__log_operator_action('login_attached', v_school,
      jsonb_build_object('user_id', p_user, 'role', v_role, 'outcome', v_outcome));
  end if;

  return jsonb_build_object('outcome', v_outcome, 'school_id', v_school, 'role', v_role);
end;
$$;

grant  execute on function public.fn_platform_attach_login(uuid) to authenticated;
revoke execute on function public.fn_platform_attach_login(uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. Repair what is already broken
--
-- WRAPPED SO IT CANNOT TAKE THE BUNDLE DOWN WITH IT. The Supabase SQL editor
-- runs a pasted file as ONE transaction, so an uncaught raise anywhere in it
-- rolls back every migration in the bundle. A repair sweep is the last thing
-- that should be allowed to do that: it is a convenience, and the operator
-- console can do the same job by hand.
--
-- Each login is attached in its own sub-block, so one that cannot be repaired
-- does not stop the rest.
-- ---------------------------------------------------------------------------
do $backfill$
declare
  v_before integer;
  v_after  integer;
  r        record;
begin
  -- The same set the operator's list shows and verify.sql counts: a login with
  -- no profile whose app metadata names a school that EXISTS. One that names a
  -- purged school or nothing at all cannot be attached to anything, so counting
  -- it here would report a permanent failure with nothing to do about it.
  select count(*) into v_before from auth.users u
   where not exists (select 1 from public.profiles p where p.id = u.id)
     and exists (select 1 from public.schools s
                  where s.id::text = u.raw_app_meta_data->>'school_id');

  if v_before = 0 then
    raise notice '0115: no login is stranded without a school. Nothing to repair.';
    return;
  end if;

  for r in
    select u.id from auth.users u
     where not exists (select 1 from public.profiles p where p.id = u.id)
       and exists (select 1 from public.schools s
                    where s.id::text = u.raw_app_meta_data->>'school_id')
  loop
    begin
      perform public.fn__attach_login(r.id);
    exception when others then
      raise warning '0115: could not attach login %: %', r.id, sqlerrm;
    end;
  end loop;

  select count(*) into v_after from auth.users u
   where not exists (select 1 from public.profiles p where p.id = u.id)
     and exists (select 1 from public.schools s
                  where s.id::text = u.raw_app_meta_data->>'school_id');

  raise notice '0115: % stranded login(s) found, % attached, % still stranded.',
    v_before, v_before - v_after, v_after;
  if v_after > 0 then
    raise notice '0115: open the operator console, tab "Logins with no school", for the rest.';
  end if;
exception when others then
  raise warning '0115: the repair sweep could not run (%). Nothing else in this '
    'file is affected. Open the operator console, tab "Logins with no school".', sqlerrm;
end
$backfill$;
