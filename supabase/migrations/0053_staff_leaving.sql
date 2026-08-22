-- =============================================================================
-- 0053 — When a member of staff leaves.
--
-- WHAT WAS WRONG
--
-- The staff screen had one button, "Deactivate", wired to a bare
-- `update staff set status = 'inactive'`. Three things followed from that, and
-- all three are the kind of thing a school discovers at the worst moment.
--
-- 1. IT DID NOT REVOKE THE LOGIN. Access in this system is gated on
--    profiles.active — current_school_id(), has_role() and is_staff() all read
--    it, and NOTHING anywhere reads staff.status. So a teacher who resigned,
--    was "deactivated" on the staff screen, and still had the app on their
--    phone could log in the next morning and mark attendance, enter marks and
--    read every child's record in their class. The button that looked like it
--    closed the door only greyed out a row.
--
--    Two switches existed: an obvious one that did nothing about access, and an
--    effective one (Settings → Users) that nobody would think to look for after
--    pressing the obvious one. That is worse than having only the hidden one.
--
-- 2. THE CLASS TEACHERS SCREEN THEN LIED. sections.class_teacher_id was left
--    pointing at the departed teacher — and it is what result cards print. The
--    Class Teachers screen builds its dropdown from ACTIVE staff only, so the
--    stored id matched no <option> and the select rendered "— unassigned —".
--    The screen therefore said the section had no class teacher while the
--    database still had one and the result card still printed their name. A
--    principal reading that screen has no way to find out.
--
-- 3. left_on WAS NEVER WRITTEN. The column has existed since 0001. Nothing set
--    it, so the school had no record of when anyone left — not on the screen,
--    not in a report, not in the audit log.
--
-- WHAT THIS DOES
--
-- Four functions, so that "this person has gone" is ONE action with a visible,
-- complete and reversible result:
--
--   fn_staff_leave            — record the leaving date, revoke the login,
--                               vacate the class-teacher slots, drop the
--                               current and future teaching assignments, and
--                               return a summary of exactly what it changed.
--   fn_staff_rejoin           — the undo, and the re-hire.
--   fn_staff_set_login_active — the access switch on its own, for suspension
--                               without leaving, and to clean up the legacy
--                               rows described below.
--   fn_staff_roster           — a read that can SEE the login state, which the
--                               screen previously could not: it selected from
--                               `staff` and never looked at `profiles`.
--
-- ABOUT THE LEGACY ROWS
--
-- Any staff row already marked 'inactive' by the old button is renamed to
-- 'left' here — same meaning, one spelling. Their logins are deliberately NOT
-- touched. Deactivating somebody's access from inside a migration is exactly
-- the sort of silent change that locks out a person who is still working, and
-- this migration cannot tell "resigned in March" from "clicked by mistake".
-- Instead fn_staff_roster reports login_active for people who have left, and
-- the screen shows it as a warning with a Revoke button. The school sees the
-- list and decides. left_on is left null for them, because inventing a date
-- would be a lie in a field a school may later rely on.
-- =============================================================================

-- --- One spelling for "not here any more" ------------------------------------
update public.staff set status = 'left' where status = 'inactive';

alter table public.staff drop constraint if exists staff_status_chk;
alter table public.staff add constraint staff_status_chk
  check (status in ('active', 'left'));

-- left_on only means anything for somebody who has left, and somebody who has
-- left with no date is a legacy row rather than a new mistake. The constraint
-- catches the other direction: an ACTIVE member of staff with a leaving date is
-- always a bug, and until now nothing would have said so.
alter table public.staff drop constraint if exists staff_left_on_chk;
alter table public.staff add constraint staff_left_on_chk
  check (status = 'left' or left_on is null);

comment on column public.staff.left_on is
  'Last working day. Written only by fn_staff_leave; cleared by fn_staff_rejoin.';

