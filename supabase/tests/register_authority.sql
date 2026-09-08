-- =============================================================================
-- Who may write an exam, and what a lock is worth against a DELETE.
--
-- WHERE THIS CAME FROM. Migration 0024 recorded the exact fault this suite
-- defends, in 2024, for two tables:
--
--   "Scoping was only enforced inside the RPCs — but the blanket table grant
--    (0001) + role-only RLS let a teacher write attendance_daily /
--    mark_entries DIRECTLY via PostgREST, bypassing fn_may_manage_class.
--    Revoke direct DML so writes MUST go through the scoped SECURITY DEFINER
--    functions."
--
-- It revoked the grant on those two and left `assessments` alone: blanket
-- INSERT, UPDATE and DELETE for `authenticated`, and a policy checking only
-- the school and the role. And `assessments` is the one with a CASCADE under
-- it. mark_entries.assessment_id is ON DELETE CASCADE, so a delete there takes
-- the marks with it, and a cascade is not subject to row security, to any
-- function's checks, or to mark_entries.is_locked.
--
-- Measured on the finished demo school before 0129, as one subject teacher, in
-- one statement:
--
--     BEFORE: 663 assessments, 10944 marks (5364 locked)
--     AFTER:    0 assessments,  4983 marks (   0 locked)
--
-- EVERY ASSERTION HERE RUNS AS `authenticated`, because that is the only role
-- these rules apply to. The suite runs as the table owner, and both RLS and
-- table grants are silent for an owner: without `set local role authenticated`
-- each of these passes while proving nothing. Same reason
-- supabase/tests/tenant_isolation.sql does it.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/register_authority.sql
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

-- Try a statement AS AUTHENTICATED and say whether it was refused. The role is
-- reset on every path out, including the exception path: a suite that leaves
-- `role` set behind runs the rest of itself as somebody else.
create or replace function pg_temp.refused_as_user(p_sql text)
returns boolean language plpgsql as $$
begin
  set local role authenticated;
  execute p_sql;
  reset role;
  return false;
exception when others then
  reset role;
  return true;
end;
$$;

-- The same, but it must be refused FOR THE RIGHT REASON. "permission denied"
-- and "row-level security" both mean the door is shut; a syntax error or a
-- missing column also raises, and would make every assertion here pass.
create or replace function pg_temp.refused_saying(p_sql text, p_needle text)
returns boolean language plpgsql as $$
declare v_msg text;
begin
  set local role authenticated;
  execute p_sql;
  reset role;
  return false;
exception when others then
  v_msg := sqlerrm;
  reset role;
  if position(lower(p_needle) in lower(v_msg)) > 0 then return true; end if;
  raise notice '  (refused, but saying: %)', v_msg;
  return false;
end;
$$;

create or replace function pg_temp.rows_as_user(p_sql text)
returns bigint language plpgsql as $$
declare n bigint;
begin
  set local role authenticated;
  execute p_sql;
  get diagnostics n = row_count;
  reset role;
  return n;
exception when others then
  reset role;
  return -1;
end;
$$;

create table pg_temp.ids (k text primary key, v uuid);

-- --- Fixture -----------------------------------------------------------------
-- One school, two classes, and a subject teacher who teaches Maths in class A
-- and nothing at all in class B. An assessment in each, and marks in each, some
-- finalised.
do $seed$
declare
  v_sch uuid; v_sess uuid; v_a uuid; v_b uuid;
  v_owner uuid := '00000000-0000-0000-0000-0000000006a1';
  v_teach uuid := '00000000-0000-0000-0000-0000000006a2';
  v_staff uuid; v_maths uuid; v_eng uuid;
  v_stu_a uuid; v_stu_b uuid; v_enr_a uuid; v_enr_b uuid;
  v_as_a uuid; v_as_b uuid; v_term uuid; v_xs uuid;
