-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0116_the_school_keeps_the_keys.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0116 - The school keeps the keys
--
-- TWO PROBLEMS, ONE SUBJECT: the login addresses a school hands out.
--
-- PROBLEM ONE. In Pakistan a private school does not collect working email
-- addresses from parents. It invents them, or reuses one it already has, and
-- names repeat: three schools in one city can each decide that the father of
-- their Muhammad Ali is muhammadali786@gmail.com. auth.users already refuses a
-- duplicate address platform-wide, so the duplicate is never CREATED. What
-- happens instead is worse for the office: the clerk types a name, an address
-- and a password, presses Create, waits, and gets back the auth service's own
-- words, after the fact, with no idea which of the three fields was the problem
-- or what to do next. There was no way to ask the question BEFORE filling in
-- the form.
--
-- PROBLEM TWO, and it is the one that loses a family. Those addresses are
-- often not real, so "Forgot password" sends a reset link into a mailbox that
-- does not exist. Until now the app said so, on the student profile, in as many
-- words:
--
--     "The password is not saved anywhere you can read it back. If it is lost
--      the parent has to use Forgot password."
--
-- For a made-up address that sentence describes a dead end. A parent who
-- forgets their password is locked out for ever, and the office's only remedy
-- was to delete the login and make another, which is refused, because the
-- address is taken by the login they are trying to replace.
--
-- WHAT THIS ADDS
--
--   1. fn_login_email_available(text) - ask before you type. It answers for
--      the whole platform, and answers in far more detail about the caller's
--      OWN school, because "that address already signs in here as Miss Ayesha,
--      class teacher" is the answer the office actually needs and revealing it
--      leaks nothing.
--   2. login_secrets - the school's key ring. The password the office set for a
--      parent, a teacher or a clerk, retrievable by the owner or principal of
--      that school and by nobody else on earth, including us.
--
-- THE ARGUMENT FOR STORING A PASSWORD AT ALL, because it is normally indefensible
--
-- An owner or principal can already change any password in their school to
-- whatever they like. They therefore already hold full access to every parent
-- and teacher account in the building. Remembering the password they chose
-- grants them nothing they did not have; it saves them from having to overwrite
-- somebody's working password in order to help them.
--
-- What IS new is the exposure if the database itself leaks. Weighed honestly:
-- that same leak already contains every child's name, address, marks, medical
-- notes and fee history, which is far more sensitive than a parent's password
-- to a portal showing that same child's fees. The credential adds little to a
-- breach that has already happened, and it prevents a certain, frequent,
-- everyday harm.
--
-- SO THE FENCES ARE THE DESIGN. All of them, deliberately:
--
--   * NO school_id COLUMN. This is not an oversight, it is the point.
--     fn__school_data_tables() finds tables BY that column, and the vendor's
--     offboarding export reads every table it finds. A school_id here would
--     have put every school's assigned passwords into an export WE can take.
--     Scoped through profiles.school_id instead, which is also the more honest
--     scoping: there is no denormalised copy that can disagree with the profile.
--   * NEVER AN OWNER. The owner's own password is not stored, ever. Owners have
--     real addresses with working password recovery, and one leaked owner
--     credential is the whole school rather than one family.
--   * RLS ON, FORCED, AND NO POLICIES. Nothing is granted to anon or
--     authenticated. There is no query any client can write that reaches this
--     table; the four functions below are the only way in, the same shape as
--     payment_method_tokens in 0112.
--   * OWNER AND PRINCIPAL ONLY. Not a clerk, not an accountant, not a class
--     teacher, and explicitly not 'readonly': an observer exists to look at
--     everything and change nothing, and a stored credential is a change
--     waiting to happen.
--   * NOT THE OPERATOR. is_staff() and may_view() honour an open support
--     session since 0074, which is how we can help a school over the phone.
--     These functions ask has_role(), which deliberately does not, so a support
--     visit cannot read them. That is not a side effect of reusing a helper; it
--     is why has_role was chosen.
--   * EVERY REVEAL IS COUNTED, with who looked last and when, shown to the
--     school. A principal reading forty parent passwords leaves a trace their
--     owner can see.
--   * A STALE ENTRY SAYS SO. See the fingerprint below.
--
-- WHY THERE IS A FINGERPRINT
--
-- A parent can change their own password from inside the portal, and nothing
-- server-side sees the value. The stored copy then silently stops working, the
-- office reads it out over the telephone, it fails, and the feature is never
-- trusted again. So the moment the office sets a password we record a
-- fingerprint of what the auth service stored, and every listing recomputes it.
-- If it no longer matches, the row is shown as changed by that person since,
-- with the remedy beside it. The fingerprint is a hash of an already-salted
-- bcrypt hash, salted again with the user id, and it never leaves the database.
--
-- WHY THE AVAILABILITY CHECK IS NOT RATE LIMITED, since that is the first thing
-- a reviewer should ask
--
-- Because it grants nothing new. Any owner or principal can already discover
-- whether an address is taken by trying to create a login with it and reading
-- the refusal: one request per address, exactly the cost of this function. Every
-- product with unique addresses answers this question, Gmail included; it is
-- inherent to uniqueness, not a defect. This function is if anything the safer
-- of the two, because it creates nothing when the answer is no. What it must
-- not do is say WHERE, and outside the caller's own school it says only yes or
-- no, with no school, no name and no role. If abuse ever appears, the gateway
-- in front of PostgREST is the layer for it, not a counter table here.
--
-- Re-runnable.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Ask before you type
-- ---------------------------------------------------------------------------
create or replace function public.fn_login_email_available(p_email text)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_school uuid := public.current_school_id();
  v_here   record;
  v_inv    record;
