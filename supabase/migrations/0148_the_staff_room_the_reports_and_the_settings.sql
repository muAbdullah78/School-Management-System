-- =============================================================================
-- 0148: the staff room, the reports, and the settings.
--
-- Step 3 of the redraw covers Staff, Reports and Settings. Reading them for
-- the redraw found faults no amount of colour would have fixed, and two of them
-- were holes anybody with a login could walk through. Those come first.
--
-- THE HOLES
--
--   1. ANY LOGIN COULD REPOINT ITSELF. profiles_update lets a user update their
--      own row, which is right for their name, and nothing guarded the two
--      columns that decide what the login can reach. A class teacher could set
--      profiles.staff_id to a colleague's staff record and take over that
--      colleague's classes: their register, their marks, the parents' phone
--      numbers on the roster. A parent could set profiles.family_id to another
--      family and read that family's fees, results and attendance. Both were
--      reproduced as the authenticated role before this was written. The two
--      columns are now written only by the functions made for it
--      (fn_link_staff_profile, fn_link_parent and the family merge), which run
--      as their owner, never by a login editing its own row.
--
--   2. A PRINCIPAL COULD MAKE THEMSELVES OWNER. guard_profile_role asked only
--      whether the caller was an owner or a principal, so a principal could
--      promote themselves, or anybody, to owner, and demote an owner. Only an
--      owner now grants or removes owner, or closes an owner's login. Nobody
--      but an owner changes their own role. And a parent login is never turned
--      into a staff login or back, because a parent login is joined to a family
--      and a staff login to a staff record, and switching the role keeps the
--      wrong join.
--
--   3. A PARENT OR OBSERVER LOGIN ATTACHED TO A STAFF RECORD TAUGHT ITS CLASS.
--      fn_link_staff_profile accepted any login, and the Staff screen offered
--      parent logins in its list. fn_may_manage_class and fn_may_mark_subject
--      then granted the staff record's classes to whatever login pointed at it,
--      without asking its role, so a Read only login attached to a class
--      teacher's record could write that class's report-card remarks. The
--      class and subject checks now require the login itself to be a class or
--      subject teacher, fn_link_staff_profile refuses a parent login, and any
--      parent login already attached to a staff record is detached here.
--
-- THE STAFF ROOM
--
--   4. A teacher who has left could be made class teacher or subject teacher.
--      fn_set_class_teacher and fn_set_subject_teachers now refuse them.
--   5. A day typed by the office carried the moment it was TYPED as the
--      teacher's arrival time, so a day marked three days late showed them
--      arriving at 14:05. A typed day now has no arrival time. A scan keeps its.
--   6. Attendance could be recorded before somebody joined or after they left.
--   7. fn_staff_mark_rest_present marks everyone not yet marked as present in
--      one statement, where the office used to press forty buttons.
--   8. Recording a leaving cleared the person's class-teacher rows and never
--      their subject-teacher rows, so a teacher who left in June still taught
--      Islamiat in September. A trigger on the leaving now clears both.
--
-- THE REPORTS
--
--   9. Every report function dated its rows by the server's UTC clock, the
--      fault 0147 fixed for Accounts. The Debit and Credit statement promises
--      to agree with Accounts for the same dates, and after 0147 it no longer
--      did. It was not only the reports: over a hundred functions read the UTC clock,
--      among them fn_staff_leave, which refused "today" as a future date
--      between midnight and 05:00 in Karachi. Every function that works out a
--      date now runs with its clock set to Karachi, one line per function, so
--      no body is retyped.
--  10. fn_fee_receipts replaces the Fee Collection report's plain read of the
--      payments table, which named no child on a family payment (a column of
--      dashes), dated by UTC, and stopped at Supabase's 1,000-row cap.
--  11. The admissions register answered any teacher's login.
--
-- THE SETTINGS
--
--  12. A school year without dates was told to "add it again below", which made
--      a second year of the same name. fn_set_session_dates sets them on the
--      year itself, and fn_add_session refuses a duplicate name or dates that
--      overlap another year.
--  13. A class with thirty children in it could be switched off, which hid them
--      from every class list. Two classes could share a name. A trigger on
--      classes now refuses both, and says how many children are in the class.
--
-- Every changed function keeps its signature, every new object is created or
-- replaced, and each rewrite checks whether it has already been done, so
-- re-pasting this file is a no-op.
-- =============================================================================

