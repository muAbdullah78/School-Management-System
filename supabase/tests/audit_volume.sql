-- =============================================================================
-- The audit log records what happened, and does not record the register twice.
--
-- Migration 0126 took 84% of a school's database away, and the whole of that
-- 84% was attendance and mark rows the audit log had copied from the register.
-- The danger in a change like that is obvious: skip one row too many and a
-- school cannot answer a parent, and nobody finds out until the parent asks.
--
-- So this file asserts BOTH halves, and the second half is the point:
--
--   1. Marking a register for the first time writes no audit row. The row
--      itself carries marked_by and created_at, and `after` would be the row.
--   2. CHANGING a mark writes one, with the `before` image, because that is
--      the thing the row cannot hold.
--   3. Finalising writes exactly ONE row for the section-day, not one per
--      pupil, and it names who did it and how many pupils it covered.
--   4. Reopening a finalised day is still recorded twice over: once as
--      ATTENDANCE_UNLOCK with the reason, and once per pupil, because the skip
--      is deliberately one-directional.
--   5. The same three rules for test marks, and locking a test writes one
--      ASSESSMENT_LOCK row.
--   6. Staff attendance: the scan writes nothing, the office overriding it
--      writes a full row.
--   7. MONEY IS UNTOUCHED. A payment writes its audit row exactly as before.
--   8. None of it crosses a school boundary.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/audit_volume.sql
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

-- How many audit rows exist for one entity right now. Every assertion below is
-- a difference across one call, so the count is taken before and after rather
-- than compared to an absolute figure that any earlier step could disturb.
create or replace function pg_temp.n(p_entity text) returns bigint language sql as $$
  select count(*) from public.audit_log where entity = p_entity;
$$;

create or replace function pg_temp.n(p_entity text, p_action text)
returns bigint language sql as $$
  select count(*) from public.audit_log where entity = p_entity and action = p_action;
$$;

-- --- Fixture -----------------------------------------------------------------
-- One school with one class of two children, one class test, one member of
-- staff, and a second school so isolation is checkable.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000a0d01';
  v_tc uuid := '00000000-0000-0000-0000-0000000a0d02';
  v_ob uuid := '00000000-0000-0000-0000-0000000a0d03';
  v_sess uuid; v_class uuid; v_subj uuid; v_asmt uuid; v_staff uuid;
  v_sess_b uuid; v_class_b uuid;
begin
  insert into public.schools (name) values ('Audit A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Audit B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'aa@audit.test'), (v_tc, 'at@audit.test'), (v_ob, 'ab@audit.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Audit Owner',   'owner',           v_a),
    (v_tc, 'Audit Teacher', 'subject_teacher', v_a),
    (v_ob, 'Audit Other',   'owner',           v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('Class 5', 5, v_a) returning id into v_class;
  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('Maths', v_class, 1, v_a) returning id into v_subj;
  insert into public.assessments (session_id, class_id, subject_id, title,
                                  assessment_date, max_marks, school_id)
    values (v_sess, v_class, v_subj, 'Monday test', current_date, 20, v_a)
    returning id into v_asmt;
  insert into public.staff (school_id, full_name, designation, status)
    values (v_a, 'Miss Ayesha', 'Teacher', 'active') returning id into v_staff;

  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Bilal Ahmed','father_name','Ahmed Sahib','father_cnic','35201-4000001-1',
    'session_id',v_sess,'class_id',v_class,'roll_no','1','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Hina Khan','father_name','Khan Sahib','father_cnic','35201-4000002-2',
    'session_id',v_sess,'class_id',v_class,'roll_no','2','links','[]'::jsonb));

  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B Five', 5, v_b) returning id into v_class_b;

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. THE REGISTER
-- =============================================================================
do $$
declare
  v_sess uuid; v_class uuid; v_e1 uuid; v_e2 uuid;
  v_before bigint; v_n integer; r record;