begin
  -- has_role, not may_view: see the header. A support visit must not be able to
  -- probe the platform's address list, and an observer has no business creating
  -- logins so has no business checking one.
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may check a login address'
      using errcode = '42501';
  end if;
  if v_school is null then
    raise exception 'Your login is not attached to a school' using errcode = '42501';
  end if;

  if v_email = '' or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object(
      'available', false, 'why', 'not_an_address',
      'message', 'That does not look like an email address.');
  end if;

  -- THIS SCHOOL'S OWN, ANSWERED IN FULL. The office is asking about somebody
  -- they can already see on their own Users screen, so naming them is not a
  -- disclosure, and "already signs in here as Miss Ayesha, class teacher" ends
  -- the question where "that address is taken" starts an argument.
  select p.full_name, p.role::text, p.active into v_here
    from auth.users u
    join public.profiles p on p.id = u.id
   where lower(btrim(u.email)) = v_email and p.school_id = v_school;
  if found then
    return jsonb_build_object(
      'available', false, 'why', 'in_use_here',
      'message', 'That address already signs in to this school'
        || coalesce(' as ' || nullif(btrim(coalesce(v_here.full_name, '')), ''), '')
        || ' (' || replace(v_here.role, '_', ' ')
        || case when v_here.active then '' else ', closed' end || ').'
        || ' Use the key ring under Settings, Users to see or change its password'
        || ' rather than making a second login.',
      'here', jsonb_build_object('full_name', v_here.full_name,
                                 'role', v_here.role, 'active', v_here.active));
  end if;

  -- THIS SCHOOL'S OWN PENDING INVITATION. Same reasoning, and it stops the
  -- office issuing a second invitation to an address it has already invited,
  -- which is how two live invitations for one address happen at one school.
  select i.role::text, i.expires_at into v_inv
    from public.user_invites i
   where i.email = v_email and i.school_id = v_school
     and i.accepted_at is null and i.expires_at > now();
  if found then
    return jsonb_build_object(
      'available', false, 'why', 'invited_here',
      'message', 'You have already invited that address as '
        || replace(v_inv.role, '_', ' ') || '. It is waiting for them to sign up.');
  end if;

  -- ANOTHER SCHOOL. Yes or no and nothing else: no school, no name, no role,
  -- no date. A school must not be able to learn that a particular teacher has
  -- an account at a particular competitor.
  if exists (select 1 from auth.users u where lower(btrim(u.email)) = v_email) then
    return jsonb_build_object(
      'available', false, 'why', 'in_use_elsewhere',
      'message', 'That address is already in use on The School Manager, so it '
        || 'cannot be used again. Choose another one.');
  end if;

  -- A LIVE INVITATION SOMEWHERE ELSE IS ALSO A REFUSAL, and this one prevents a
  -- silent failure rather than a visible one. Two live invitations for one
  -- address create NO profile at all (0065: a profile carries one school_id and
  -- there is no honest way to choose between two schools), so the person signs
  -- up successfully and lands nowhere. Refusing here means one of the two
  -- schools finds out now, at the keyboard, instead of both of them believing
  -- they have a teacher who cannot see anything.
  if exists (select 1 from public.user_invites i
              where i.email = v_email and i.accepted_at is null
                and i.expires_at > now()) then
    return jsonb_build_object(
      'available', false, 'why', 'invited_elsewhere',
      'message', 'Another school has already invited that address and is waiting '
        || 'for them to sign up. Two invitations for one address cancel each '
        || 'other out, so choose a different address.');
  end if;

  return jsonb_build_object(
    'available', true, 'why', 'available',
    'message', 'That address is free to use.');