begin
  insert into public.schools (name) values ('Authority School') returning id into v_sch;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_sch, 'growth', 'active', current_date - 1);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'owner@authority.test'), (v_teach, 'teacher@authority.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner, 'Authority Owner', 'owner', v_sch),
    (v_teach, 'Maths Teacher',   'subject_teacher', v_sch)
  on conflict (id) do update set school_id = excluded.school_id,
                                 role = excluded.role, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);

  insert into public.academic_sessions (name, is_current, school_id, starts_on, ends_on)
    values ('2026-2027', true, v_sch, current_date - 60, current_date + 300)
    returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_sch;

  insert into public.classes (name, level_order, school_id)
    values ('Class A', 1, v_sch) returning id into v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Class B', 2, v_sch) returning id into v_b;
  insert into public.subjects (name, school_id)
    values ('Maths', v_sch) returning id into v_maths;
  insert into public.subjects (name, school_id)
    values ('English', v_sch) returning id into v_eng;

  -- The teacher, and their ONE assignment: Maths, class A.
  insert into public.staff (full_name, designation, school_id, profile_id)
    values ('Maths Teacher', 'Teacher', v_sch, v_teach) returning id into v_staff;
  update public.profiles set staff_id = v_staff where id = v_teach;
  insert into public.subject_teachers (school_id, session_id, class_id, section_id,
                                       subject_id, staff_id)
    values (v_sch, v_sess, v_a, null, v_maths, v_staff);

  -- A child in each class.
  insert into public.students (full_name, father_name, school_id)
    values ('Child A', 'Father A', v_sch) returning id into v_stu_a;
  insert into public.students (full_name, father_name, school_id)
    values ('Child B', 'Father B', v_sch) returning id into v_stu_b;
  insert into public.enrollments (school_id, session_id, class_id, student_id, status)
    values (v_sch, v_sess, v_a, v_stu_a, 'active') returning id into v_enr_a;
  insert into public.enrollments (school_id, session_id, class_id, student_id, status)
    values (v_sch, v_sess, v_b, v_stu_b, 'active') returning id into v_enr_b;

  -- An assessment in each class. A's marks are FINALISED; B's are not.
  insert into public.assessments (school_id, session_id, class_id, subject_id,
                                  title, assessment_date, max_marks)
    values (v_sch, v_sess, v_a, v_maths, 'Maths Test 1', current_date - 10, 20)
    returning id into v_as_a;
  insert into public.assessments (school_id, session_id, class_id, subject_id,
                                  title, assessment_date, max_marks)
    values (v_sch, v_sess, v_b, v_eng, 'English Test 1', current_date - 10, 20)
    returning id into v_as_b;
  insert into public.mark_entries (school_id, assessment_id, enrollment_id,
                                   marks, max_marks, is_locked, marked_by)
    values (v_sch, v_as_a, v_enr_a, 18, 20, true, v_owner);
  insert into public.mark_entries (school_id, assessment_id, enrollment_id,
                                   marks, max_marks, is_locked, marked_by)
    values (v_sch, v_as_b, v_enr_b, 15, 20, false, v_owner);

  -- And a term paper with a finalised mark on it, which is the delete the app
  -- actually offers.
  insert into public.exam_terms (school_id, session_id, name, term_type)
    values (v_sch, v_sess, 'First Term', 'first') returning id into v_term;
  insert into public.exam_subjects (school_id, exam_term_id, class_id, subject_id,
                                    max_marks, pass_marks)
    values (v_sch, v_term, v_a, v_maths, 100, 33) returning id into v_xs;
  insert into public.mark_entries (school_id, exam_subject_id, enrollment_id,
                                   marks, max_marks, is_locked, marked_by)
    values (v_sch, v_xs, v_enr_a, 71, 100, true, v_owner);

  insert into pg_temp.ids (k, v) values
    ('sch', v_sch), ('sess', v_sess), ('a', v_a), ('b', v_b),
    ('owner', v_owner), ('teach', v_teach),
    ('maths', v_maths), ('eng', v_eng),
    ('enr_a', v_enr_a), ('enr_b', v_enr_b),
    ('as_a', v_as_a), ('as_b', v_as_b), ('term', v_term), ('xs', v_xs);
