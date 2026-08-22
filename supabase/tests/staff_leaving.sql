-- =============================================================================
-- When a member of staff leaves.
--
-- The rules this file defends:
--
--  1. LEAVING REVOKES ACCESS. This is the whole reason 0053 exists. The old
--     "Deactivate" button wrote staff.status and nothing anywhere reads
--     staff.status — access is gated on profiles.active. A resigned teacher
--     could still log in and mark attendance. The test therefore does not check
--     that a column changed; it becomes the departed teacher and asserts that
--     is_staff(), has_role() and current_school_id() all refuse her.
--  2. LEAVING VACATES THE CLASS-TEACHER SLOTS. sections.class_teacher_id is
--     what result cards print, and the Class Teachers screen builds its dropdown
--     from active staff only — so a stale id rendered as "— unassigned —" while
--     the card still printed the departed teacher's name.
--  3. HISTORY SURVIVES. Assignments for sessions that had already ended are
--     kept. "Who taught 1-A in 2023-24" must still be answerable.
--  4. A SCHOOL CANNOT LOCK ITSELF OUT. Processing the exit of the only active
--     owner must fail, and must leave NOTHING behind — not the leaving date, not
--     the vacated sections.
--  5. THE UNDO IS HONEST. Rejoining restores the login and clears left_on, and
--     deliberately does NOT put back the class-teacher slots: a replacement may
--     be in them, and silently overwriting that is how two teachers end up on
--     one result card.
--  6. THE ROSTER CAN SEE THE LOGIN. "No account" and "account switched off" are
--     different facts, so login_active is NULL for one and false for the other.
--  7. Revoking access is owner/principal only — a clerk may edit a staff record
--     but not close somebody's access to every child's file.
--  8. Nothing crosses a school boundary.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/staff_leaving.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

