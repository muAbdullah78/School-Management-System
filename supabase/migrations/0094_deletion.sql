-- =============================================================================
-- 0094  Deleting things, and refusing to
--
-- THE PROBLEM. Nothing in this application could be deleted. Not a student,
-- not a staff member, not a login. The only deletes in the whole codebase were
-- for link rows. Every screen offered "record leaving" or "mark inactive"
-- instead, which is right for somebody who really left and useless for a name
-- typed in wrong five seconds ago. A school's roster filled with test records
-- and typos and stayed that way forever. That alone gets a product rejected in
-- its first week, and it is the first thing the owner of the first real school
-- asked for.
--
-- WHY "JUST ADD A DELETE BUTTON" IS THE WRONG ANSWER. A student who has paid
-- fees is not a row, they are part of the school's books. Deleting them would
-- remove receipts that have been handed to a parent, change last month's income
-- after it was reported, and leave the audit trail with a hole in it. No
-- accounting system on earth lets you do that, and a school that discovered it
-- could would be right to distrust every other figure we show them.
--
-- SO THE RULE IS: DELETE WHAT HAS NO CONSEQUENCES, ARCHIVE WHAT DOES.
--
-- A record with nothing attached to it never happened as far as the school is
-- concerned, and removing it loses nothing. A record with money, attendance,
-- marks or issued documents against it has a history, and history is archived,
-- never deleted. The line between them is drawn HERE rather than in the
-- browser, because a rule about the school's books that a client could skip is
-- not a rule.
--
-- AND IT MUST SAY WHY. A refusal that says only "cannot delete" is the reason
-- people distrust software. Every function below returns the exact list of
-- what is in the way, with counts, in words a school office uses: "3 receipts,
-- 42 days of attendance". Then the person can decide to archive instead, which
-- is almost always what they actually wanted.
--
-- ON THE FOREIGN KEYS. The blocking lists below were read out of the live
-- constraint graph rather than guessed. Anything already declared ON DELETE
-- CASCADE is part of the record and goes with it (a student's guardians, a
-- staff member's subject assignments); anything that blocks is either history,
-- and refuses the delete, or setup, and is removed explicitly first. Adding a
-- new table that references one of these WILL be caught by the tests in
-- supabase/tests/deletion.sql, which assert the blocker list is complete.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. What is standing in the way
--
-- Each returns a jsonb array of {what, count}, empty when nothing blocks. They
-- are readable on their own so a screen can warn BEFORE somebody presses
-- delete, rather than only explaining afterwards.
-- ---------------------------------------------------------------------------

create or replace function public.fn_student_delete_blockers(p_student_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_out jsonb := '[]'::jsonb;
  v_n bigint;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may delete a student';
  end if;
  if not exists (select 1 from public.students
                 where id = p_student_id and school_id = v_school) then
    raise exception 'No such student in this school';
  end if;

  -- Money first: it is the reason this function exists.
  select count(*) into v_n from public.payments
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a payment received' else 'payments received' end,
    'count', v_n); end if;

  select count(*) into v_n from public.invoices
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a fee challan' else 'fee challans' end,
    'count', v_n); end if;

  select count(*) into v_n from public.adjustments
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a fine or discount' else 'fines or discounts' end,
    'count', v_n); end if;

  select count(*) into v_n from public.discounts d
    join public.enrollments e on e.id = d.enrollment_id
   where e.student_id = p_student_id and d.school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object('what', 'discounts', 'count', v_n); end if;

  -- Then the record of what happened to the child.
  select count(*) into v_n from public.attendance_daily a
    join public.enrollments e on e.id = a.enrollment_id
   where e.student_id = p_student_id and a.school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a day of attendance' else 'days of attendance' end,
    'count', v_n); end if;

  select count(*) into v_n from public.mark_entries m
    join public.enrollments e on e.id = m.enrollment_id
   where e.student_id = p_student_id and m.school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'an exam mark' else 'exam marks' end,
    'count', v_n); end if;

  select count(*) into v_n from public.result_cards
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object('what', 'result cards', 'count', v_n); end if;

  -- Then anything that left the building with the school's name on it.
  select count(*) into v_n from public.certificates
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a certificate issued' else 'certificates issued' end,
    'count', v_n); end if;

  select count(*) into v_n from public.message_outbox
   where student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a message sent home' else 'messages sent home' end,
    'count', v_n); end if;

  select count(*) into v_n from public.admission_enquiries
   where admitted_student_id = p_student_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object('what', 'an admission enquiry', 'count', v_n); end if;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. A login is the hardest of the three
