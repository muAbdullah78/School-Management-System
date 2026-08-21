-- =============================================================================
-- 0037 — Make the parent portal reachable.
--
-- THE BUG THIS FIXES
--
-- Migration 0033 built the whole parent portal: fn_portal_me, child fee
-- history, attendance, results, an enumeration-proof child guard, and a
-- published_at gate on result cards. Fourteen tests cover it. Not one line of
-- it could ever run, because there was no way to tell the system which family a
-- parent belongs to.
--
--   * fn_link_parent is the ONLY code in the repo that writes
--     profiles.family_id — and it had zero callers. No wrapper in the app, no
--     screen, no other SQL function.
--   * handle_new_user writes id, full_name, role and school_id. Not family_id.
--   * So my_family_id() returned null for every parent account, which made
--     fn__assert_my_child raise 'Not a parent account', which made
--     fn_portal_child_fees / _attendance / _results all throw. fn_portal_me
--     returned an empty child list.
--
-- A parent login created through the app landed in a portal that was either
-- empty or erroring, every time, with no way to fix it from inside the product.
--
-- Worse, the login could not be created in the first place: the create-teacher
-- Edge Function validates the requested role against an allow-list that did not
-- include 'parent', so asking for one came back "Invalid role".
--
-- WHAT THIS ADDS
--
--   1. fn_family_parents  — who can already see this family's portal. Needed
--      before creating anything, or a school ends up with four logins for one
--      father and no idea which one he actually uses.
--   2. fn_unlink_parent   — revoke access. A guardian changes, a couple
--      separates, a phone is lost. Without this, granting access is
--      irreversible, which makes it something a school is right to be afraid
--      of.
--
--   3. Enforcement of profiles.active, which nothing read — so the
--      "Deactivate" button in Settings was decorative and a dismissed clerk
--      kept every permission. Found while writing the revoke above.
--   4. A guard so enforcing that cannot let a school lock itself out by
--      deactivating its last owner.
--
-- fn_link_parent itself is unchanged and was always correct. The gap was
-- everything around it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who can see this family's portal?
--
-- The email lives in auth.users, which the app cannot read directly — so this
-- is SECURITY DEFINER and joins on the caller's behalf. That makes the guards
-- load-bearing rather than decorative:
--
--   * is_staff() — a parent must never be able to enumerate other logins,
--     including the other logins on their own family.
--   * assert_own('families') — without it, passing an arbitrary family id would
--     read another school's parent emails out of auth.users. This function is
--     the only place in the schema that reads auth.users on request, so it is
--     the one place that check absolutely cannot be skipped.
-- ---------------------------------------------------------------------------
create or replace function public.fn_family_parents(p_family_id uuid)
returns table (profile_id uuid, full_name text, email text, active boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  perform public.assert_own('families', p_family_id);

  return query
  select p.id, p.full_name, u.email::text, p.active
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.family_id = p_family_id
    and p.role = 'parent'
    and p.school_id = public.current_school_id()
  order by p.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Revoke a parent's access.
--
-- Deliberately NOT a delete. Deleting the auth user needs the service key and
-- would also erase the record that this person once had access, which is
-- exactly the thing a school wants to be able to show later. Detaching the
-- family is what cuts the data off: my_family_id() goes null and every portal
-- read refuses.
--
-- active=false is set as well, and section 3 below is what makes that mean
-- anything — until this migration it did not.
-- ---------------------------------------------------------------------------
create or replace function public.fn_unlink_parent(p_profile_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may remove portal access';
  end if;
  perform public.assert_own('profiles', p_profile_id);

  if (select role from public.profiles where id = p_profile_id) <> 'parent' then
    raise exception 'That account is not a parent account';
  end if;

  update public.profiles
     set family_id = null, active = false
   where id = p_profile_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Make "Deactivate" actually deactivate.
--
-- A SEPARATE BUG, found while writing the revoke above.
--
-- profiles.active is written by Settings -> Users & Roles ("Deactivate") and is
-- read by NOTHING. Not by current_school_id(), not by has_role(), not by
-- is_staff(), not by a single RLS policy. The button has always been
-- decorative: a school that dismisses a clerk, clicks Deactivate and believes
-- access is cut is wrong — that clerk keeps every permission they had,
-- including the fee counter, until the login is deleted in Supabase by hand.
--
-- Fixed at the two chokepoints every other check already flows through, so
-- nothing else has to be touched:
--
--   * current_school_id() returns NULL for an inactive profile. Every RLS
--     policy in the schema is `school_id = public.current_school_id()`, and
--     assert_own() is built on it, so a null there closes all of them at once.
--   * has_role() and is_staff() return false. Belt and braces: these are the
--     role guards inside the SECURITY DEFINER functions, which do not all go
--     through RLS.
--
-- Enforcing this creates a new way to break a school: an owner deactivating
-- themselves, or the last owner, would lock everyone out of the school with no
-- route back in except the SQL editor. Section 4 refuses that.
-- ---------------------------------------------------------------------------
create or replace function public.current_school_id() returns uuid
language sql stable security definer set search_path = public as $$
  select school_id from public.profiles where id = auth.uid() and active;
$$;

create or replace function public.has_role(variadic roles public.user_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active and p.role = any(roles)
  );
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.active and p.role <> 'parent' from public.profiles p where p.id = auth.uid()),
    false);
$$;

-- ---------------------------------------------------------------------------
-- 4. Do not let a school lock itself out.
--
-- With section 3 live, deactivating the last active owner would leave nobody
-- who can reactivate anyone — has_role('owner') would be false for everybody.
-- A BEFORE UPDATE trigger is the right place: it catches the Settings screen,
-- a stray SQL update, and anything added later, rather than trusting each
-- caller to remember.
-- ---------------------------------------------------------------------------
create or replace function public.guard_last_owner_active() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active and old.role = 'owner' then
    if not exists (
      select 1 from public.profiles p
      where p.school_id = old.school_id
        and p.role = 'owner'
        and p.active
        and p.id <> old.id
    ) then
      raise exception 'This is the school''s only active owner — make someone else an owner first';
    end if;
  end if;

  -- Changing the last active owner's ROLE has exactly the same effect.
  if old.active and new.active and old.role = 'owner' and new.role <> 'owner' then
    if not exists (
      select 1 from public.profiles p
      where p.school_id = old.school_id
        and p.role = 'owner'
        and p.active
        and p.id <> old.id
    ) then
      raise exception 'This is the school''s only active owner — make someone else an owner first';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_profiles_last_owner on public.profiles;
create trigger trg_profiles_last_owner
  before update on public.profiles
  for each row execute function public.guard_last_owner_active();

-- ---------------------------------------------------------------------------
-- 5. Grants.
--
-- fn_family_parents is granted to authenticated but gated on is_staff()
-- INSIDE the function, so a signed-in parent calling it directly gets 42501.
-- ---------------------------------------------------------------------------
grant execute on function public.fn_family_parents(uuid) to authenticated;
grant execute on function public.fn_unlink_parent(uuid)  to authenticated;

revoke all on function public.fn_family_parents(uuid) from anon;
revoke all on function public.fn_unlink_parent(uuid)  from anon;