begin
  select id into v_sess  from public.academic_sessions where school_id =
    (select id from public.schools where name = 'Audit A');
  select id into v_class from public.classes where name = 'Class 5';
  select e.id into v_e1 from public.enrollments e join public.students s
    on s.id = e.student_id where s.full_name = 'Bilal Ahmed';
  select e.id into v_e2 from public.enrollments e join public.students s
    on s.id = e.student_id where s.full_name = 'Hina Khan';

  -- --- Marking, first time --------------------------------------------------
  v_before := pg_temp.n('attendance_daily');
  perform public.fn_mark_attendance(current_date, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'status', 'present'),
    jsonb_build_object('enrollment_id', v_e2, 'status', 'present')));
  perform pg_temp.ok(pg_temp.n('attendance_daily') = v_before,
    '1  marking a register for the first time writes no audit row');

  -- and the row itself holds everything the audit row would have.
  perform pg_temp.ok((select count(*) from public.attendance_daily ad
                       where ad.enrollment_id = v_e1
                         and ad.marked_by = auth.uid()
                         and ad.created_at > now() - interval '1 minute') = 1,
    '2  because the register row carries its own marked_by and created_at');

  -- --- Correcting -----------------------------------------------------------
  v_before := pg_temp.n('attendance_daily');
  perform public.fn_mark_attendance(current_date, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'status', 'absent')),
    'father brought the leave application');
  perform pg_temp.ok(pg_temp.n('attendance_daily') = v_before + 1,
    '3  CHANGING a mark writes one, because the row cannot hold what it was');

  select * into r from public.audit_log
   where entity = 'attendance_daily' and action = 'UPDATE'
   order by id desc limit 1;
  perform pg_temp.ok(r.before ->> 'status' = 'present'
                 and r.after  ->> 'status' = 'absent',
    '4  and the before image says present, which is the whole point of it');

  -- Re-saving the same status is not a change and must not manufacture a row.
  v_before := pg_temp.n('attendance_daily');
  perform public.fn_mark_attendance(current_date, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'status', 'absent')), 'saved again');
  perform pg_temp.ok(pg_temp.n('attendance_daily') = v_before,
    '5  re-saving the same status writes nothing: nothing changed');

  -- --- Finalising -----------------------------------------------------------
  v_before := pg_temp.n('attendance_daily');
  v_n := public.fn_finalize_attendance(v_sess, v_class, null, current_date);
  perform pg_temp.ok(v_n = 2, '6  finalising locked both children');
  perform pg_temp.ok(pg_temp.n('attendance_daily') = v_before + 1,
    '7  and wrote ONE audit row for the day, not one per child');

  select * into r from public.audit_log
   where action = 'ATTENDANCE_FINALIZE' order by id desc limit 1;
  perform pg_temp.ok(r.entity_id = current_date::text
                 and (r.after ->> 'rows')::int = 2
                 and (r.after ->> 'class_id')::uuid = v_class
                 and r.actor = auth.uid()
                 and r.actor_role = 'owner',
    '8  naming the day, the class, how many children, and who closed it');

  -- A finalise that locks nothing is not an event.
  v_before := pg_temp.n('attendance_daily');
  perform public.fn_finalize_attendance(v_sess, v_class, null, current_date);
  perform pg_temp.ok(pg_temp.n('attendance_daily') = v_before,
    '9  finalising an already finalised day records nothing');
end $$;

-- =============================================================================
-- 2. REOPENING IS RECORDED TWICE OVER, ON PURPOSE
--
-- The skip is one-directional: false to true is dropped, true to false is not.
-- So an unlock leaves both the ATTENDANCE_UNLOCK row that fn_unlock_attendance
-- writes AND a row per pupil. That is the cheap price of not needing to be
-- right about a second unlock path nobody has written yet.
-- =============================================================================
do $$
declare
  v_sess uuid; v_class uuid; v_before bigint; v_unlock bigint; v_n integer;