end;
$$;

grant  execute on function public.fn_login_email_available(text) to authenticated;
revoke execute on function public.fn_login_email_available(text) from public, anon;

-- ---------------------------------------------------------------------------
-- 2. The key ring
--
-- One row per login, keyed on the profile. NO school_id: see the header.
-- ---------------------------------------------------------------------------
create table if not exists public.login_secrets (
  profile_id  uuid primary key references public.profiles(id) on delete cascade,
  -- The password the office chose. Stored so it can be read back, which is the
  -- entire purpose of the table and the whole of its risk.
  password    text not null,
  set_by      uuid references public.profiles(id) on delete set null,
  set_at      timestamptz not null default now(),
  -- What the auth service was holding at the moment the office set it. A hash
  -- of a salted bcrypt hash, salted again with the user id. Never returned.
  fingerprint text,
  -- Counted rather than kept as a history. The readers are the owner and the
  -- principal, usually one or two people, so "has anybody looked, who last, and
  -- when" answers the question an owner asks; a full log of every reveal would
  -- grow without bound to answer a question nobody has yet asked. If that
  -- changes, a table is the answer, and it must have NO school_id either.
  reads       integer not null default 0,
  read_by     uuid references public.profiles(id) on delete set null,
  read_at     timestamptz
);

comment on table public.login_secrets is
  'The password a school assigned to one of its own non-owner logins, so the '
  'office can tell a parent again. Reachable only through fn_school_key_ring, '
  'fn_reveal_login_password and fn_remember_login_password. Deliberately has no '
  'school_id column, so the vendor offboarding export cannot see it.';

alter table public.login_secrets enable row level security;
alter table public.login_secrets force row level security;
-- NOTHING is granted and NO policy exists. Supabase grants the client roles on
-- new tables in public by default, so this revoke is what actually seals it.
revoke all on table public.login_secrets from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Reading the ring
--
-- Two functions on purpose. The LIST never contains a password, so the office
-- can see at a glance who has one and whether it is still good without any
-- credential crossing the wire. Revealing is a separate, single, counted act
-- against one named person.
-- ---------------------------------------------------------------------------
create or replace function public.fn_school_key_ring()
returns table (
  profile_id  uuid,
  full_name   text,
  email       text,
  role        public.user_role,
  active      boolean,
  /** False when the office never saved one, or saved it before this feature. */
  has_password boolean,
  set_at      timestamptz,
  set_by_name text,
  /** True when that person has changed their own password since. The saved one
   *  will not work and the office needs to set a new one. */
  changed_since boolean,
  reads       integer,
  read_by_name text,
  read_at     timestamptz
)
language plpgsql stable security definer set search_path = public, auth as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may see the key ring'
      using errcode = '42501';
  end if;
  if v_school is null then
    raise exception 'Your login is not attached to a school' using errcode = '42501';
  end if;

  return query
  select p.id, p.full_name, u.email::text, p.role, p.active,
         s.profile_id is not null,
         s.set_at,
         sb.full_name,
         case when s.profile_id is null or s.fingerprint is null then false
              else s.fingerprint <> md5(coalesce(u.encrypted_password, '') || p.id::text)
         end,
         coalesce(s.reads, 0),
         rb.full_name,
         s.read_at
    from public.profiles p
    join auth.users u on u.id = p.id
    left join public.login_secrets s on s.profile_id = p.id
    left join public.profiles sb on sb.id = s.set_by
    left join public.profiles rb on rb.id = s.read_by
   where p.school_id = v_school
     -- The owner's own password is never on the ring, so the owner row would be
     -- a permanent "no password saved" inviting somebody to fix it. Excluded, and
     -- the screen says why.
     and p.role <> 'owner'
   order by p.role, coalesce(p.full_name, u.email::text);
end;
$$;

grant  execute on function public.fn_school_key_ring() to authenticated;
revoke execute on function public.fn_school_key_ring() from public, anon;

