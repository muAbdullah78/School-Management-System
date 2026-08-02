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
begin
  if not public.has_role('owner','principal') then
    raise exception 'Only owner/principal may change the current session';
  end if;
  if not exists (select 1 from public.academic_sessions where id = p_session_id) then
    raise exception 'Session not found';
  end if;
  update public.academic_sessions set is_current = (id = p_session_id);
  insert into public.school_settings(id, current_session_id) values (1, p_session_id)
    on conflict (id) do update set current_session_id = excluded.current_session_id;
end;
$$;

grant execute on function public.fn_set_current_session(uuid) to authenticated;