begin
  select id into v_sess  from public.academic_sessions where school_id =
    (select id from public.schools where name = 'Audit A');
  select id into v_class from public.classes where name = 'Class 5';

  v_before := pg_temp.n('attendance_daily', 'UPDATE');
  v_unlock := pg_temp.n('attendance_daily', 'ATTENDANCE_UNLOCK');
  v_n := public.fn_unlock_attendance(v_sess, v_class, null, current_date,
                                     'the father brought the letter');
  perform pg_temp.ok(v_n = 2, '10 reopening unlocked both children');
  perform pg_temp.ok(pg_temp.n('attendance_daily', 'ATTENDANCE_UNLOCK') = v_unlock + 1,
    '11 and wrote the ATTENDANCE_UNLOCK row with the reason');
  perform pg_temp.ok(pg_temp.n('attendance_daily', 'UPDATE') = v_before + 2,
    '12 and the per-pupil rows too: the skip does not run backwards');
end $$;

-- =============================================================================
-- 3. THE MARK SHEET
-- =============================================================================
do $$
declare
  v_asmt uuid; v_e1 uuid; v_e2 uuid; v_before bigint; r record;
begin
  select id into v_asmt from public.assessments where title = 'Monday test';
  select e.id into v_e1 from public.enrollments e join public.students s
    on s.id = e.student_id where s.full_name = 'Bilal Ahmed';
  select e.id into v_e2 from public.enrollments e join public.students s
    on s.id = e.student_id where s.full_name = 'Hina Khan';

  v_before := pg_temp.n('mark_entries');
  perform public.fn_enter_assessment_marks(v_asmt, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'marks', 15),
    jsonb_build_object('enrollment_id', v_e2, 'marks', 18)));
  perform pg_temp.ok(pg_temp.n('mark_entries') = v_before,
    '13 entering marks for the first time writes no audit row');

  v_before := pg_temp.n('mark_entries');
  perform public.fn_enter_assessment_marks(v_asmt, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'marks', 12)), 're-totalled');
  perform pg_temp.ok(pg_temp.n('mark_entries') = v_before + 1,
    '14 changing a mark writes one');
  select * into r from public.audit_log
   where entity = 'mark_entries' and action = 'UPDATE' order by id desc limit 1;
  perform pg_temp.ok((r.before ->> 'marks')::numeric = 15
                 and (r.after  ->> 'marks')::numeric = 12,
    '15 with the mark it was, which is what a disputed result needs');

  v_before := pg_temp.n('mark_entries');
  perform public.fn_lock_assessment(v_asmt);
  perform pg_temp.ok(pg_temp.n('mark_entries') = v_before,
    '16 locking the test writes no per-mark rows');
  select * into r from public.audit_log
   where action = 'ASSESSMENT_LOCK' order by id desc limit 1;
  perform pg_temp.ok(r.entity = 'assessments' and r.entity_id = v_asmt::text
                 and (r.after ->> 'marks')::int = 2 and r.actor = auth.uid(),
    '17 it writes ONE ASSESSMENT_LOCK row naming the test and the marks in it');

  -- assessments carries no audit trigger of its own, so without that row a
  -- locked test would have left no trace at all. Assert the gap is closed.
  perform pg_temp.ok(not exists (
      select 1 from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_proc p on p.oid = t.tgfoid
       where c.relname = 'assessments' and p.proname = 'audit_trigger'
         and not t.tgisinternal),
    '18 and it has to, because assessments has no audit trigger of its own');
end $$;

-- =============================================================================
-- 4. STAFF ATTENDANCE
-- =============================================================================
do $$
declare v_staff uuid; v_before bigint; r record;
begin
  select id into v_staff from public.staff where full_name = 'Miss Ayesha';

  v_before := pg_temp.n('staff_attendance');
  perform public.fn_set_staff_attendance(v_staff, current_date, 'present');
  perform pg_temp.ok(pg_temp.n('staff_attendance') = v_before,
    '19 recording a member of staff present writes no audit row');

  v_before := pg_temp.n('staff_attendance');
  perform public.fn_set_staff_attendance(v_staff, current_date, 'absent',
                                         'left at nine, I saw her go');
  perform pg_temp.ok(pg_temp.n('staff_attendance') = v_before + 1,
    '20 the office overriding it writes a full row');
  select * into r from public.audit_log
   where entity = 'staff_attendance' order by id desc limit 1;
  perform pg_temp.ok(r.before ->> 'status' = 'present'
                 and r.after  ->> 'status' = 'absent',
    '21 with what the day said before somebody changed it');