--
-- profiles is referenced by twenty-nine columns, nearly all of them "who did
-- this": who received the payment, who marked the register, who issued the
-- certificate. Every one of those is the audit trail, and the audit trail is
-- the thing that makes the rest of the numbers worth believing. So a login
-- that has done ANY of it cannot be deleted, only closed.
--
-- Rather than twenty-nine hand-written counts that fall out of date the moment
-- somebody adds a table, this walks the actual foreign keys. A new table
-- referencing profiles is covered the day it is created, which is the opposite
-- of how the rest of this kind of code usually ages.
-- ---------------------------------------------------------------------------
create or replace function public.fn_login_delete_blockers(p_profile_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_rec record;
  v_n bigint;
  v_total bigint := 0;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may delete a login';
  end if;

  for v_rec in
    select c.conrelid::regclass::text as tbl, a.attname as col
      from pg_constraint c
      join unnest(c.conkey) k(attnum) on true
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
     where c.contype = 'f'
       and c.confrelid = 'public.profiles'::regclass
       -- staff.profile_id is the LINK to the person, not something they did.
       -- Deleting the person removes it; it must not block them.
       and not (c.conrelid = 'public.staff'::regclass and a.attname = 'profile_id')
       -- Likewise the family link on a parent login.
       and not (c.conrelid = 'public.profiles'::regclass)
  loop
    execute format('select count(*) from %s where %I = $1', v_rec.tbl, v_rec.col)
      into v_n using p_profile_id;
    v_total := v_total + v_n;
  end loop;

  if v_total > 0 then
    v_out := v_out || jsonb_build_object(
      'what', 'work recorded against their login (payments taken, registers marked, '
              || 'documents issued). Closing the login stops them signing in and keeps '
              || 'that record intact',
      'count', v_total);
  end if;
  return v_out;
end;
$$;

create or replace function public.fn_staff_delete_blockers(p_staff_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_out jsonb := '[]'::jsonb;
  v_profile uuid;
  v_n bigint;
  v_names text;
begin
  if not public.has_role('owner', 'principal') then
    raise exception 'Only the owner or principal may delete a staff member';
  end if;
  if not exists (select 1 from public.staff
                 where id = p_staff_id and school_id = v_school) then
    raise exception 'No such staff member in this school';
  end if;

  select count(*) into v_n from public.staff_attendance
   where staff_id = p_staff_id and school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', case when v_n = 1 then 'a day of their attendance' else 'days of their attendance' end,
    'count', v_n); end if;

  -- Named, not counted. "Class 2-B" tells the office what to reassign;
  -- "1 section" tells them to go and look.
  select count(*), string_agg(c.name || coalesce('-' || s.name, ''), ', ' order by c.name)
    into v_n, v_names
    from public.sections s join public.classes c on c.id = s.class_id
   where s.class_teacher_id = p_staff_id and s.school_id = v_school;
  if v_n > 0 then v_out := v_out || jsonb_build_object(
    'what', 'class teacher of ' || v_names, 'count', v_n); end if;

  -- A login that has DONE things blocks the person, because deleting the
  -- person means deleting the login and the login is on their work.
  -- school_id on the statement itself, not only on the existence check above.
  -- SECURITY DEFINER means RLS does not apply, so every statement has to carry
  -- its own scope: an earlier guard is a guard until somebody moves it.
  select profile_id into v_profile from public.staff
   where id = p_staff_id and school_id = v_school;
  if v_profile is not null then
    v_out := v_out || public.fn_login_delete_blockers(v_profile);
  end if;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The deletes themselves
--
-- Each re-checks its own blockers. The screen calls the blocker function first
-- so it can warn early, but a check performed only by the caller is not a
-- check: these refuse on their own authority.
-- ---------------------------------------------------------------------------

create or replace function public.fn_delete_student(p_student_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_block jsonb;
  v_name text;
begin
  v_block := public.fn_student_delete_blockers(p_student_id);
  if jsonb_array_length(v_block) > 0 then
    return jsonb_build_object('deleted', false, 'blockers', v_block);
  end if;

  select full_name into v_name from public.students
   where id = p_student_id and school_id = v_school;

  -- Setup rows, which are part of the record rather than history. Order
  -- matters: fee items and enrolments both block the student row.
  --
  -- THE FOREIGN KEYS ARE THE REAL GUARANTEE, not the list above. Removing the
  -- payment check from the blockers does NOT let a paid student be deleted:
  -- Postgres refuses, because payments.student_id references this row. That is
  -- the property worth having, and it is asserted in the tests.
  --
  -- But a raw constraint error is not something to show a school clerk, and it
  -- would mean the blocker list had missed something. Catching it turns the
  -- backstop into the same clear refusal as everything else, and says plainly
  -- that we could not name the reason.
  begin
    delete from public.student_fee_items i using public.enrollments e
     where i.enrollment_id = e.id and e.student_id = p_student_id
       and i.school_id = v_school and e.school_id = v_school;
    delete from public.enrollments where student_id = p_student_id and school_id = v_school;
    -- guardians, student_links, exam_remarks and deposit_refunds are ON DELETE
    -- CASCADE and go with the row below.
    delete from public.students where id = p_student_id and school_id = v_school;
  exception when foreign_key_violation then
    return jsonb_build_object('deleted', false, 'blockers', jsonb_build_array(
      jsonb_build_object(
        'what', 'something else in the school''s records still refers to this student. '
                || 'Nothing has been changed. Please tell us, because this one is our '
                || 'mistake to fix',
        'count', 1)));
  end;

  perform public.fn__log_operator_action('student.deleted', v_school,
    jsonb_build_object('student_id', p_student_id, 'name', v_name));
  return jsonb_build_object('deleted', true, 'name', v_name, 'blockers', '[]'::jsonb);
end;
$$;

create or replace function public.fn_delete_staff(p_staff_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_block jsonb;
  v_name text;
  v_profile uuid;
begin
  v_block := public.fn_staff_delete_blockers(p_staff_id);
  if jsonb_array_length(v_block) > 0 then
    return jsonb_build_object('deleted', false, 'blockers', v_block);
  end if;

  select full_name, profile_id into v_name, v_profile
    from public.staff where id = p_staff_id and school_id = v_school;

  -- Setup that hangs off the person. teacher_assignments, subject_teachers and
  -- staff_attendance are ON DELETE CASCADE; staff_checkin_attempts is SET NULL.
  begin
    delete from public.staff where id = p_staff_id and school_id = v_school;
  exception when foreign_key_violation then
    return jsonb_build_object('deleted', false, 'blockers', jsonb_build_array(
      jsonb_build_object(
        'what', 'something else in the school''s records still refers to this person. '
                || 'Nothing has been changed. Please tell us, because this one is our '
                || 'mistake to fix',
        'count', 1)));
  end;

  -- The login goes with the person. The blocker check above already refused if
  -- it had done any work, so this can only ever remove one that never did.
  -- The auth.users row is removed by the create-teacher Edge Function, which
  -- holds the service key; a profile row on its own is enough to stop all
  -- access, because every RLS policy in this database reads it.
  if v_profile is not null then
    delete from public.profiles where id = v_profile;
  end if;

  perform public.fn__log_operator_action('staff.deleted', v_school,
    jsonb_build_object('staff_id', p_staff_id, 'name', v_name, 'profile_id', v_profile));
  return jsonb_build_object(
    'deleted', true, 'name', v_name, 'profile_id', v_profile, 'blockers', '[]'::jsonb);
end;
$$;

create or replace function public.fn_delete_login(p_profile_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_block jsonb;
  v_name text;
  v_role public.user_role;
begin
  select full_name, role into v_name, v_role
    from public.profiles where id = p_profile_id and school_id = v_school;
  if v_name is null and v_role is null then
    raise exception 'No such login in this school';
  end if;

  -- Two refusals that are about authority rather than history, and both are
  -- ways a school could lock itself out of its own account permanently.
  if p_profile_id = auth.uid() then
    raise exception 'You cannot delete the login you are signed in with';
  end if;
  if v_role = 'owner' and (
    select count(*) from public.profiles
     where school_id = v_school and role = 'owner' and active) <= 1 then
    raise exception 'This is the only owner login. A school must keep one.';
  end if;

  v_block := public.fn_login_delete_blockers(p_profile_id);
  if jsonb_array_length(v_block) > 0 then
    return jsonb_build_object('deleted', false, 'blockers', v_block);
  end if;

  update public.staff set profile_id = null
   where profile_id = p_profile_id and school_id = v_school;
  delete from public.profiles where id = p_profile_id and school_id = v_school;

  perform public.fn__log_operator_action('login.deleted', v_school,
    jsonb_build_object('profile_id', p_profile_id, 'name', v_name, 'role', v_role));
  return jsonb_build_object('deleted', true, 'name', v_name, 'blockers', '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Grants
--
-- Every one of these re-checks has_role('owner','principal') itself, so the
-- grant to authenticated is not the boundary; the check inside is.
--
-- BUT THE REVOKE IS NOT OPTIONAL. Postgres grants EXECUTE on a new function to
-- PUBLIC automatically, and anon is a member of PUBLIC, so a function is
-- reachable without a login the moment it is created unless somebody says
-- otherwise. 0071 revoked the whole schema from anon once and verify.sql
-- asserts nothing has crept back. These six crept back, and it caught them on
-- a fresh install: "7 functions still open".
--
-- Not merely untidy. An unauthenticated caller reaching fn_delete_student is
-- stopped by has_role() only because auth.uid() is null there, which is one
-- accident away from not being true.
-- ---------------------------------------------------------------------------
revoke execute on function public.fn_student_delete_blockers(uuid) from public, anon;
revoke execute on function public.fn_staff_delete_blockers(uuid)   from public, anon;
revoke execute on function public.fn_login_delete_blockers(uuid)   from public, anon;
revoke execute on function public.fn_delete_student(uuid)          from public, anon;
revoke execute on function public.fn_delete_staff(uuid)            from public, anon;
revoke execute on function public.fn_delete_login(uuid)            from public, anon;

grant execute on function public.fn_student_delete_blockers(uuid) to authenticated;
grant execute on function public.fn_staff_delete_blockers(uuid)   to authenticated;
grant execute on function public.fn_login_delete_blockers(uuid)   to authenticated;
grant execute on function public.fn_delete_student(uuid)          to authenticated;
grant execute on function public.fn_delete_staff(uuid)            to authenticated;
grant execute on function public.fn_delete_login(uuid)            to authenticated;