-- ============================================ 1. the two columns that decide ==
-- SECURITY INVOKER on purpose. current_user is the role that ran the UPDATE:
-- "authenticated" for a login editing a row through the API, and the function
-- owner when fn_link_staff_profile or fn_link_parent did it. A definer trigger
-- would see its own owner every time and could not tell the two apart.
create or replace function public.guard_profile_links()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon')
     and (new.staff_id is distinct from old.staff_id
          or new.family_id is distinct from old.family_id) then
    raise exception 'A login is attached to a person on the Staff screen, or to a '
                    'family from the child''s profile. It cannot be repointed by '
                    'editing the login.'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

-- A trigger function is not an API. Postgres grants EXECUTE on every new
-- function to PUBLIC, so each one here is revoked as it is made.
revoke all on function public.guard_profile_links() from public, anon, authenticated;

drop trigger if exists trg_profiles_link_guard on public.profiles;
create trigger trg_profiles_link_guard
  before update on public.profiles
  for each row execute function public.guard_profile_links();

-- ======================================================= 2. who grants owner ==
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.role is distinct from old.role then
    if not public.has_role('owner', 'principal') then
      raise exception 'Only an owner or principal may change a role'
        using errcode = '42501';
    end if;
    -- 0148. The school's top privilege is granted and removed by an owner.
    if (new.role = 'owner' or old.role = 'owner') and not public.has_role('owner') then
      raise exception 'Only an owner can make somebody an owner, or change an owner''s role.'
        using errcode = '42501';
    end if;
    -- 0148. Nobody promotes or demotes themselves, except an owner, whom
    -- guard_last_owner_active stops being the last one.
    if old.id = auth.uid() and not public.has_role('owner') then
      raise exception 'You cannot change your own role. Ask the school''s owner.'
        using errcode = '42501';
    end if;
    -- 0148. A parent login belongs to a family and a staff login to a staff
    -- record. Switching one into the other keeps the wrong join.
    if (old.role = 'parent') <> (new.role = 'parent') then
      raise exception 'A parent''s login cannot become a staff login, or the other '
                      'way round. Make a new login for the other job.'
        using errcode = '22023';
    end if;
  end if;

  -- 0148. Closing or reopening an owner's login is an owner's decision.
  if tg_op = 'UPDATE' and new.active is distinct from old.active
     and old.role = 'owner' and not public.has_role('owner') then
    raise exception 'Only an owner can close or reopen an owner''s login.'
      using errcode = '42501';
  end if;

  -- Said in words, because this is what a school sees if it has an old tab
  -- open, or a bookmarked screen, or a browser that cached the page from
  -- before the update.
  if new.role in ('admin_clerk', 'accountant') then
    raise exception 'The Admin / Clerk and Accountant roles have been '
                    'withdrawn. Use Principal / Headmaster for office staff, '
                    'or Read only for someone who should see and not change.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

-- ============================================ 3. a staff login is a staff role ==
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

  -- 0148. A parent's login is joined to a family. Attached to a staff record
  -- it was handed that person's classes.
  if p_profile_id is not null and exists (
       select 1 from public.profiles
        where id = p_profile_id and role = 'parent'
          and school_id = public.current_school_id()) then
    raise exception 'That is a parent''s login. A member of staff needs a staff '
                    'login: use Give a login on their row.'
      using errcode = '22023';
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

-- Any parent login already attached to a staff record is detached. Both sides
-- of the link are cleared, so neither points at the other afterwards.
do $parents$
declare v_n integer;
begin
  update public.staff st set profile_id = null
    from public.profiles p
   where p.id = st.profile_id and p.role = 'parent';
  get diagnostics v_n = row_count;
  update public.profiles set staff_id = null
   where role = 'parent' and staff_id is not null;
  raise notice '0148: % parent login(s) detached from a staff record', v_n;
end
$parents$;