-- Run a statement in a subtransaction and assert it was refused. The
-- subtransaction matters: without it the first expected failure would abort the
-- whole test run. `p_expect` is matched against the message so that a test
-- cannot pass on the WRONG error — which is how a permission test quietly
-- becomes a typo test.
create or replace function pg_temp.refuses(p_sql text, p_label text, p_expect text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if p_expect is not null and sqlerrm not like p_expect then
      raise exception 'FAIL  % — refused, but with the wrong message: %', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (%)', p_label, sqlerrm;
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

create or replace function pg_temp.staff_id(p_name text) returns uuid language sql as $$
  select id from public.staff where full_name = p_name and deleted_at is null
$$;

-- --- Fixture -----------------------------------------------------------------
-- School A: an owner (who is ALSO a staff member, so rule 4 has something to
-- bite on), a principal, a clerk, a teacher with a login and a teacher without
-- one. One class, two sections, both class-taught by the teacher with a login,
-- plus a teaching assignment in the current session and one in a session that
-- has already ended.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_own  uuid := '00000000-0000-0000-0000-00000000fa01';
  v_prin uuid := '00000000-0000-0000-0000-00000000fa02';
  v_clerk uuid := '00000000-0000-0000-0000-00000000fa03';
  v_tch  uuid := '00000000-0000-0000-0000-00000000fa04';
  v_ownb uuid := '00000000-0000-0000-0000-00000000fa05';
  v_sess uuid; v_old uuid; v_cl uuid; v_sec_a uuid; v_sec_b uuid;
  v_ayesha uuid; v_bilal uuid; v_ownstaff uuid;
  v_sess_b uuid; v_cl_b uuid;
begin
  insert into public.schools (name) values ('Leave A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Leave B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own,'lown@lv.test'), (v_prin,'lprin@lv.test'), (v_clerk,'lclerk@lv.test'),
    (v_tch,'ltch@lv.test'), (v_ownb,'lownb@lv.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own,   'Lv Owner',     'owner',         v_a),
    (v_prin,  'Lv Principal', 'principal',     v_a),
    (v_clerk, 'Lv Clerk',     'admin_clerk',   v_a),
    (v_tch,   'Lv Ayesha',    'class_teacher', v_a),
    (v_ownb,  'Lv Owner B',   'owner',         v_b)
  on conflict (id) do update set school_id = excluded.school_id,
                                 role      = excluded.role,
                                 full_name = excluded.full_name,
                                 active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);

  -- A session that has already ended, and the current one.
  insert into public.academic_sessions (name, starts_on, ends_on, is_current, school_id)
    values ('2023-2024', current_date - 800, current_date - 440, false, v_a)
    returning id into v_old;
  insert into public.academic_sessions (name, starts_on, ends_on, is_current, school_id)
    values ('2025-2026', current_date - 60, current_date + 300, true, v_a)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;

  insert into public.classes (name, level_order, school_id)
    values ('Class 1', 1, v_a) returning id into v_cl;
  insert into public.sections (class_id, name, sort_order, school_id)
    values (v_cl, 'A', 1, v_a) returning id into v_sec_a;
  insert into public.sections (class_id, name, sort_order, school_id)
    values (v_cl, 'B', 2, v_a) returning id into v_sec_b;

  insert into public.staff (full_name, designation, employee_no, joined_on, profile_id, school_id)
    values ('Ayesha Teacher', 'Senior Teacher', 'EMP-1',
            current_date - 700, v_tch, v_a) returning id into v_ayesha;
  -- No profile_id: a member of staff with no login at all.
  insert into public.staff (full_name, designation, employee_no, joined_on, school_id)
    values ('Bilal Helper', 'Lab Assistant', 'EMP-2',
            current_date - 200, v_a) returning id into v_bilal;
  -- The owner is a staff member too, which is normal in a small school and is
  -- what makes the lock-out guard reachable.
  insert into public.staff (full_name, designation, joined_on, profile_id, school_id)
    values ('Lv Owner', 'Proprietor', current_date - 900, v_own, v_a)
    returning id into v_ownstaff;

  update public.sections set class_teacher_id = v_ayesha where id in (v_sec_a, v_sec_b);
  insert into public.teacher_assignments (staff_id, session_id, class_id, section_id, school_id)
    values (v_ayesha, v_sess, v_cl, v_sec_a, v_a),
           (v_ayesha, v_old,  v_cl, v_sec_a, v_a);

  -- School B, with its own staff member, so a leak would be obvious.
  perform set_config('test.uid', v_ownb::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B One', 1, v_b) returning id into v_cl_b;
  insert into public.staff (full_name, designation, joined_on, school_id)
    values ('B Side Teacher', 'Teacher', current_date - 100, v_b);

  -- Deliberately corrupt: a section in school B naming school A's teacher as
  -- its class teacher. sections.class_teacher_id is a plain FK to staff(id)
  -- with no school in the key, so nothing in the schema forbids this — only the
  -- school filters inside fn_staff_roster keep it out of A's screen. Without a
  -- row like this those filters are unreachable, and a test that cannot fail
  -- when a guard is deleted is not testing the guard. Assertion 4 is what
  -- notices.
  insert into public.sections (class_id, name, sort_order, class_teacher_id, school_id)
    values (v_cl_b, 'X', 1, v_ayesha, v_b);

  perform set_config('test.uid', v_own::text, false);
end;
$seed$;

-- =============================================================================
-- 1. The roster tells the truth the old screen could not
-- =============================================================================
do $$
declare r record; n integer;
begin
  perform pg_temp.be('Lv Owner');

  select count(*) into n from public.fn_staff_roster();
  perform pg_temp.ok(n = 3, '1. the roster returns this school''s three staff (got ' || n || ')');

  select * into r from public.fn_staff_roster() where full_name = 'Ayesha Teacher';
  perform pg_temp.ok(r.login_active is true,
    '2. a teacher with a working login reads login_active = true');
  perform pg_temp.ok(r.login_role = 'class_teacher',
    '3. the roster names the login''s role');
  perform pg_temp.ok(r.class_teacher_of = 'Class 1-A, Class 1-B',
    '4. it names the sections she is class teacher of, in class order (got '
      || coalesce(r.class_teacher_of, 'null') || ')');
  perform pg_temp.ok(r.assignments = 1,
    '5. it counts CURRENT-session assignments only, not the ended session (got '
      || r.assignments || ')');
  perform pg_temp.ok(r.status = 'active' and r.left_on is null,
    '6. an active member of staff has no leaving date');

  select * into r from public.fn_staff_roster() where full_name = 'Bilal Helper';
  perform pg_temp.ok(r.login_active is null,
    '7. NO ACCOUNT reads as null, not false — "never had a login" and '
    '"login switched off" are different facts');
  perform pg_temp.ok(r.class_teacher_of is null and r.assignments = 0,
    '8. somebody holding nothing reads as holding nothing');
end;
$$;

-- =============================================================================
-- 2. Who may do this
-- =============================================================================
do $$
declare v_id uuid := pg_temp.staff_id('Ayesha Teacher');
begin
  perform pg_temp.be('Lv Clerk');
  perform pg_temp.ok((select count(*) from public.fn_staff_roster()) = 3,
    '9. a clerk may READ the roster — they maintain staff records');
  perform pg_temp.refuses(
    format('select public.fn_staff_leave(%L::uuid, current_date, %L)', v_id, 'resigned'),
    '10. a clerk may not record a leaving — it revokes access', '%owner or principal%');
  perform pg_temp.refuses(
    format('select public.fn_staff_set_login_active(%L::uuid, false, null)', v_id),
    '11. a clerk may not close a login', '%owner or principal%');

  perform pg_temp.be('Lv Ayesha');
  perform pg_temp.refuses('select count(*) from public.fn_staff_roster()',
    '12. a class teacher cannot read the staff roster at all', '%Not permitted%');
end;
$$;

-- =============================================================================
-- 3. The dates have to make sense
-- =============================================================================
do $$
declare v_id uuid := pg_temp.staff_id('Ayesha Teacher');
begin
  perform pg_temp.be('Lv Principal');
  perform pg_temp.refuses(
    format('select public.fn_staff_leave(%L::uuid, current_date + 5, null)', v_id),
    '13. a future last working day is refused — the login closes now, not then',
    '%cannot be in the future%');
  perform pg_temp.refuses(
    format('select public.fn_staff_leave(%L::uuid, current_date - 900, null)', v_id),
    '14. a last working day before the joining date is a typo',
    '%before the joining date%');
end;
$$;

-- =============================================================================
-- 4. A school cannot lock itself out — and a refusal leaves NOTHING behind
-- =============================================================================
do $$
declare v_own uuid := pg_temp.staff_id('Lv Owner'); n integer; v_status text;
begin
  perform pg_temp.be('Lv Owner');
  perform pg_temp.refuses(
    format('select public.fn_staff_leave(%L::uuid, current_date, %L)', v_own, 'retiring'),
    '15. the only active owner cannot process their own exit',
    '%only active owner%');

  -- The important half. fn_staff_leave writes the status, vacates sections and
  -- deletes assignments BEFORE it touches the login, so if the guard fired
  -- late and the function were not one transaction, the school would be left
  -- with a half-processed exit: an owner marked as gone who can still log in.
  select status into v_status from public.staff where id = v_own;
  perform pg_temp.ok(v_status = 'active',
    '16. the refusal rolled back the status change (got ' || v_status || ')');
  select count(*) into n from public.profiles
   where full_name = 'Lv Owner' and active;
  perform pg_temp.ok(n = 1, '17. the owner can still log in');
  -- Scoped to THIS school on purpose: the fixture deliberately puts a corrupt
  -- cross-school row in sections (see the seed), so an unscoped count here
  -- would be measuring the wrong school's data.
  select count(*) into n from public.sections
   where class_teacher_id is not null and school_id = public.current_school_id();
  perform pg_temp.ok(n = 2, '18. and the class-teacher slots are untouched');
end;
$$;

-- =============================================================================
-- 5. The leaving itself
-- =============================================================================
do $$
declare
  v_id uuid := pg_temp.staff_id('Ayesha Teacher');
  j jsonb; n integer; r record;
begin
  perform pg_temp.be('Lv Principal');
  j := public.fn_staff_leave(v_id, current_date - 3, 'Resigned — moved to Lahore');

  perform pg_temp.ok((j->>'login_revoked')::boolean,
    '19. the leaving REVOKED THE LOGIN — the entire point of 0053');
  perform pg_temp.ok((j->>'sections_count')::int = 2,
    '20. it reports how many class-teacher slots it vacated');
  perform pg_temp.ok(j->>'sections_vacated' = 'Class 1-A, Class 1-B',
    '21. and NAMES them, so the principal knows what to reassign (got '
      || (j->>'sections_vacated') || ')');
  perform pg_temp.ok((j->>'assignments_removed')::int = 1,
    '22. it removed the current-session assignment only (got '
      || (j->>'assignments_removed') || ')');
  perform pg_temp.ok((j->>'left_on')::date = current_date - 3,
    '23. the leaving date is the one given, not today');

  select count(*) into n from public.staff
   where id = v_id and status = 'left' and left_on = current_date - 3;
  perform pg_temp.ok(n = 1, '24. the staff row records both facts');

  select count(*) into n from public.sections
   where class_teacher_id = v_id and school_id = public.current_school_id();
  perform pg_temp.ok(n = 0,
    '25. no section still names her as class teacher — result cards print this column');

  select count(*) into n from public.teacher_assignments ta
    join public.academic_sessions s on s.id = ta.session_id
   where ta.staff_id = v_id and s.is_current
     and ta.school_id = public.current_school_id();
  perform pg_temp.ok(n = 0, '26. the current-session assignment is gone');

  select count(*) into n from public.teacher_assignments ta
    join public.academic_sessions s on s.id = ta.session_id
   where ta.staff_id = v_id and s.name = '2023-2024';
  perform pg_temp.ok(n = 1,
    '27. the ENDED session''s assignment survives — "who taught 1-A in 2023-24" '
    'must still be answerable');

  perform pg_temp.be('Lv Owner');
  select * into r from public.fn_staff_roster() where full_name = 'Ayesha Teacher';
  perform pg_temp.ok(r.login_active is false,
    '28. the roster now shows the login as closed, not absent');
  perform pg_temp.ok(r.class_teacher_of is null and r.assignments = 0,
    '29. and shows her holding nothing');
  perform pg_temp.ok(
    (select full_name from public.fn_staff_roster() limit 1) <> 'Ayesha Teacher',
    '30. people who have left sort below people who are here');
end;
$$;

-- =============================================================================
-- 6. She really cannot get in
--
-- Not "the column changed" — the actual guards, as her. This is the assertion
-- the old Deactivate button would have failed.
-- =============================================================================
do $$
begin
  perform pg_temp.be('Lv Ayesha');
  perform pg_temp.ok(public.is_staff() = false,
    '31. is_staff() refuses her — no marks, no attendance, no child records');
  perform pg_temp.ok(public.has_role('class_teacher') = false,
    '32. has_role() refuses her');
  perform pg_temp.ok(public.current_school_id() is null,
    '33. she has no school context at all, so every scoped read returns nothing');
end;
$$;

-- =============================================================================
-- 7. It cannot be done twice, and the two facts cannot contradict each other
-- =============================================================================
do $$
declare v_id uuid := pg_temp.staff_id('Ayesha Teacher');
begin
  perform pg_temp.be('Lv Owner');
  perform pg_temp.refuses(
    format('select public.fn_staff_leave(%L::uuid, current_date, null)', v_id),
    '34. a second leaving is refused, and the message names her',
    '%Ayesha Teacher is already recorded%');
  perform pg_temp.refuses(
    format('select public.fn_staff_set_login_active(%L::uuid, true, null)', v_id),
    '35. her login cannot be reopened while she is recorded as having left',
    '%recorded as having left%');
end;
$$;

-- =============================================================================
-- 8. Coming back
-- =============================================================================
do $$
declare v_id uuid := pg_temp.staff_id('Ayesha Teacher'); j jsonb; n integer;
begin
  perform pg_temp.be('Lv Owner');
  j := public.fn_staff_rejoin(v_id, 'Came back in September');
  perform pg_temp.ok((j->>'login_restored')::boolean,
    '36. rejoining restores the login');

  select count(*) into n from public.staff
   where id = v_id and status = 'active' and left_on is null;
  perform pg_temp.ok(n = 1, '37. and clears the leaving date');

  select count(*) into n from public.sections
   where class_teacher_id = v_id and school_id = public.current_school_id();
  perform pg_temp.ok(n = 0,
    '38. it deliberately does NOT put the class-teacher slots back — a '
    'replacement may be in them, and two teachers on one result card is worse');

  perform pg_temp.be('Lv Ayesha');
  perform pg_temp.ok(public.is_staff(),
    '39. she can work again');

  perform pg_temp.be('Lv Owner');
  perform pg_temp.refuses(
    format('select public.fn_staff_rejoin(%L::uuid, null)', v_id),
    '40. rejoining somebody who is already here is refused', '%already active%');
end;
$$;

-- =============================================================================
-- 9. Suspension without leaving — and the legacy rows this exists for
-- =============================================================================
do $$
declare
  v_id uuid := pg_temp.staff_id('Ayesha Teacher');
  v_bilal uuid := pg_temp.staff_id('Bilal Helper');
  j jsonb; v_status text;
begin
  perform pg_temp.be('Lv Owner');
  j := public.fn_staff_set_login_active(v_id, false, 'Under enquiry');
  perform pg_temp.ok((j->>'changed')::boolean and (j->>'login_active')::boolean = false,
    '41. a login can be closed without recording anyone as having left');

  select status into v_status from public.staff where id = v_id;
  perform pg_temp.ok(v_status = 'active',
    '42. her employment record still says active, because she has not left');

  perform pg_temp.be('Lv Ayesha');
  perform pg_temp.ok(public.is_staff() = false, '43. but she cannot get in');

  perform pg_temp.be('Lv Owner');
  j := public.fn_staff_set_login_active(v_id, false, 'again');
  perform pg_temp.ok((j->>'changed')::boolean = false,
    '44. closing an already-closed login reports changed = false rather than '
    'writing a second audit row');

  j := public.fn_staff_set_login_active(v_id, true, 'Cleared');
  perform pg_temp.ok((j->>'changed')::boolean,
    '45. and it can be reopened, because she never left');

  perform pg_temp.refuses(
    format('select public.fn_staff_set_login_active(%L::uuid, false, null)', v_bilal),
    '46. somebody with no login has no login to close', '%no login to change%');
end;
$$;

-- =============================================================================
-- 10. The audit trail
-- =============================================================================
do $$
declare n integer; v_reason text;
begin
  perform pg_temp.be('Lv Owner');
  select count(*) into n from public.audit_log
   where action = 'STAFF_LEAVE' and entity = 'staff';
  perform pg_temp.ok(n = 1, '47. the leaving is in the audit log');

  select reason into v_reason from public.audit_log
   where action = 'STAFF_LEAVE' limit 1;
  perform pg_temp.ok(v_reason = 'Resigned — moved to Lahore',
    '48. with the reason the principal typed');

  select count(*) into n from public.audit_log where action = 'STAFF_REJOIN';
  perform pg_temp.ok(n = 1, '49. so is the rejoining');

  select count(*) into n from public.audit_log
   where action in ('STAFF_LOGIN_REVOKE', 'STAFF_LOGIN_RESTORE');
  perform pg_temp.ok(n = 2,
    '50. and both login changes — but only the ones that changed something (got '
      || n || ')');

  select count(*) into n from public.audit_log
   where action like 'STAFF_%' and school_id is null;
  perform pg_temp.ok(n = 0, '51. every audit row is stamped with the school');
end;
$$;

-- =============================================================================
-- 11. The constraints catch what a stray UPDATE would not
-- =============================================================================
do $$
declare v_id uuid := pg_temp.staff_id('Ayesha Teacher');
begin
  perform pg_temp.refuses(
    format('update public.staff set left_on = current_date where id = %L::uuid', v_id),
    '52. an ACTIVE member of staff cannot have a leaving date', '%staff_left_on_chk%');
  perform pg_temp.refuses(
    format('update public.staff set status = ''inactive'' where id = %L::uuid', v_id),
    '53. "inactive" is no longer a spelling of anything', '%staff_status_chk%');
end;
$$;

-- =============================================================================
-- 12. Nothing crosses a school boundary
-- =============================================================================
do $$
declare v_id uuid := pg_temp.staff_id('Ayesha Teacher'); n integer;
begin
  perform pg_temp.be('Lv Owner B');
  select count(*) into n from public.fn_staff_roster();
  perform pg_temp.ok(n = 1,
    '54. school B''s roster holds only school B''s staff (got ' || n || ')');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_staff_roster() where full_name = 'Ayesha Teacher'),
    '55. and does not name school A''s teacher');

  perform pg_temp.refuses(
    format('select public.fn_staff_leave(%L::uuid, current_date, null)', v_id),
    '56. another school''s owner cannot process my teacher''s exit', '%not found%');
  perform pg_temp.refuses(
    format('select public.fn_staff_set_login_active(%L::uuid, false, null)', v_id),
    '57. nor close her login', '%not found%');
  perform pg_temp.refuses(
    format('select public.fn_staff_rejoin(%L::uuid, null)', v_id),
    '58. nor bring her back', '%not found%');
end;
$$;

-- =============================================================================
-- 13. The boundary that is allowed: leaving on the day you joined
-- =============================================================================
do $$
declare v_id uuid; j jsonb;
begin
  perform pg_temp.be('Lv Owner');
  insert into public.staff (full_name, joined_on, school_id)
    values ('One Day Wonder', current_date, public.current_school_id())
    returning id into v_id;
  j := public.fn_staff_leave(v_id, current_date, 'Did not stay');
  perform pg_temp.ok((j->>'left_on')::date = current_date,
    '59. joining and leaving on the same day is allowed');
  perform pg_temp.ok((j->>'had_login')::boolean = false
                 and (j->>'login_revoked')::boolean = false,
    '60. and somebody with no login is reported as having had none, rather than '
    'as having been revoked');
end;
$$;

rollback;