-- ---------------------------------------------------------------------------
-- fn_staff_roster — staff, WITH their login state and what they still hold.
--
-- The old screen read the staff table directly, which is why it could not show
-- whether a "deactivated" person could still log in: that fact lives in
-- profiles, and PostgREST cannot embed it unambiguously because staff and
-- profiles reference each other twice (staff.profile_id and profiles.staff_id).
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_roster()
returns table (
  id            uuid,
  full_name     text,
  designation   text,
  employee_no   text,
  mobile        text,
  whatsapp      text,
  cnic          text,
  joined_on     date,
  dob           date,
  left_on       date,
  status        text,
  profile_id    uuid,
  login_active  boolean,
  login_role    text,
  class_teacher_of text,
  assignments   integer
)
language plpgsql stable security definer set search_path = public as $$
declare v_school uuid := public.current_school_id();
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;

  return query
  select
    st.id, st.full_name, st.designation, st.employee_no, st.mobile, st.whatsapp,
    st.cnic, st.joined_on, st.dob, st.left_on, st.status,
    st.profile_id,
    -- NULL, not false, when there is no login at all: "no account" and "account
    -- switched off" are different facts and the screen says different things
    -- about them. Collapsing them to false would make every teacher without a
    -- login look like a revoked one.
    pr.active,
    pr.role::text,
    -- The sections this person is still class teacher of, named. A count would
    -- not be actionable; "1-A, 2-B" tells the principal what to reassign.
    (select string_agg(c.name || coalesce('-' || sec.name, ''), ', '
                       order by c.level_order, sec.sort_order, sec.name)
       from public.sections sec
       join public.classes c on c.id = sec.class_id and c.school_id = v_school
      where sec.school_id = v_school and sec.class_teacher_id = st.id),
    (select count(*)::integer
       from public.teacher_assignments ta
       join public.academic_sessions ses
         on ses.id = ta.session_id and ses.school_id = v_school and ses.is_current
      where ta.school_id = v_school and ta.staff_id = st.id)
  from public.staff st
  left join public.profiles pr
         on pr.id = st.profile_id and pr.school_id = v_school
  where st.school_id = v_school and st.deleted_at is null
  order by (st.status = 'active') desc, st.full_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_staff_leave — the whole exit, in one transaction.