-- The class and subject checks, rewritten in place from the catalogue rather
-- than retyped. Each place a login is matched to its staff record also
-- requires the login to be a class or subject teacher. \s+ rather than any
-- newline, per supabase/check-patch-anchors.py. A function already rewritten
-- is left alone.
do $teach$
declare
  v_name text;
  v_oid  oid;
  v_def  text;
  v_done integer := 0;
begin
  foreach v_name in array array['fn_may_manage_class', 'fn_may_mark_subject'] loop
    for v_oid in
      select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name
    loop
      v_def := pg_get_functiondef(v_oid);
      if v_def ~ 'pr\.role\s+in\s+\(''class_teacher''' then
        continue;
      end if;
      if v_def !~ 'pr\.id\s*=\s*auth\.uid\(\)' then
        raise exception '0148: could not find where % matches a login to its staff record', v_name;
      end if;
      execute regexp_replace(
        v_def,
        'pr\.id\s*=\s*auth\.uid\(\)',
        'pr.id = auth.uid() and pr.role in (''class_teacher'', ''subject_teacher'')',
        'g');
      v_done := v_done + 1;
    end loop;
  end loop;
  raise notice '0148: % class and subject check(s) now ask the login''s role', v_done;
end
$teach$;

-- ===================================================== 4. only who is here ==
create or replace function public.fn_set_class_teacher(
  p_staff_id uuid, p_session_id uuid, p_class_id uuid, p_section_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_who text;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to assign class teachers';
  end if;
  -- Guard every id: the DELETE below is scoped only by session/class, so
  -- another school's ids would wipe their teacher assignments.
  perform public.assert_own('staff', p_staff_id);
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('sections', p_section_id);

  -- 0148. Somebody who has left cannot mark a register.
  if p_staff_id is not null then
    select full_name into v_who from public.staff
     where id = p_staff_id and school_id = public.current_school_id()
       and (status <> 'active' or deleted_at is not null);
    if found then
      raise exception '% has left the school, so cannot be a class teacher. Choose somebody on the staff.', v_who
        using errcode = '22023';
    end if;
  end if;

  delete from public.teacher_assignments
   where session_id = p_session_id and class_id = p_class_id
     and section_id is not distinct from p_section_id;
  if p_section_id is not null then
    update public.sections set class_teacher_id = p_staff_id where id = p_section_id;
  end if;
  if p_staff_id is not null then
    insert into public.teacher_assignments(staff_id, session_id, class_id, section_id, created_by)
    values (p_staff_id, p_session_id, p_class_id, p_section_id, auth.uid())
    on conflict (staff_id, session_id, class_id, section_id) do nothing;
  end if;
end;
$$;

create or replace function public.fn_set_subject_teachers(
  p_session_id uuid, p_class_id uuid, p_section_id uuid, p_subject_id uuid, p_staff_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_n integer := 0; v_who text;
begin
  if not public.has_role('owner', 'principal', 'admin_clerk') then
    raise exception 'Only the office may assign subject teachers';
  end if;
  -- Every id guarded: the DELETE below is scoped by session/class/subject, so
  -- another school's ids would clear THEIR register.
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.assert_own('classes', p_class_id);
  perform public.assert_own('subjects', p_subject_id);
  if p_section_id is not null then
    perform public.assert_own('sections', p_section_id);
  end if;

  -- The subject must belong to the class it is being taught in.
  if not exists (select 1 from public.subjects s
                  where s.id = p_subject_id and s.class_id = p_class_id) then
    raise exception 'That subject does not belong to that class';
  end if;

  -- 0148. Nobody who has left, checked before anything is cleared.
  if p_staff_ids is not null then
    select st.full_name into v_who from public.staff st
     where st.id = any(p_staff_ids) and st.school_id = public.current_school_id()
       and (st.status <> 'active' or st.deleted_at is not null)
     limit 1;
    if found then
      raise exception '% has left the school, so cannot teach a subject. Choose somebody on the staff.', v_who
        using errcode = '22023';
    end if;
  end if;

  delete from public.subject_teachers
   where session_id = p_session_id
     and class_id = p_class_id
     and subject_id = p_subject_id
     and section_id is not distinct from p_section_id
     and school_id = public.current_school_id();

  if p_staff_ids is not null then
    foreach v_id in array p_staff_ids loop
      perform public.assert_own('staff', v_id);
      insert into public.subject_teachers
        (staff_id, session_id, class_id, section_id, subject_id, created_by)
      values (v_id, p_session_id, p_class_id, p_section_id, p_subject_id, auth.uid())
      on conflict do nothing;
      v_n := v_n + 1;
    end loop;
  end if;

  return v_n;
end;
$$;

-- ================================================ 5 and 6. a day in the office ==
create or replace function public.fn_set_staff_attendance(
  p_staff_id uuid, p_date date, p_status attendance_status, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_prior record; v_staff record;
begin
  if not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set staff attendance' using errcode = '42501';
  end if;
  perform public.assert_own('staff', p_staff_id);
  -- 0130: and not before the school existed either.
  perform public.fn__assert_date_in_calendar(p_date, 'Staff attendance');
  if p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Attendance cannot be recorded for a day that has not happened yet';
  end if;

  -- 0148. Not before they joined, and not after they left.
  select full_name, joined_on, left_on into v_staff from public.staff
   where id = p_staff_id and school_id = public.current_school_id();
  if v_staff.joined_on is not null and p_date < v_staff.joined_on then
    raise exception '% joined on %, so there is nothing to record for %.',
      v_staff.full_name, to_char(v_staff.joined_on, 'DD Mon YYYY'), to_char(p_date, 'DD Mon YYYY')
      using errcode = '22023';
  end if;
  if v_staff.left_on is not null and p_date > v_staff.left_on then
    raise exception '% left on %, so there is nothing to record for %.',
      v_staff.full_name, to_char(v_staff.left_on, 'DD Mon YYYY'), to_char(p_date, 'DD Mon YYYY')
      using errcode = '22023';
  end if;

  select * into v_prior from public.staff_attendance
   where staff_id = p_staff_id and attendance_date = p_date
     and school_id = public.current_school_id();

  -- Overwriting a recorded scan with a judgement is exactly the thing somebody
  -- has to be able to explain a month later, so it needs a reason.
  if v_prior.id is not null and v_prior.source = 'qr'
     and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'This day was recorded by a check-in at %. Changing it needs a reason.',
      to_char(v_prior.checked_at at time zone 'Asia/Karachi', 'HH24:MI');
  end if;

  -- 0148. No arrival time on a typed day. It used to be now(), the moment the
  -- office typed it, which read on the register as when the teacher arrived.
  -- A scanned day keeps the time the scan recorded.
  insert into public.staff_attendance
    (staff_id, attendance_date, status, source, reason, marked_by, checked_at)
  values (p_staff_id, p_date, p_status, 'manual', nullif(btrim(p_reason),''), auth.uid(), null)
  on conflict (staff_id, attendance_date) do update
    set status = excluded.status, source = 'manual', reason = excluded.reason,
        marked_by = excluded.marked_by;
end;
$$;

-- ============================================= 7. everybody else is present ==
create or replace function public.fn_staff_mark_rest_present(p_date date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_n integer;
begin
  if v_school is null or not public.has_role('owner','principal','admin_clerk') then
    raise exception 'Not permitted to set staff attendance' using errcode = '42501';
  end if;
  if p_date is null then
    raise exception 'Which day?';
  end if;
  perform public.fn__assert_date_in_calendar(p_date, 'Staff attendance');
  if p_date > (now() at time zone 'Asia/Karachi')::date then
    raise exception 'Attendance cannot be recorded for a day that has not happened yet';
  end if;

  -- Only the people with no row for the day. A scan, an absence or a leave the
  -- office has already typed is left exactly as it is.
  insert into public.staff_attendance
    (school_id, staff_id, attendance_date, status, source, marked_by, checked_at)
  select v_school, s.id, p_date, 'present', 'manual', auth.uid(), null
    from public.staff s
   where s.school_id = v_school and s.status = 'active' and s.deleted_at is null
     and (s.joined_on is null or s.joined_on <= p_date)
     and not exists (select 1 from public.staff_attendance a
                      where a.staff_id = s.id and a.attendance_date = p_date
                        and a.school_id = v_school)
  on conflict (staff_id, attendance_date) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.fn_staff_mark_rest_present(date) from public, anon;
grant execute on function public.fn_staff_mark_rest_present(date) to authenticated;

-- ======================================================= 8. the reports' clock ==
-- One line per function rather than a rewrite of each body. With the function's
-- clock set to Karachi, current_date and every created_at::date inside it are
-- the day in Pakistan, which is the day the school means. The setting is part
-- of the function, so pg_get_functiondef carries it and a later in-place
-- rewrite keeps it.
do $clock$
declare
  v_oid oid;
  v_n integer := 0;
begin
  for v_oid in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('fn_report_ledger', 'fn_report_balance_sheet', 'fn_report_unpaid_invoices',
                         'fn_report_discounts', 'fn_report_admissions', 'fn_mark_corrections',
                         'fn_attendance_corrections', 'fn_voided_invoices', 'fn__student_ledger')
  loop
    execute format('alter function %s set timezone to %L', v_oid::regprocedure, 'Asia/Karachi');
    v_n := v_n + 1;
  end loop;
  raise notice '0148: % report function(s) now count days in Pakistan', v_n;
end
$clock$;


-- ============================================ 10. the admissions register gate ==
do $gate$
declare
  v_oid oid;
  v_def text;
begin
  for v_oid in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_report_admissions'
  loop
    v_def := pg_get_functiondef(v_oid);
    if v_def ~ 'if\s+not\s+public\.is_staff\(\)\s+then' then
      execute regexp_replace(
        v_def,
        'if\s+not\s+public\.is_staff\(\)\s+then',
        'if not public.may_view(''owner'', ''principal'', ''admin_clerk'', ''accountant'') then');
      raise notice '0148: the admissions register now answers only the office';
    end if;
  end loop;
end
$gate$;

-- ==================================================== 9. the fee receipts ==
create or replace function public.fn_fee_receipts(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school   uuid := public.current_school_id();
  v_start    timestamptz;
  v_end      timestamptz;
  v_session  uuid;
  v_rows     jsonb;
  v_method   jsonb;
  v_day      jsonb;
  v_total    numeric;
  v_receipts integer;
  v_rev_n    integer;
  v_rev      numeric;
  v_pend_n   integer;
  v_pend     numeric;
begin
  if v_school is null
     or not public.may_view('owner', 'principal', 'admin_clerk', 'accountant') then
    raise exception 'Not permitted to view fee records' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A date range is required';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date';
  end if;
  if p_to - p_from > 400 then
    raise exception 'Ask for a year at a time or less';
  end if;

  -- The day in Pakistan, as two instants.
  v_start := p_from::timestamp at time zone 'Asia/Karachi';
  v_end   := (p_to + 1)::timestamp at time zone 'Asia/Karachi';
  select id into v_session from public.academic_sessions
   where school_id = v_school and is_current
   order by created_at desc limit 1;

  with p as (
    select x.*, (x.created_at at time zone 'Asia/Karachi') as local_at
      from public.payments x
     where x.school_id = v_school and x.status = 'verified'
       and x.created_at >= v_start and x.created_at < v_end
  ), r as (
    select p.id, p.created_at, p.local_at, p.receipt_no, p.amount, p.method::text as method,
           p.reversal_of is not null as is_reversal, p.note,
           coalesce(f.head_name, k.names, '-') as payer,
           k.names as children, coalesce(k.n, 0) as child_count,
           case when k.n = 1 then k.gr end as gr_no,
           case when k.n = 1 then k.cls end as class_label,
           coalesce(pr.full_name, '-') as recorded_by
      from p
      left join public.payments o
             on o.id = p.reversal_of and o.school_id = v_school
      left join public.families f
             on f.id = coalesce(p.family_id, o.family_id) and f.school_id = v_school
      left join public.profiles pr
             on pr.id = p.received_by and pr.school_id = v_school
      -- Who the money was for: the children on the challans it paid, the child
      -- on the payment row, and for a reversal the same of the receipt it
      -- reverses. A family payment has no child on its own row, which is why
      -- the old report printed a dash for it.
      left join lateral (
        select string_agg(distinct s.full_name, ', ' order by s.full_name) as names,
               count(distinct s.id)::int as n,
               min(s.gr_no) as gr,
               min(c.name || coalesce('-' || sec.name, '')) as cls
          from public.students s
          left join public.enrollments e
                 on e.student_id = s.id and e.school_id = v_school and e.session_id = v_session
          left join public.classes c on c.id = e.class_id and c.school_id = v_school
          left join public.sections sec on sec.id = e.section_id and sec.school_id = v_school
         where s.school_id = v_school
           and s.id in (
             select i.student_id
               from public.payment_allocations al
               join public.invoices i on i.id = al.invoice_id and i.school_id = v_school
              where al.school_id = v_school and al.payment_id in (p.id, p.reversal_of)
             union select p.student_id
             union select o.student_id)
      ) k on true
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'paid_at', r.created_at, 'paid_on', r.local_at::date,
           'time', to_char(r.local_at, 'HH24:MI'), 'receipt_no', r.receipt_no,
           'amount', r.amount, 'method', r.method, 'payer', r.payer,
           'children', r.children, 'child_count', r.child_count,
           'gr_no', r.gr_no, 'class_label', r.class_label,
           'is_reversal', r.is_reversal, 'recorded_by', r.recorded_by, 'note', r.note)
           order by r.created_at, r.receipt_no), '[]'::jsonb),
         coalesce(sum(r.amount), 0),
         (count(*) filter (where not r.is_reversal))::int,
         (count(*) filter (where r.is_reversal))::int,
         coalesce(sum(-r.amount) filter (where r.is_reversal), 0)
    into v_rows, v_total, v_receipts, v_rev_n, v_rev
    from r;

  select coalesce(jsonb_agg(jsonb_build_object(
           'method', m.method, 'receipts', m.receipts, 'amount', m.amount)
           order by m.amount desc), '[]'::jsonb)
    into v_method
    from (select x.method::text as method,
                 (count(*) filter (where x.reversal_of is null))::int as receipts,
                 sum(x.amount) as amount
            from public.payments x
           where x.school_id = v_school and x.status = 'verified'
             and x.created_at >= v_start and x.created_at < v_end
           group by x.method) m;

  select coalesce(jsonb_agg(jsonb_build_object(
           'day', d.day, 'receipts', d.receipts, 'amount', d.amount)
           order by d.day), '[]'::jsonb)
    into v_day
    from (select (x.created_at at time zone 'Asia/Karachi')::date as day,
                 (count(*) filter (where x.reversal_of is null))::int as receipts,
                 sum(x.amount) as amount
            from public.payments x
           where x.school_id = v_school and x.status = 'verified'
             and x.created_at >= v_start and x.created_at < v_end
           group by 1) d;

  -- Recorded in these dates and still waiting to clear. Not money in yet, and
  -- said so, rather than silently left out.
  select count(*)::int, coalesce(sum(x.amount), 0) into v_pend_n, v_pend
    from public.payments x
   where x.school_id = v_school and x.status = 'pending'
     and x.created_at >= v_start and x.created_at < v_end;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'total', v_total, 'receipts', v_receipts,
    'reversals', v_rev_n, 'reversed', v_rev,
    'pending_count', v_pend_n, 'pending_total', v_pend,
    'by_method', v_method, 'by_day', v_day, 'rows', v_rows);
end;
$$;
revoke all on function public.fn_fee_receipts(date, date) from public, anon;
grant execute on function public.fn_fee_receipts(date, date) to authenticated;

-- ============================================================ 11. the years ==
-- The checks both writers share: dates present and in order, a sane length,
-- and no overlap with another year of the same school.
create or replace function public.fn__session_dates_ok(
  p_school uuid, p_session_id uuid, p_starts date, p_ends date)
returns void language plpgsql stable security definer set search_path = public as $$
declare v_other text;
begin
  if p_starts is null or p_ends is null then
    raise exception 'A school year needs its first and last day.' using errcode = '22023';
  end if;
  if p_ends <= p_starts then
    raise exception 'The last day is before the first.' using errcode = '22023';
  end if;
  if p_ends - p_starts > 800 then
    raise exception 'A school year of more than two years is almost certainly a mistyped date.'
      using errcode = '22023';
  end if;
  select s.name into v_other from public.academic_sessions s
   where s.school_id = p_school
     and s.id is distinct from p_session_id
     and s.starts_on is not null and s.ends_on is not null
     and s.starts_on <= p_ends and s.ends_on >= p_starts
   limit 1;
  if found then
    raise exception 'Those dates overlap %. Two years cannot share a day: the software decides which year a date belongs to from these.', v_other
      using errcode = '22023';
  end if;
end;
$$;
revoke all on function public.fn__session_dates_ok(uuid, uuid, date, date) from public, anon, authenticated;

create or replace function public.fn_add_session(p_name text, p_starts date, p_ends date)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text := nullif(btrim(coalesce(p_name, '')), '');
  v_id     uuid;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may add a school year' using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'Give the year a name, such as 2026-2027.' using errcode = '22023';
  end if;
  if exists (select 1 from public.academic_sessions
              where school_id = v_school and lower(btrim(name)) = lower(v_name)) then
    raise exception 'There is already a year called %.', v_name using errcode = '23505';
  end if;
  perform public.fn__session_dates_ok(v_school, null, p_starts, p_ends);
  -- 0130's rule, and the right one here too: a year that starts more than a
  -- year away from everything the school has recorded is a mistyped year,
  -- 2062 for 2026. A school with no dated year yet is not checked.
  perform public.fn__assert_date_in_calendar(p_starts, 'A new school year');
  insert into public.academic_sessions (school_id, name, starts_on, ends_on)
  values (v_school, v_name, p_starts, p_ends)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.fn_add_session(text, date, date) from public, anon;
grant execute on function public.fn_add_session(text, date, date) to authenticated;

create or replace function public.fn_set_session_dates(p_session_id uuid, p_starts date, p_ends date)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_att    integer;
  v_inv    integer;
begin
  if v_school is null or not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may change a school year' using errcode = '42501';
  end if;
  perform public.assert_own('academic_sessions', p_session_id);
  perform public.fn__session_dates_ok(v_school, p_session_id, p_starts, p_ends);

  -- Nothing already recorded in this year may fall outside it.
  select count(*)::int into v_att
    from public.attendance_daily ad
    join public.enrollments e on e.id = ad.enrollment_id and e.school_id = v_school
   where ad.school_id = v_school and e.session_id = p_session_id
     and (ad.attendance_date < p_starts or ad.attendance_date > p_ends);
  if v_att > 0 then
    raise exception '% attendance mark(s) in this year fall outside those dates. Choose dates that cover them.', v_att
      using errcode = '22023';
  end if;
  select count(*)::int into v_inv
    from public.invoices i
   where i.school_id = v_school and i.session_id = p_session_id
     and i.period_month is not null and i.voided_at is null
     and (i.period_month < date_trunc('month', p_starts)::date or i.period_month > p_ends);
  if v_inv > 0 then
    raise exception '% challan(s) in this year are for months outside those dates. Choose dates that cover them.', v_inv
      using errcode = '22023';
  end if;

  update public.academic_sessions
     set starts_on = p_starts, ends_on = p_ends
   where id = p_session_id and school_id = v_school;
end;
$$;
revoke all on function public.fn_set_session_dates(uuid, date, date) from public, anon;
grant execute on function public.fn_set_session_dates(uuid, date, date) to authenticated;

-- ========================================================== 12. the classes ==
create or replace function public.guard_class_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if nullif(btrim(coalesce(new.name, '')), '') is null then
    raise exception 'A class needs a name.' using errcode = '22023';
  end if;
  if (tg_op = 'INSERT' or new.name is distinct from old.name)
     and exists (select 1 from public.classes c
                  where c.school_id = new.school_id and c.id <> new.id
                    and lower(btrim(c.name)) = lower(btrim(new.name))) then
    raise exception 'There is already a class called %.', btrim(new.name) using errcode = '23505';
  end if;
  -- Switching off a class that has children in it this year hid them from
  -- every class list: their register, their challans, their results.
  if tg_op = 'UPDATE' and old.active and not new.active then
    select count(*)::int into v_n
      from public.enrollments e
      join public.academic_sessions s on s.id = e.session_id and s.school_id = new.school_id and s.is_current
     where e.school_id = new.school_id and e.class_id = new.id and e.status = 'active';
    if v_n > 0 then
      raise exception '% has % child(ren) in it this year. Move them to another class before switching it off.', new.name, v_n
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.guard_class_change() from public, anon, authenticated;

drop trigger if exists trg_classes_guard on public.classes;
create trigger trg_classes_guard
  before insert or update on public.classes
  for each row execute function public.guard_class_change();

-- ============================================ 13. a teacher who left teaches nothing ==
-- fn_staff_leave clears the class-teacher rows of anybody who leaves, for every
-- year not over by their last day, and never cleared the subject-teacher rows,
-- so a teacher who left in June was still the Islamiat teacher of Class 5 in
-- September. Done by a trigger on the leaving itself rather than by retyping
-- fn_staff_leave, with the same rule: past years are history and stay.
create or replace function public.fn__staff_left_subjects()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'active' and new.status <> 'active' then
    delete from public.subject_teachers st
     where st.school_id = new.school_id
       and st.staff_id = new.id
       and st.session_id in (
         select ses.id from public.academic_sessions ses
          where ses.school_id = new.school_id
            and coalesce(ses.ends_on, 'infinity'::date)
                >= coalesce(new.left_on, (now() at time zone 'Asia/Karachi')::date));
  end if;
  return new;
end;
$$;

revoke all on function public.fn__staff_left_subjects() from public, anon, authenticated;

drop trigger if exists trg_staff_left_subjects on public.staff;
create trigger trg_staff_left_subjects
  after update of status on public.staff
  for each row execute function public.fn__staff_left_subjects();

-- And the ones already left behind.
do $left$
declare v_n integer;
begin
  delete from public.subject_teachers st
   using public.staff s, public.academic_sessions ses
   where s.id = st.staff_id and s.school_id = st.school_id
     and ses.id = st.session_id and ses.school_id = st.school_id
     and (s.status <> 'active' or s.deleted_at is not null)
     and coalesce(ses.ends_on, 'infinity'::date)
         >= coalesce(s.left_on, (now() at time zone 'Asia/Karachi')::date);
  get diagnostics v_n = row_count;
  raise notice '0148: % subject(s) taken off teachers who have left', v_n;
end
$left$;

-- ======================================== 14. every function on Karachi's clock ==
-- Last in the file, so it also covers every function this migration made.
--
-- And every other function that works out a date. Supabase runs on UTC, so
-- between midnight and 05:00 in Karachi current_date is still yesterday: a
-- leaving recorded "today" was refused as being in the future, a challan's
-- days overdue were one short, and a created_at::date put a 01:00 receipt on
-- the day before. 0107, 0140 and 0147 fixed this one function at a time, and
-- over a hundred were left. Read off the catalogue rather than listed, so none is missed:
-- any function whose body reads current_date, casts to a date, truncates a
-- time or prints a timestamp now runs with its clock in Karachi. A function that only stamps now()
-- is unaffected, because an instant is the same instant in any zone. The
-- setting is part of each function, so pg_get_functiondef carries it and a
-- later in-place rewrite keeps it.
do $clock_all$
declare
  v_oid oid;
  v_n integer := 0;
begin
  for v_oid in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.prosrc ~* '(\mcurrent_date\M|::date\M|date_trunc\s*\(|localtimestamp|to_char\s*\(\s*[a-z_.]*_at\M)'
       and not ('TimeZone=Asia/Karachi' = any(coalesce(p.proconfig, '{}'::text[])))
  loop
    execute format('alter function %s set timezone to %L', v_oid::regprocedure, 'Asia/Karachi');
    v_n := v_n + 1;
  end loop;
  raise notice '0148: % more function(s) now count days in Pakistan', v_n;
end
$clock_all$;
