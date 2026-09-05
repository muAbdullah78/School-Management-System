-- =============================================================================
-- 0104 — A parent login attached to no family appeared on no screen
--
-- 0095 fixed this exact shape for STAFF: a login that was never attached to a
-- staff record was invisible, because the roster reads the staff table, so
-- creating a teacher login left the screen still saying "No staff yet". The fix
-- was fn_school_logins, which lists every login including the unattached ones.
--
-- It excluded parents, and said why:
--
--     -- screen. Mixing four hundred parents into a staff roster would bury the
--     and p.role <> 'parent'
--
-- That reason is right for a LINKED parent, and it hid the broken ones with
-- them. Measured on the running code, with a parent login whose family link was
-- never written:
--
--     Who can sign in            0 rows
--     the family page            0 rows
--     public.profiles            1 row
--     the parent's own portal    {"children": [], "full_name": "Unlinked Parent"}
--
-- So the parent sits at home looking at an empty portal with their own name at
-- the top of it, the office has no screen anywhere that shows the login exists,
-- and the only remedy anybody can find is to create a SECOND login for the same
-- address, which fails because the address is taken. There is no way out of that
-- state from inside the product.
--
-- IT IS REACHABLE BY AN ORDINARY FAILURE. createParentLogin does two things in
-- sequence: the edge function creates the auth user and the profile, and then
-- fn_link_parent writes the family. A dropped connection, an edge function that
-- is a version behind, or any error between those two awaits leaves the orphan.
-- That is not a hypothetical: the app already carries a warning banner about
-- exactly one of those failure modes.
--
-- THE CHANGE IS ONE CLAUSE, and it keeps 0095's reason intact:
--
--     and (p.role <> 'parent' or p.family_id is null)
--
-- A parent attached to a family is still kept out of the staff roster, which is
-- what stops four hundred of them burying it. A parent attached to NOTHING is
-- shown, because there are never many of them and each one is a person who
-- cannot use the thing they were given.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_school_logins()
returns table (
  profile_id uuid, full_name text, email text, role public.user_role,
  active boolean, staff_id uuid, staff_name text, last_sign_in_at timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may see who can sign in'
      using errcode = '42501';
  end if;

  return query
  select p.id,
         p.full_name,
         u.email::text,
         p.role,
         p.active,
         s.id,
         s.full_name,
         u.last_sign_in_at
  from public.profiles p
  left join auth.users u on u.id = p.id
  left join public.staff s on s.profile_id = p.id
  where p.school_id = public.current_school_id()
    -- 0095's rule, with the hole closed. A parent WITH a family stays out of the
    -- staff roster: four hundred of them would bury it, and they are already
    -- listed on their own family's page. A parent with NO family is on no other
    -- screen in the product, so they belong here.
    and (p.role <> 'parent' or p.family_id is null)
  -- Unattached first: the whole point of this list is the login nobody has
  -- connected to anybody, and it is the one a school has to act on.
  order by (s.id is null) desc, p.full_name;
end;
$$;

revoke all on function public.fn_school_logins() from public, anon;
grant execute on function public.fn_school_logins() to authenticated;

do $assert$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'fn_school_logins'
      and p.prosrc like '%p.family_id is null%')
  then
    raise exception '0104: fn_school_logins still hides a parent login that '
      'belongs to no family, and that login is on no other screen';
  end if;
end $assert$;
