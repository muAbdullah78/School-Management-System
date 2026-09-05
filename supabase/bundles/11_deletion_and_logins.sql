-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0094_deletion.sql
-- ─────────────────────────────────────────────────────────────────────────
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
  select profile_id into v_profile from public.staff where id = p_staff_id;
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
     where i.enrollment_id = e.id and e.student_id = p_student_id;
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

  update public.staff set profile_id = null where profile_id = p_profile_id;
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0095_who_can_sign_in.sql
-- ─────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────
-- 0096_start_again.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- 0096  Starting again
--
-- WHY. Every school's first week is the same: somebody types in fifteen made-up
-- children to see how it works, raises a few challans, marks a register, and
-- then wants the practice gone before the real admissions start. Until 0094
-- nothing could be deleted at all. With 0094 they can now remove records one at
-- a time, which is right for a typo and absurd for forty rows of practice.
--
-- WHAT IT DELETES. Every operational row belonging to the school: children,
-- families, staff records, classes, sessions, the fee structure, challans,
-- receipts, attendance, marks, exams, certificates, expenses, messages.
--
-- WHAT IT KEEPS, and each for a reason:
--
--   the school, its subscription and its settings   it is the same school
--   every login                                     a person is not data. The
--     owner would otherwise reset themselves out of their own account, and
--     deleting a login here cannot remove the auth user, so the address could
--     never be reused. Unwanted logins are removed one at a time on the Staff
--     screen, where the reason for each refusal can be shown.
--   the audit log                                   we do not build a button
--     that erases an audit trail. Not once, not for a trial.
--   anything of OURS: platform invoices, payments, claims, exports, operator
--     actions and support visits, and the school's review. Those are the
--     vendor's records that happen to name this school, and 0080 already made
--     them survive a school being deleted outright.
--
-- WHY ONLY DURING A TRIAL. A paying school with three years of fee history has
-- no legitimate use for this and one bad afternoon would end them. The trial is
-- exactly the period when the data is known to be practice.
--
-- HOW IT DELETES, AND WHY NOT A HAND-WRITTEN ORDER. Fifty-six tables carry a
-- school_id. A hand-written delete order would be wrong the first time somebody
-- adds a table and would fail with a foreign key error a school cannot act on.
-- So this loops: try every table, ignore the ones still referenced, go round
-- again, and stop when a pass changes nothing. Then it CHECKS, and raises if
-- any row is left. A new table is therefore covered the day it is created, and
-- if it somehow is not, this says so loudly instead of half-clearing a school.
-- =============================================================================

create or replace function public.fn_reset_school_data(p_confirm_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_school uuid := public.current_school_id();
  v_name   text;
  v_status public.subscription_status;
  -- Ours, not theirs. Never cleared by a school.
  v_keep   text[] := array[
    'subscriptions', 'school_settings', 'profiles', 'audit_log', 'reviews',
    'operator_actions', 'operator_sessions', 'platform_invoices',
    'platform_payments', 'platform_payment_claims', 'platform_exports'
  ];
  v_tables text[];
  v_t      text;
  v_before bigint;
  v_after  bigint;
  v_pass   int := 0;
  v_left   text[];
  v_total  bigint := 0;
  v_n      bigint;
begin
  if not public.has_role('owner') then
    raise exception 'Only the owner may clear the school''s data';
  end if;

  select s.name into v_name from public.schools s where s.id = v_school;
  select sub.status into v_status from public.subscriptions sub where sub.school_id = v_school;

  if v_status is distinct from 'trialing' then
    raise exception 'This is only available during the free trial. Ask us if you '
                    'really need to start again.';
  end if;

  -- Typing the school's name is the whole confirmation. A dialog that only
  -- needs one click gets clicked.
  if btrim(lower(coalesce(p_confirm_name, ''))) <> btrim(lower(coalesce(v_name, ''))) then
    raise exception 'Type the school''s name exactly to confirm';
  end if;

  select array_agg(c.relname order by c.relname) into v_tables
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'school_id' and a.attnum > 0
   where n.nspname = 'public' and c.relkind = 'r'
     and not (c.relname = any(v_keep));

  -- Count what is about to go, for the message afterwards.
  foreach v_t in array v_tables loop
    execute format('select count(*) from public.%I where school_id = $1', v_t)
      into v_n using v_school;
    v_total := v_total + v_n;
  end loop;

  -- The fixpoint. Ten passes is far more than the dependency depth of this
  -- schema; the check below is what actually decides whether it worked.
  loop
    v_pass := v_pass + 1;
    v_before := 0; v_after := 0;
    foreach v_t in array v_tables loop
      execute format('select count(*) from public.%I where school_id = $1', v_t)
        into v_n using v_school;
      v_before := v_before + v_n;
      begin
        execute format('delete from public.%I where school_id = $1', v_t) using v_school;
      exception when foreign_key_violation then
        -- Something else still points at these rows. A later pass will have
        -- removed it.
        null;
      end;
      execute format('select count(*) from public.%I where school_id = $1', v_t)
        into v_n using v_school;
      v_after := v_after + v_n;
    end loop;
    exit when v_after = 0 or v_after = v_before or v_pass >= 10;
  end loop;

  -- Prove it, rather than assume it. A half-cleared school is worse than an
  -- uncleared one, because the owner believes it is empty.
  v_left := array[]::text[];
  foreach v_t in array v_tables loop
    execute format('select count(*) from public.%I where school_id = $1', v_t)
      into v_n using v_school;
    if v_n > 0 then v_left := v_left || v_t; end if;
  end loop;

  if array_length(v_left, 1) > 0 then
    raise exception 'Could not clear everything: % still has rows. Nothing has been '
                    'left half done on purpose; please tell us.', array_to_string(v_left, ', ');
  end if;

  perform public.fn__log_operator_action('school.data_reset', v_school,
    jsonb_build_object('school', v_name, 'rows_removed', v_total, 'passes', v_pass));

  return jsonb_build_object('cleared', true, 'rows_removed', v_total, 'school', v_name);
end;
$$;

-- Postgres grants EXECUTE to PUBLIC by default and anon inherits it. This one
-- empties a school; it is not reachable without a login.
revoke execute on function public.fn_reset_school_data(text) from public, anon;
grant execute on function public.fn_reset_school_data(text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- Record what this bundle applied (no-op before 0069 creates the ledger)
-- ─────────────────────────────────────────────────────────────────────────
do $ledger$
begin
  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then
    raise notice 'migration ledger not present yet — nothing recorded';
    return;
  end if;
  perform public.fn_record_migration('0094_deletion.sql', '11_deletion_and_logins.sql');
  perform public.fn_record_migration('0095_who_can_sign_in.sql', '11_deletion_and_logins.sql');
  perform public.fn_record_migration('0096_start_again.sql', '11_deletion_and_logins.sql');
end $ledger$;