end $seed$;

-- =============================================================================
-- 1. WHAT 0024 ALREADY PROTECTS, asserted here so a re-grant cannot pass
--    unnoticed.
--
-- The register and the marks are protected by the TABLE GRANT, not by their
-- policies: 0024 revoked direct DML and left the role-only policies in place.
-- That is a working defence and an invisible one, and it is why the same fault
-- survived on `assessments` for two years. So both halves are asserted: the
-- grant is gone, AND the policy would hold if the grant ever came back.
-- =============================================================================
do $$
declare v_teach uuid := (select v from pg_temp.ids where k='teach');
begin
  perform set_config('test.uid', v_teach::text, false);

  perform pg_temp.ok(
    not has_table_privilege('authenticated', 'public.attendance_daily', 'INSERT')
    and not has_table_privilege('authenticated', 'public.attendance_daily', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.attendance_daily', 'DELETE'),
    '1  a browser holds no direct write on the register (0024). This, and not '
    || 'the policy, is what actually stops a teacher rewriting another '
    || 'class''s attendance');
  perform pg_temp.ok(
    not has_table_privilege('authenticated', 'public.mark_entries', 'INSERT')
    and not has_table_privilege('authenticated', 'public.mark_entries', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.mark_entries', 'DELETE'),
    '2  nor on the marks');

  -- AND THE POLICY NOW SAYS THE SAME THING, so the two mechanisms agree. Before
  -- 0129 the policy said "any teacher, any row in the school", which is what
  -- the next person to read it would have believed.
  perform pg_temp.ok(
    (select coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')
       from pg_policy pol join pg_class c on c.oid = pol.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname='public' and c.relname='attendance_daily'
        and pol.polname='attendance_insert') ~ 'fn_may_manage_enrollment',
    '3  and the attendance policy narrows to the class as well, so a re-grant '
    || 'of direct DML would not reopen what 0024 closed');
end $$;

-- =============================================================================
-- 2. THE TABLE 0024 MISSED
--
-- `assessments` keeps blanket INSERT, UPDATE and DELETE for `authenticated`,
-- which is not a defect on its own: the app creates assessments from the
-- browser. The defect was the policy behind it.
-- =============================================================================
do $$
declare
  v_teach uuid := (select v from pg_temp.ids where k='teach');
  v_sch uuid := (select v from pg_temp.ids where k='sch');
  v_sess uuid := (select v from pg_temp.ids where k='sess');
  v_a uuid := (select v from pg_temp.ids where k='a');
  v_b uuid := (select v from pg_temp.ids where k='b');
  v_maths uuid := (select v from pg_temp.ids where k='maths');
  v_eng uuid := (select v from pg_temp.ids where k='eng');
  v_as_a uuid := (select v from pg_temp.ids where k='as_a');
  v_as_b uuid := (select v from pg_temp.ids where k='as_b');
begin
  perform set_config('test.uid', v_teach::text, false);
  perform pg_temp.ok(
    has_table_privilege('authenticated', 'public.assessments', 'DELETE'),
    '4  a browser DOES hold DELETE on assessments, which is why the policy '
    || 'behind it is the whole defence');

  -- 4a. The Maths teacher of class A may set a Maths test for class A.
  perform pg_temp.ok(
    pg_temp.rows_as_user(format(
      $q$insert into public.assessments (school_id, session_id, class_id, subject_id,
                                         title, assessment_date, max_marks)
         values (%L, %L, %L, %L, 'Maths Test 2', current_date, 20)$q$,
      v_sch, v_sess, v_a, v_maths)) = 1,
    '5  the Maths teacher of class A can set a Maths test for class A. This is '
    || 'the assertion that stops the four below passing because the door is '
    || 'shut to everybody');

  -- 4b. And not for a class they do not teach.
  perform pg_temp.ok(
    pg_temp.refused_saying(format(
      $q$insert into public.assessments (school_id, session_id, class_id, subject_id,
                                         title, assessment_date, max_marks)
         values (%L, %L, %L, %L, 'Not mine', current_date, 20)$q$,
      v_sch, v_sess, v_b, v_eng), 'row-level security'),
    '6  and cannot set a test for class B, which they do not teach at all');

  -- 4c. Nor for a subject they do not teach in a class they do.
  perform pg_temp.ok(
    pg_temp.refused_saying(format(
      $q$insert into public.assessments (school_id, session_id, class_id, subject_id,
                                         title, assessment_date, max_marks)
         values (%L, %L, %L, %L, 'English by the Maths teacher', current_date, 20)$q$,
      v_sch, v_sess, v_a, v_eng), 'row-level security'),
    '7  nor an ENGLISH test for their own class A, because the check is '
    || 'fn_may_mark_subject and not fn_may_manage_class: the maths teacher '
    || 'setting the English paper is the same mistake one column over');

  -- 4d. Editing somebody else's test.
  perform pg_temp.ok(
    pg_temp.rows_as_user(format(
      $q$update public.assessments set title = 'Renamed' where id = %L$q$, v_as_b)) = 0,
    '8  and cannot rename class B''s test');

  -- 4e. THE ONE THAT MATTERED. Deleting an assessment cascades to its marks.
  perform pg_temp.ok(
    pg_temp.rows_as_user(format(
      $q$delete from public.assessments where school_id = %L$q$, v_sch)) <= 0,
    '9  A TEACHER CANNOT DELETE AN ASSESSMENT AT ALL. Before 0129 this exact '
    || 'statement, from a subject teacher''s own browser, removed 663 '
    || 'assessments and 5,961 marks from the demo school, all 5,364 finalised '
    || 'ones among them');
  perform pg_temp.ok(
    (select count(*) from public.assessments where school_id = v_sch) >= 2,
    '10 and the assessments are all still there, which is what makes 9 a '
    || 'check on the delete rather than on the count');
end $$;

-- =============================================================================
-- 3. AND A LOCK HOLDS AGAINST A CASCADE
--
-- The owner may delete their own school's exam. What they may not do is
-- destroy finalised marks by deleting the row above them, which is what
-- is_locked is for and what a cascade ignores.
-- =============================================================================
do $$
declare
  v_owner uuid := (select v from pg_temp.ids where k='owner');
  v_sch uuid := (select v from pg_temp.ids where k='sch');
  v_as_a uuid := (select v from pg_temp.ids where k='as_a');
  v_as_b uuid := (select v from pg_temp.ids where k='as_b');
  v_term uuid := (select v from pg_temp.ids where k='term');
  v_xs uuid := (select v from pg_temp.ids where k='xs');
  v_before bigint;
begin
  perform set_config('test.uid', v_owner::text, false);

  perform pg_temp.ok(
    pg_temp.refused_saying(
      format($q$delete from public.assessments where id = %L$q$, v_as_a),
      'finalised mark'),
    '11 even the OWNER cannot delete an assessment whose marks are finalised, '
    || 'and the message says how many would go');
  perform pg_temp.ok(
    (select count(*) from public.mark_entries
      where assessment_id = v_as_a and is_locked) = 1,
    '12 and the finalised mark is still there');

  -- The legitimate case, which must keep working: a test set up wrongly, that
  -- nobody has finalised.
  select count(*) into v_before from public.audit_log
   where school_id = v_sch and action = 'MARKS_DESTROYED_BY_DELETE';
  perform pg_temp.ok(
    pg_temp.rows_as_user(format(
      $q$delete from public.assessments where id = %L$q$, v_as_b)) = 1,
    '13 an assessment with no finalised marks CAN still be deleted, because a '
    || 'test set up wrongly has to be removable or the mistake is permanent');
  perform pg_temp.ok(
    (select count(*) from public.audit_log
      where school_id = v_sch and action = 'MARKS_DESTROYED_BY_DELETE') = v_before + 1,
    '14 and the marks that went with it are audited with their count, because '
    || 'forty marks disappearing silently is the other way to lose a school''s '
    || 'work');

  -- The delete the app actually offers: removing a subject from an exam.
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format($q$delete from public.exam_subjects where id = %L$q$, v_xs),
      'finalised mark'),
    '15 removing a subject from an exam is refused once its marks are '
    || 'finalised. This is the one delete web/src/lib/db.ts issues, and before '
    || '0129 it cascaded straight through the lock');

  -- And two hops up.
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format($q$delete from public.exam_terms where id = %L$q$, v_term),
      'finalised mark'),
    '16 and so is deleting the whole exam term, whose marks are TWO cascades '
    || 'away: exam_terms to exam_subjects to mark_entries, with nothing on the '
    || 'way down that would have stopped them');
  perform pg_temp.ok(
    (select count(*) from public.mark_entries where exam_subject_id = v_xs) = 1,
    '17 and the term paper''s mark survived both attempts');
