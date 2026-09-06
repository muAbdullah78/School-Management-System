-- =============================================================================
-- 0117 - Why this login cannot get in
--
-- 0115 replaced a wall with an explanation. A signed-in person with no school
-- used to be assumed to be the vendor and sent to the operator console, which
-- refused them; they now get a screen saying their login is not attached to a
-- school, what not to do about it, and who can fix it.
--
-- That screen is right for one of the two ways to be in that position and
-- wrong for the other.
--
--   * NOTHING EVER ATTACHED THIS LOGIN. The 0115 case. "Not attached to a
--     school yet" is exactly true.
--   * SOMEBODY CLOSED IT. A teacher who left, a parent whose access was
--     removed, a clerk deactivated on the Users screen. Their profile exists,
--     names a school, and has active = false.
--
-- The second one gets told their login is not attached to a school and to ask
-- the office to attach it. The office then looks, finds the person IS attached
-- and merely closed, and cannot see what the screen said. That is a support
-- call created by a wrong message, and the remedy is one button ("Activate")
-- already sitting on the Users screen next to their name.
--
-- WHY THE APP CANNOT WORK THIS OUT FOR ITSELF
--
-- current_school_id() requires `active`, and profiles_select requires
-- school_id = current_school_id(). So a closed login reads no profile at all,
-- by design, and the browser cannot tell "there is no row" from "there is a
-- row I am not allowed to see". Those two need opposite things said about
-- them, so something has to answer, and only a definer function can.
--
-- WHAT THIS DOES NOT DO, and would be a defect if it did. It takes no argument
-- and answers only about auth.uid(), which cannot be forged. There is nothing
-- here to point at somebody else, so it is not a way to ask which school a
-- given login belongs to.
--
-- Re-runnable.
-- =============================================================================

create or replace function public.fn_my_login_state()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_p  record;
begin
  if v_me is null then
    return jsonb_build_object('state', 'signed_out');
  end if;

  select p.active, p.role::text as role, s.name as school
    into v_p
    from public.profiles p
    left join public.schools s on s.id = p.school_id
   where p.id = v_me;

  if not found then
    -- The operator belongs to no school and that is what one IS. Said
    -- explicitly so the screen never tells the vendor their own login is
    -- broken, which is what "not attached to a school" reads as.
    if exists (select 1 from public.platform_admins where user_id = v_me) then
      return jsonb_build_object('state', 'operator');
    end if;
    return jsonb_build_object('state', 'unattached');
  end if;

  if not coalesce(v_p.active, false) then
    -- The school's NAME, not its id. The person worked there or had a child
    -- there, so it discloses nothing they did not know, and it is the one fact
    -- that turns "something is wrong" into "ring that office".
    return jsonb_build_object('state', 'closed',
                              'school', v_p.school, 'role', v_p.role);
  end if;

  return jsonb_build_object('state', 'ok', 'school', v_p.school, 'role', v_p.role);
end;
$$;

grant  execute on function public.fn_my_login_state() to authenticated;
revoke execute on function public.fn_my_login_state() from public, anon;
