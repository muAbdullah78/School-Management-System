-- =============================================================================
-- Staff <-> login link. A staff record and an auth profile point at each other
-- (staff.profile_id <-> profiles.staff_id) and the mapping is 1:1. Doing this
-- from the client risks a half-linked state, so this one helper sets both sides
-- (and clears any prior link on either side) in a single transaction.
-- Everything else in the Staff module is plain RLS'd CRUD.
-- =============================================================================

create or replace function public.fn_link_staff_profile(p_staff_id uuid, p_profile_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only owner/principal may link staff to a login';
  end if;
  -- Both sides must be ours: linking our staff row to another school's login
  -- would hand that login this school's data.
  perform public.assert_own('staff', p_staff_id);
  perform public.assert_own('profiles', p_profile_id);
  if not exists (select 1 from public.staff where id = p_staff_id) then
    raise exception 'Staff not found';
  end if;

  -- detach this staff from whatever profile currently points at it
  update public.profiles set staff_id = null where staff_id = p_staff_id;

  if p_profile_id is null then
    update public.staff set profile_id = null where id = p_staff_id;
    return;
  end if;

  if not exists (select 1 from public.profiles where id = p_profile_id) then
    raise exception 'Login profile not found';
  end if;

  -- detach the target profile from any OTHER staff row
  update public.staff set profile_id = null where profile_id = p_profile_id and id <> p_staff_id;

  update public.staff set profile_id = p_profile_id where id = p_staff_id;
  update public.profiles set staff_id = p_staff_id where id = p_profile_id;
end;
$$;

grant execute on function public.fn_link_staff_profile(uuid, uuid) to authenticated;