end $$;

-- =============================================================================
-- 4. AND CLEARING A WHOLE SCHOOL STILL WORKS
--
-- THE REGRESSION THIS FILE EXISTS TO CATCH, and school_lifecycle.sql could not:
-- its test school has no finalised marks, so it passed while offboarding any
-- real customer would have failed.
--
-- The three functions that empty a school delete their tables in a multi-pass
-- loop that swallows ONLY foreign_key_violation, on purpose. fn__school_data_tables()
-- lists assessments at position 4 and mark_entries at 27, so pass one deletes
-- assessments while every locked mark is still there, the trigger raises 42501,
-- and the whole purge aborts. The flag app.clearing_school is what stops that,
-- and this is the assertion that keeps it working.
-- =============================================================================
do $$
declare
  v_owner uuid := (select v from pg_temp.ids where k='owner');
  v_sch uuid := (select v from pg_temp.ids where k='sch');
  v_locked bigint;
  v_pos_as int; v_pos_me int;
begin
  perform set_config('test.uid', v_owner::text, false);

  -- The premise, asserted rather than assumed: the order really is the wrong
  -- way round, so this test is exercising the hard case.
  select n into v_pos_as from (
    select row_number() over () as n, table_name from public.fn__school_data_tables()) t
   where table_name = 'assessments';
  select n into v_pos_me from (
    select row_number() over () as n, table_name from public.fn__school_data_tables()) t
   where table_name = 'mark_entries';
  perform pg_temp.ok(v_pos_as < v_pos_me,
    format('18 assessments are cleared at position %s and the marks at %s, so a '
      || 'wholesale clear reaches the parent while its finalised marks still '
      || 'exist. If this ever reverses, the assertion below stops testing '
      || 'anything', v_pos_as, v_pos_me));

  select count(*) into v_locked from public.mark_entries
   where school_id = v_sch and is_locked;
  perform pg_temp.ok(v_locked > 0,
    '19 and this school has finalised marks, which is what school_lifecycle.sql''s '
    || 'purge test does not');

  -- TESTED ON THE TRIGGER'S OWN CONTRACT, not by calling one of the four wipe
  -- functions. fn_reset_school_data cannot finish on this fixture for a reason
  -- that has nothing to do with 0129: it keeps `profiles`, and profiles.staff_id
  -- references staff with NO ACTION, so a school that has ever created a teacher
  -- login can never be reset. That is worth fixing and it is not this file's
  -- business, and a test that failed for it would be testing the wrong thing.
  --
  -- So: the flag makes the delete pass, its absence makes it fail, and every
  -- function that empties a school sets it. Those three facts are the contract.
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format($q$delete from public.assessments where id = %L$q$,
             (select v from pg_temp.ids where k='as_a')),
      'finalised mark'),
    '20 with the flag off, deleting an assessment with finalised marks is '
    || 'refused (the same check as 11, restated here so 21 has something to '
    || 'contrast with)');

  perform set_config('app.clearing_school', 'on', true);
  perform pg_temp.ok(
    pg_temp.rows_as_user(format(
      $q$delete from public.assessments where id = %L$q$,
      (select v from pg_temp.ids where k='as_a'))) = 1,
    '21 AND WITH IT ON, THE SAME DELETE GOES THROUGH. This is what lets a '
    || 'school be cleared at all: the four wipe functions delete assessments '
    || 'long before mark_entries and swallow only foreign_key_violation, so '
    || 'without this the trigger would abort the offboarding of any customer '
    || 'who had ever finalised a mark');
  perform set_config('app.clearing_school', 'off', true);

  -- And every function that empties a school announces it. Read off the
  -- catalogue, so a fifth one written later fails here.
  perform pg_temp.ok(
    not exists (
      select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.prosrc ~ 'delete from public\.%I'
         and p.prosrc !~ 'app\.clearing_school'),
    '22 and every function that empties a school table by table sets the flag '
    || 'first. Four of them do: the purge, the orphan purge, the trial reset '
    || 'and the signup rollback');
  perform pg_temp.ok(
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prosrc ~ 'delete from public\.%I') = 4,
    '22b there are four of them, which is the number this was checked against. '
    || 'A fifth is not a failure, but it is a thing to look at');