end $$;

-- =============================================================================
-- 5. MONEY IS UNTOUCHED
--
-- The three tables in the rule are named one at a time in the trigger, and this
-- asserts the negative: nothing about a payment changed. It is the assertion
-- that would fail if somebody later widened the list "while they were in there".
-- =============================================================================
do $$
declare v_student uuid; v_before bigint; r record;
begin
  select id into v_student from public.students where full_name = 'Bilal Ahmed';

  v_before := pg_temp.n('payments');
  perform public.fn_record_payment(v_student, 500, 'cash', 'part payment');
  perform pg_temp.ok(pg_temp.n('payments') = v_before + 1,
    '22 a payment still writes its audit row, in full');
  select * into r from public.audit_log
   where entity = 'payments' order by id desc limit 1;
  perform pg_temp.ok(r.action = 'INSERT' and (r.after ->> 'amount')::numeric = 500,
    '23 including the amount, on the INSERT, which is the case the register skips');
end $$;

-- =============================================================================
-- 6. THE TRIGGER NAMES THREE TABLES AND ONLY THREE
--
-- Read off the installed function rather than from the migration file, because
-- the migration edits the function programmatically and the thing that ships is
-- whatever came out of that edit.
-- =============================================================================
do $$
declare v_src text := pg_get_functiondef('public.audit_trigger()'::regprocedure);
begin
  perform pg_temp.ok(
    position('''attendance_daily'', ''mark_entries'', ''staff_attendance''' in v_src) > 0,
    '24 the skip list is exactly attendance_daily, mark_entries, staff_attendance');
  perform pg_temp.ok(position('payments' in v_src) = 0
                 and position('discounts' in v_src) = 0
                 and position('adjustments' in v_src) = 0,
    '25 and names no money table at all');
  perform pg_temp.ok(
    position('not exists (select 1 from public.schools s where s.id = v_school)' in v_src) > 0,
    '26 and still carries 0092''s missing-school guard below it');
end $$;

-- =============================================================================
-- 7. NOTHING CROSSES A SCHOOL BOUNDARY
-- =============================================================================
do $$
declare
  v_sess_b uuid; v_class_b uuid; v_class_a uuid; v_ok boolean := false;
begin
  select a.id into v_sess_b from public.academic_sessions a
    join public.schools s on s.id = a.school_id where s.name = 'Audit B';
  select id into v_class_b from public.classes where name = 'B Five';
  select id into v_class_a from public.classes where name = 'Class 5';

  -- School A's owner cannot finalise, and so cannot audit, school B's register.
  begin
    perform public.fn_finalize_attendance(v_sess_b, v_class_b, null, current_date);
  exception when others then v_ok := true;
  end;
  perform pg_temp.ok(v_ok, '27 school A cannot finalise school B''s register');

  -- Not "school B has no audit rows": every new school gets eight, because a
  -- trigger seeds its expense categories and expense_categories is audited.
  -- Asserting the broader thing looks stricter and fails for a reason that has
  -- nothing to do with this file, which is worse than asserting less.
  perform pg_temp.ok(not exists (
      select 1 from public.audit_log a
        join public.schools s on s.id = a.school_id
       where s.name = 'Audit B'
         and a.entity in ('attendance_daily', 'mark_entries', 'staff_attendance',
                          'assessments', 'payments')),
    '28 and school B has no register, mark, staff or money rows from any of this');

  -- And every row written above belongs to school A, with a school_id on it:
  -- audit_log.school_id is NOT NULL, and a row with the wrong one is invisible
  -- to the school that needs it and visible to the school that must not see it.
  perform pg_temp.ok(not exists (
      select 1 from public.audit_log a
       where a.entity in ('attendance_daily', 'mark_entries', 'staff_attendance',
                          'assessments', 'payments')
         and a.school_id is distinct from
             (select id from public.schools where name = 'Audit A')),
    '29 every row this file produced carries school A''s id');
end $$;

rollback;
