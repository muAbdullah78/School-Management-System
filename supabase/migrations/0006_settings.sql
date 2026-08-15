-- =============================================================================
-- Settings / school setup — the one operation that must be transactional:
-- switching which academic session is "current". Everything else in Settings
-- (school profile, creating sessions/classes/sections/subjects, editing roles)
-- is plain RLS-guarded client-side CRUD.
-- =============================================================================

-- Make one session current: clear the flag on all others, set it here, and
-- point school_settings.current_session_id at it — in one transaction so there
-- is never more than one "current" session. owner/principal only.
create or replace function public.fn_set_current_session(p_session_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only owner/principal may change the current session';
  end if;
  -- Also proves the session belongs to this school, so the UPDATE below can
  -- never be aimed at someone else's row.
  perform public.assert_own('academic_sessions', p_session_id);

  -- The `where school_id` is load-bearing. Without it this statement rewrites
  -- is_current for EVERY school in the database, clearing the current academic
  -- year for all of them — from one school pressing one button.
  update public.academic_sessions
     set is_current = (id = p_session_id)
   where school_id = v_school;

  insert into public.school_settings(school_id, current_session_id)
    values (v_school, p_session_id)
    on conflict (school_id) do update set current_session_id = excluded.current_session_id;
end;
$$;

grant execute on function public.fn_set_current_session(uuid) to authenticated;
