-- =============================================================================
-- 0095  Which login is which
--
-- THE PROBLEM. profiles has no email column. The address lives in auth.users,
-- which the app cannot read, so NO SCREEN ANYWHERE could tell you what address
-- a login belongs to. The consequences are all small and all daily:
--
--   * a teacher rings to say they cannot sign in, and the office has no way to
--     find out which address to check
--   * two staff both called Muhammad Ali appear in the link dropdown as
--     "Muhammad Ali" twice, and picking the wrong one gives the wrong person
--     access to the wrong class
--   * you cannot tell whether somebody already has a login before making a
--     second one for them
--
-- AND THE WORSE ONE. The staff roster reads the staff table. A login that has
-- never been attached to a staff record is therefore INVISIBLE: it exists, it
-- works, it can sign in and read every child's record, and it appears on no
-- screen. Create a teacher login and the roster still says "No staff yet",
-- which looks exactly like the creation having failed. That is what the first
-- real school saw, and they reasonably concluded the feature was broken.
--
-- So this returns every login in the school, whether or not anybody has
-- attached it to a person, with the address it signs in with.
--
-- WHY IT IS SECURITY DEFINER, AND WHAT THAT COSTS
--
-- Reading auth.users needs privileges the caller does not have. That makes the
-- two guards below load-bearing rather than decorative, exactly as in
-- fn_family_parents (0037):
--
--   * owner or principal only. A clerk has no business enumerating logins, and
--     a PARENT must never be able to: they would get every staff email in the
--     school out of auth.users.
--   * scoped to current_school_id(), which comes from the caller's own profile
--     and never from a parameter, so there is no argument to point at another
--     school.
-- =============================================================================

create or replace function public.fn_school_logins()
returns table (
  profile_id  uuid,
  full_name   text,
  email       text,
  role        public.user_role,
  active      boolean,
  staff_id    uuid,
  staff_name  text,
  last_sign_in_at timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may list logins'
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
    join auth.users u on u.id = p.id
    -- The staff row is optional on purpose: a login with no person attached is
    -- the case this function exists to make visible.
    left join public.staff s on s.profile_id = p.id
   where p.school_id = public.current_school_id()
     -- Parents are listed on the family they belong to, not on the staff
     -- screen. Mixing four hundred parents into a staff roster would bury the
     -- eight people it is actually about.
     and p.role <> 'parent'
   order by (s.id is null) desc, p.full_name;
end;
$$;

-- Postgres grants EXECUTE on a new function to PUBLIC, and anon is a member of
-- PUBLIC. This function reads auth.users, so leaving that default in place puts
-- every staff email in the school one unauthenticated call away, with only
-- has_role() in between. 0071 revoked the whole schema from anon and verify.sql
-- asserts nothing has crept back.
revoke execute on function public.fn_school_logins() from public, anon;
grant execute on function public.fn_school_logins() to authenticated;