end $$;

-- =============================================================================
-- 5. A RECORD OF SERVICE
-- =============================================================================
do $$
declare
  v_owner uuid := (select v from pg_temp.ids where k='owner');
  v_sch uuid := (select v from pg_temp.ids where k='sch');
  v_staff uuid; v_fresh uuid;
begin
  perform set_config('test.uid', v_owner::text, false);
  select id into v_staff from public.staff where school_id = v_sch limit 1;
  insert into public.staff_attendance (school_id, staff_id, attendance_date,
                                       status, source, marked_by)
    values (v_sch, v_staff, current_date - 1, 'present', 'manual', v_owner);

  -- THROUGH THE MECHANISM THAT ALREADY EXISTS. This migration grew a BEFORE
  -- DELETE trigger for this and then removed it: fn_staff_delete_blockers
  -- already counts the days and refuses, in better words, and the trigger also
  -- broke the platform purge. Asserted here so the existing rule is not
  -- mistaken for a gap next time somebody goes looking.
  perform pg_temp.ok(
    jsonb_array_length(public.fn_staff_delete_blockers(v_staff)) > 0
    and public.fn_staff_delete_blockers(v_staff)::text like '%attendance%',
    '23 a staff member with attendance on record is refused by '
    || 'fn_staff_delete_blockers, which is where that decision already lived. '
    || 'A trigger for it would have been a second opinion on a settled '
    || 'question, and would have blocked the platform purge as well');
  perform pg_temp.ok(
    not (public.fn_delete_staff(v_staff)->>'deleted')::boolean,
    '24 and fn_delete_staff refuses, rather than reporting a delete it did not '
    || 'do');

  -- Somebody added by mistake this morning, with no history, still goes.
  insert into public.staff (full_name, designation, school_id)
    values ('Added By Mistake', 'Teacher', v_sch) returning id into v_fresh;
  perform pg_temp.ok(
    pg_temp.rows_as_user(format($q$delete from public.staff where id = %L$q$, v_fresh)) = 1,
    '25 and one added by mistake, with no attendance at all, still can be: the '
    || 'rule is about losing history, not about making staff permanent');
end $$;

rollback;