create or replace function public.fn_reveal_login_password(p_profile_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, auth as $$
declare
  v_school uuid := public.current_school_id();
  v_me     uuid := auth.uid();
  v_row    record;
  v_now    text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may read a saved password'
      using errcode = '42501';
  end if;
  if v_school is null then
    raise exception 'Your login is not attached to a school' using errcode = '42501';
  end if;

  select p.full_name, p.role::text, u.email::text as email, s.password, s.fingerprint,
         md5(coalesce(u.encrypted_password, '') || p.id::text) as live
    into v_row
    from public.profiles p
    join auth.users u on u.id = p.id
    join public.login_secrets s on s.profile_id = p.id
   where p.id = p_profile_id and p.school_id = v_school and p.role <> 'owner';

  if not found then
    -- One message for "not in your school", "no saved password" and "that is
    -- the owner". Distinguishing them would turn this into a way to ask whether
    -- a given uuid is a login at another school.
    raise exception 'No saved password for that login' using errcode = '42501';
  end if;

  -- COUNTED BEFORE IT IS RETURNED, so a failure between the two cannot hand out
  -- a password with no trace of it.
  update public.login_secrets
     set reads = reads + 1, read_by = v_me, read_at = now()
   where profile_id = p_profile_id;

  return jsonb_build_object(
    'email', v_row.email,
    'full_name', v_row.full_name,
    'password', v_row.password,
    'changed_since', v_row.fingerprint is not null and v_row.fingerprint <> v_row.live);
end;
$$;

grant  execute on function public.fn_reveal_login_password(uuid) to authenticated;
revoke execute on function public.fn_reveal_login_password(uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 4. Writing to the ring
--
-- CALLED BY THE APP, not by the Edge Function, and the split matters. The Edge
-- Function does the one thing only the service key can do: create the login, or
-- change its password. The remembering happens here, so there is one
-- implementation of it whichever of those two just happened, and a school
-- running a stale copy of the Edge Function still gets a key ring.
--
-- The caller already knows the password: they typed it. So this grants them
-- nothing. What it must refuse is the two things they should not be able to do:
-- write a row for another school, and write one for an owner.
-- ---------------------------------------------------------------------------
create or replace function public.fn_remember_login_password(
  p_profile_id uuid, p_password text)
returns jsonb language plpgsql volatile security definer set search_path = public, auth as $$
declare
  v_school uuid := public.current_school_id();
  v_role   public.user_role;
  v_hash   text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may save a login password'
      using errcode = '42501';
  end if;
  if v_school is null then
    raise exception 'Your login is not attached to a school' using errcode = '42501';
  end if;
  if coalesce(btrim(p_password), '') = '' then
    raise exception 'A password is required';
  end if;

  select p.role, md5(coalesce(u.encrypted_password, '') || p.id::text)
    into v_role, v_hash
    from public.profiles p join auth.users u on u.id = p.id
   where p.id = p_profile_id and p.school_id = v_school;
  if not found then
    raise exception 'That login is not in your school' using errcode = '42501';
  end if;
  if v_role = 'owner' then
    -- Not a refusal to be worked around. One leaked owner credential is the
    -- whole school, and an owner has a real address with working recovery.
    raise exception 'An owner''s own password is never saved. They use Forgot '
      'password on their own address, which is the one address on a school that '
      'has to be real.' using errcode = '42501';
  end if;

  insert into public.login_secrets (profile_id, password, set_by, set_at, fingerprint)
  values (p_profile_id, p_password, auth.uid(), now(), v_hash)
  on conflict (profile_id) do update
     set password = excluded.password,
         set_by   = excluded.set_by,
         set_at   = excluded.set_at,
         fingerprint = excluded.fingerprint,
         -- The read count belongs to the password that was read, not to the new
         -- one. Cleared with it, so "nobody has looked at this" stays true.
         reads    = 0,
         read_by  = null,
         read_at  = null;

  return jsonb_build_object('saved', true, 'profile_id', p_profile_id);
end;
$$;

grant  execute on function public.fn_remember_login_password(uuid, text) to authenticated;
revoke execute on function public.fn_remember_login_password(uuid, text) from public, anon;

-- Forgetting one. The office may decide a password should not be on the ring
-- after all, and a feature that can only ever accumulate credentials is one
-- nobody can undo their mind about.
create or replace function public.fn_forget_login_password(p_profile_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_school uuid := public.current_school_id(); v_n integer;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may do this' using errcode = '42501';
  end if;
  if v_school is null then
    raise exception 'Your login is not attached to a school' using errcode = '42501';
  end if;

  delete from public.login_secrets s
   where s.profile_id = p_profile_id
     and exists (select 1 from public.profiles p
                  where p.id = s.profile_id and p.school_id = v_school);
  get diagnostics v_n = row_count;
  return jsonb_build_object('forgotten', v_n > 0);
end;
$$;

grant  execute on function public.fn_forget_login_password(uuid) to authenticated;
revoke execute on function public.fn_forget_login_password(uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0116_the_school_keeps_the_keys.sql', '22_the_school_keeps_the_keys.sql');
end $ledger$;