--
-- Owner and principal only. A clerk may edit a staff record (the staff_write
-- policy lets them) but revoking somebody's access to every child's record is
-- not a clerical act.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_leave(
  p_staff_id uuid,
  p_left_on  date default current_date,
  p_reason   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_staff    public.staff;
  v_sections text;
  v_vacated  integer := 0;
  v_dropped  integer := 0;
  v_revoked  boolean := false;
  v_on       date    := coalesce(p_left_on, current_date);
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may record a member of staff leaving'
      using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);

  select * into v_staff from public.staff
   where id = p_staff_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Staff record not found';
  end if;
  if v_staff.status <> 'active' then
    raise exception '% is already recorded as having left', v_staff.full_name;
  end if;

  -- A future leaving date would be a record saying they were employed on a day
  -- the system had already locked them out — the login is cut below, now, not
  -- on the date. A school processing an exit after the fact (the normal case)
  -- passes a past date, which is fine.
  if v_on > current_date then
    raise exception 'The last working day cannot be in the future — the login is closed straight away';
  end if;
  if v_staff.joined_on is not null and v_on < v_staff.joined_on then
    raise exception 'Last working day (%) is before the joining date (%)', v_on, v_staff.joined_on;
  end if;

  update public.staff
     set status = 'left', left_on = v_on
   where id = p_staff_id and school_id = v_school;

  -- Vacate the class-teacher slots BEFORE reporting them, and name them, so the
  -- caller can tell the principal which classes now need somebody.
  select string_agg(c.name || coalesce('-' || sec.name, ''), ', '
                    order by c.level_order, sec.sort_order, sec.name),
         count(*)
    into v_sections, v_vacated
    from public.sections sec
    join public.classes c on c.id = sec.class_id and c.school_id = v_school
   where sec.school_id = v_school and sec.class_teacher_id = p_staff_id;

  update public.sections
     set class_teacher_id = null
   where school_id = v_school and class_teacher_id = p_staff_id;

  -- Teaching assignments for any session that had not already ended by their
  -- last day. Past sessions are history and stay: "who taught 1-A in 2023-24"
  -- must still be answerable after the teacher has gone.
  with gone as (
    delete from public.teacher_assignments ta
     where ta.school_id = v_school
       and ta.staff_id = p_staff_id
       and ta.session_id in (
         select ses.id from public.academic_sessions ses
          where ses.school_id = v_school
            and coalesce(ses.ends_on, 'infinity'::date) >= v_on)
    returning 1)
  select count(*) into v_dropped from gone;

  -- The point of the whole exercise. If this person is the school's only active
  -- owner the profiles trigger refuses, the transaction aborts, and nothing
  -- above is written — which is right: a school must not be able to lock itself
  -- out by processing its own exit.
  if v_staff.profile_id is not null then
    update public.profiles
       set active = false
     where id = v_staff.profile_id and school_id = v_school and active;
    v_revoked := found;
  end if;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'STAFF_LEAVE', 'staff', p_staff_id::text,
    to_jsonb(v_staff),
    jsonb_build_object('left_on', v_on, 'login_revoked', v_revoked,
                       'sections_vacated', coalesce(v_sections, ''),
                       'assignments_removed', v_dropped),
    p_reason);

  return jsonb_build_object(
    'staff_name',          v_staff.full_name,
    'left_on',             v_on,
    'login_revoked',       v_revoked,
    'had_login',           v_staff.profile_id is not null,
    'sections_vacated',    coalesce(v_sections, ''),
    'sections_count',      coalesce(v_vacated, 0),
    'assignments_removed', v_dropped);
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_staff_rejoin — the undo, and the re-hire.
--
-- It does NOT put back the class-teacher slots or the assignments. Restoring
-- them silently would be worse than making somebody choose: the slots may have
-- been filled by a replacement in the meantime, and quietly overwriting that is
-- how two teachers end up on one result card.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_rejoin(
  p_staff_id uuid,
  p_reason   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school  uuid := public.current_school_id();
  v_staff   public.staff;
  v_restored boolean := false;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may bring a member of staff back'
      using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);

  select * into v_staff from public.staff
   where id = p_staff_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Staff record not found';
  end if;
  if v_staff.status = 'active' then
    raise exception '% is already active', v_staff.full_name;
  end if;

  update public.staff
     set status = 'active', left_on = null
   where id = p_staff_id and school_id = v_school;

  if v_staff.profile_id is not null then
    update public.profiles
       set active = true
     where id = v_staff.profile_id and school_id = v_school and not active;
    v_restored := found;
  end if;

  insert into public.audit_log (
    school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
  values (
    v_school, auth.uid(),
    (select role from public.profiles where id = auth.uid()),
    'STAFF_REJOIN', 'staff', p_staff_id::text,
    to_jsonb(v_staff),
    jsonb_build_object('login_restored', v_restored),
    p_reason);

  return jsonb_build_object(
    'staff_name',     v_staff.full_name,
    'login_restored', v_restored,
    'had_login',      v_staff.profile_id is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- fn_staff_set_login_active — the access switch on its own.
--
-- Two jobs. Suspending somebody who has not left (long leave, an investigation)
-- without falsifying their employment record; and closing the logins of the
-- people the OLD button left open, which is the one thing this migration
-- refuses to do silently on the school's behalf.
-- ---------------------------------------------------------------------------
create or replace function public.fn_staff_set_login_active(
  p_staff_id uuid,
  p_active   boolean,
  p_reason   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_staff  public.staff;
  v_before boolean;
  v_changed boolean := false;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only an owner or principal may change who can log in'
      using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);

  select * into v_staff from public.staff
   where id = p_staff_id and school_id = v_school and deleted_at is null;
  if not found then
    raise exception 'Staff record not found';
  end if;
  if v_staff.profile_id is null then
    raise exception '% has no login to change', v_staff.full_name;
  end if;

  select active into v_before from public.profiles
   where id = v_staff.profile_id and school_id = v_school;
  if v_before is null then
    raise exception '% has no login to change', v_staff.full_name;
  end if;

  -- Restoring access to somebody recorded as having left would leave the two
  -- facts contradicting each other, and the roster would show a departed member
  -- of staff with a working account. Bring them back properly instead.
  if p_active and v_staff.status <> 'active' then
    raise exception '% is recorded as having left on %. Use Rejoined first.',
      v_staff.full_name, coalesce(v_staff.left_on::text, 'an unrecorded date');
  end if;

  update public.profiles
     set active = p_active
   where id = v_staff.profile_id and school_id = v_school
     and active is distinct from p_active;
  v_changed := found;

  if v_changed then
    insert into public.audit_log (
      school_id, actor, actor_role, action, entity, entity_id, before, after, reason)
    values (
      v_school, auth.uid(),
      (select role from public.profiles where id = auth.uid()),
      case when p_active then 'STAFF_LOGIN_RESTORE' else 'STAFF_LOGIN_REVOKE' end,
      'profiles', v_staff.profile_id::text,
      jsonb_build_object('active', v_before),
      jsonb_build_object('active', p_active, 'staff_id', p_staff_id),
      p_reason);
  end if;

  return jsonb_build_object(
    'staff_name', v_staff.full_name,
    'login_active', p_active,
    'changed', v_changed);
end;
$$;

revoke all on function public.fn_staff_roster() from public;
revoke all on function public.fn_staff_leave(uuid, date, text) from public;
revoke all on function public.fn_staff_rejoin(uuid, text) from public;
revoke all on function public.fn_staff_set_login_active(uuid, boolean, text) from public;

grant execute on function public.fn_staff_roster() to authenticated;
grant execute on function public.fn_staff_leave(uuid, date, text) to authenticated;
grant execute on function public.fn_staff_rejoin(uuid, text) to authenticated;
grant execute on function public.fn_staff_set_login_active(uuid, boolean, text) to authenticated;
