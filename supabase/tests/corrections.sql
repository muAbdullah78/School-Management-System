-- =============================================================================
-- Mark and attendance corrections: can a school SEE that a mark was changed?
--
-- mark_entries and attendance_daily have carried `corrected_from` and
-- `correction_reason` since early on. The entry functions faithfully wrote
-- `corrected_from`; nothing has ever read either column, and
-- `correction_reason` was never written at all. So the system recorded that a
-- teacher changed a mark from 45 to 40 the night before results, and no
-- principal could see it, no parent disputing that mark could be answered, and
-- nobody was ever asked why.
--
-- The rules this file defends:
--
--  1. A CHANGED mark appears in the corrections report, with what it WAS.
--  2. An UNCHANGED mark does not — a report full of rows where nothing happened
--     is a report nobody reads.
--  3. The reason lands only on the rows that actually changed.
--  4. Entering a mark for the FIRST time is not a correction.
--  5. A locked mark cannot be changed at all, so it cannot appear.
--  6. Only owner and principal may read it. The person most likely to want this
--     hidden is the person who changed the mark, so a subject teacher — who can
--     enter marks — must not be able to audit them.
--  7. Nothing crosses a school boundary.
--  8. The old two-argument callers still work, because the app is one.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/corrections.sql
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

-- --- Fixture -----------------------------------------------------------------
-- One school, one class, two children, one exam paper out of 100, and one class
-- test out of 20. Plus a second school so isolation can be checked.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000cc01';
  v_pr uuid := '00000000-0000-0000-0000-00000000cc02';
  v_tc uuid := '00000000-0000-0000-0000-00000000cc03';
  v_ob uuid := '00000000-0000-0000-0000-00000000cc04';
  v_sess uuid; v_class uuid; v_subj uuid; v_term uuid; v_es uuid; v_asmt uuid;
  v_sess_b uuid; v_class_b uuid;
begin
  insert into public.schools (name) values ('Corr A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Corr B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa,'ca@corr.test'), (v_pr,'cp@corr.test'),
    (v_tc,'ct@corr.test'), (v_ob,'cb@corr.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Corr Owner',     'owner',          v_a),
    (v_pr, 'Corr Principal', 'principal',      v_a),
    (v_tc, 'Corr Teacher',   'subject_teacher', v_a),
    (v_ob, 'Corr Other',     'owner',          v_b)
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
    values ('Class 9', 9, v_a) returning id into v_class;
  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('Physics', v_class, 1, v_a) returning id into v_subj;
  insert into public.exam_terms (session_id, name, term_type, school_id)
    values (v_sess, 'First Term', 'first', v_a) returning id into v_term;
  insert into public.exam_subjects (exam_term_id, class_id, subject_id, max_marks, school_id)
    values (v_term, v_class, v_subj, 100, v_a) returning id into v_es;
  insert into public.assessments (session_id, class_id, subject_id, title,
                                  assessment_date, max_marks, school_id)
    values (v_sess, v_class, v_subj, 'Weekly test', current_date, 20, v_a)
    returning id into v_asmt;

  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Ali Raza','father_name','Raza Sahib','father_cnic','35201-3000001-1',
    'session_id',v_sess,'class_id',v_class,'roll_no','1','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Sana Iqbal','father_name','Iqbal Sahib','father_cnic','35201-3000002-2',
    'session_id',v_sess,'class_id',v_class,'roll_no','2','links','[]'::jsonb));

  -- School B, so isolation is checkable.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B Nine', 9, v_b) returning id into v_class_b;

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. Entering marks for the first time is NOT a correction
-- =============================================================================
do $$
declare
  v_es uuid; v_e1 uuid; v_e2 uuid; r jsonb;
begin
  select id into v_es from public.exam_subjects limit 1;
  select e.id into v_e1 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Ali Raza';
  select e.id into v_e2 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Sana Iqbal';

  -- Two arguments, exactly as the app calls it today. If dropping and
  -- recreating the signature broke this, everything below is moot.
  r := public.fn_enter_marks(v_es, jsonb_build_array(
        jsonb_build_object('enrollment_id', v_e1, 'marks', 45),
        jsonb_build_object('enrollment_id', v_e2, 'marks', 70)));
  perform pg_temp.ok((r->>'marked')::int = 2,
    '1  the two-argument call still works — the app is one of those callers');

  perform pg_temp.ok((select count(*) from public.fn_mark_corrections()) = 0,
    '2  entering a mark for the first time is not a correction');
end $$;

-- =============================================================================
-- 2. THE ONE THAT MATTERS — a changed mark becomes visible
-- =============================================================================
do $$
declare
  v_es uuid; v_e1 uuid; r record;
begin
  select id into v_es from public.exam_subjects limit 1;
  select e.id into v_e1 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Ali Raza';

  -- 45 becomes 40 the night before results, with a reason this time.
  perform public.fn_enter_marks(v_es, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'marks', 40)),
    're-totalled question 7');

  select * into r from public.fn_mark_corrections();
  perform pg_temp.ok(r.student_name = 'Ali Raza' and r.was = 45 and r.now_is = 40,
    '3  the correction is visible, WITH what the mark was before');
  perform pg_temp.ok(r.reason = 're-totalled question 7',
    '4  and why — the column that was never written at all');
  perform pg_temp.ok(r.changed_by = 'Corr Owner',
    '5  and who changed it');
  perform pg_temp.ok(r.kind = 'Exam' and r.subject_name = 'Physics'
                 and r.paper = 'First Term' and r.max_marks = 100,
    '6  with enough context to find the paper it belongs to');
  perform pg_temp.ok((select count(*) from public.fn_mark_corrections()) = 1,
    '7  Sana''s untouched 70 is not reported as a correction');
end $$;

-- Re-saving the SAME mark is not a change, and must not manufacture a row or
-- overwrite the reason already recorded.
do $$
declare v_es uuid; v_e1 uuid; r record;
begin
  select id into v_es from public.exam_subjects limit 1;
  select e.id into v_e1 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Ali Raza';

  perform public.fn_enter_marks(v_es, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'marks', 40)), 'saved again by mistake');

  select * into r from public.fn_mark_corrections();
  perform pg_temp.ok((select count(*) from public.fn_mark_corrections()) = 1,
    '8  re-saving an unchanged mark does not add a correction');
  perform pg_temp.ok(r.reason = 're-totalled question 7',
    '9  ...and does not overwrite the reason for the real change');
end $$;

-- A second, later change shows the most recent pair, not the original.
do $$
declare v_es uuid; v_e1 uuid; r record;
begin
  select id into v_es from public.exam_subjects limit 1;
  select e.id into v_e1 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Ali Raza';

  perform public.fn_enter_marks(v_es, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'marks', 55)), 'paper remarked on appeal');

  select * into r from public.fn_mark_corrections();
  perform pg_temp.ok(r.was = 40 and r.now_is = 55 and r.reason = 'paper remarked on appeal',
    '10 a further change reports the latest pair — the row holds one step, not a history');
end $$;

-- A change with NO reason still appears. Hiding it because nobody typed a
-- reason would be exactly backwards.
do $$
declare v_es uuid; v_e2 uuid; r record;
begin
  select id into v_es from public.exam_subjects limit 1;
  select e.id into v_e2 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Sana Iqbal';

  perform public.fn_enter_marks(v_es, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e2, 'marks', 72)));

  select * into r from public.fn_mark_corrections() where student_name = 'Sana Iqbal';
  perform pg_temp.ok(r.was = 70 and r.now_is = 72 and r.reason is null,
    '11 a change with no reason given is still reported, with the reason blank');
end $$;

-- =============================================================================
-- 3. Class tests go through the same report
-- =============================================================================
do $$
declare v_a uuid; v_e1 uuid; r record;
begin
  select id into v_a from public.assessments limit 1;
  select e.id into v_e1 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Ali Raza';

  perform public.fn_enter_assessment_marks(v_a, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'marks', 15)));
  perform public.fn_enter_assessment_marks(v_a, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'marks', 18)), 'addition error');

  select * into r from public.fn_mark_corrections() where kind = 'Class test';
  perform pg_temp.ok(r.was = 15 and r.now_is = 18 and r.reason = 'addition error'
                 and r.paper = 'Weekly test' and r.max_marks = 20,
    '12 a class-test mark change is reported the same way, labelled as one');
end $$;

-- =============================================================================
-- 4. A locked mark cannot be changed, so it cannot appear
-- =============================================================================
do $$
declare v_es uuid; v_e2 uuid; v_before int; r jsonb;
begin
  select id into v_es from public.exam_subjects limit 1;
  select e.id into v_e2 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Sana Iqbal';

  update public.mark_entries set is_locked = true
   where exam_subject_id = v_es and enrollment_id = v_e2;

  select count(*) into v_before from public.fn_mark_corrections();
  r := public.fn_enter_marks(v_es, jsonb_build_array(
        jsonb_build_object('enrollment_id', v_e2, 'marks', 99)));

  perform pg_temp.ok((r->>'marked')::int = 0 and (r->>'skipped')::int = 1,
    '13 a locked mark is skipped, and the caller is told how many');
  perform pg_temp.ok(
    (select marks from public.mark_entries
      where exam_subject_id = v_es and enrollment_id = v_e2) = 72,
    '14 ...and the mark itself is untouched');
  perform pg_temp.ok((select count(*) from public.fn_mark_corrections()) = v_before,
    '15 ...so no phantom correction is recorded for the attempt');

  update public.mark_entries set is_locked = false
   where exam_subject_id = v_es and enrollment_id = v_e2;
end $$;

-- =============================================================================
-- 5. Attendance, same principle
-- =============================================================================
do $$
declare v_e1 uuid; r record; v_n int;
begin
  select e.id into v_e1 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Ali Raza';

  perform public.fn_mark_attendance(current_date, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'status', 'absent')));
  perform pg_temp.ok((select count(*) from public.fn_attendance_corrections()) = 0,
    '16 marking attendance for the first time is not a correction');

  perform public.fn_mark_attendance(current_date, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'status', 'present')),
    'father produced a medical certificate');

  select * into r from public.fn_attendance_corrections();
  perform pg_temp.ok(r.was = 'absent' and r.now_is = 'present'
                 and r.reason = 'father produced a medical certificate'
                 and r.attendance_date = current_date,
    '17 an absence changed to present is visible, with the date and the reason');
  perform pg_temp.ok(r.changed_by = 'Corr Owner' and r.student_name = 'Ali Raza',
    '18 and who changed it');
end $$;

-- =============================================================================
-- 6. Who may audit
-- =============================================================================
do $$
begin
  perform pg_temp.be('Corr Principal');
  perform public.fn_mark_corrections();
  perform public.fn_attendance_corrections();
  raise notice 'PASS  19 a principal may review corrections';

  -- The teacher can ENTER marks. That is exactly why they must not be able to
  -- audit them.
  perform pg_temp.be('Corr Teacher');
  begin
    perform public.fn_mark_corrections();
    raise exception 'FAIL  20 a subject teacher read the mark corrections report';
  exception when insufficient_privilege then
    raise notice 'PASS  20 a subject teacher — who can enter marks — cannot audit them';
  end;
  begin
    perform public.fn_attendance_corrections();
    raise exception 'FAIL  21 a subject teacher read the attendance corrections report';
  exception when insufficient_privilege then
    raise notice 'PASS  21 nor the attendance corrections';
  end;

  perform pg_temp.be('Corr Owner');
end $$;

-- A deactivated principal is not a principal.
do $$
declare v_p uuid;
begin
  select id into v_p from public.profiles where full_name = 'Corr Principal';
  update public.profiles set active = false where id = v_p;
  perform set_config('test.uid', v_p::text, false);
  begin
    perform public.fn_mark_corrections();
    raise exception 'FAIL  22 a deactivated principal read the corrections report';
  exception when insufficient_privilege then
    raise notice 'PASS  22 a deactivated principal is refused';
  end;
  update public.profiles set active = true where id = v_p;
  perform pg_temp.be('Corr Owner');
end $$;

-- =============================================================================
-- 7. Tenant isolation
-- =============================================================================
do $$
declare v_n_a int;
begin
  select count(*) into v_n_a from public.fn_mark_corrections();
  perform pg_temp.ok(v_n_a > 0, '23 school A has corrections to show');

  perform pg_temp.be('Corr Other');
  perform pg_temp.ok((select count(*) from public.fn_mark_corrections()) = 0,
    '24 school B sees none of school A''s mark corrections');
  perform pg_temp.ok((select count(*) from public.fn_attendance_corrections()) = 0,
    '25 nor its attendance corrections');
  perform pg_temp.be('Corr Owner');
end $$;

-- =============================================================================
-- 8. The date filter
-- =============================================================================
do $$
begin
  perform pg_temp.ok(
    (select count(*) from public.fn_mark_corrections(current_date, current_date)) > 0,
    '26 today''s corrections are found by today''s date range');
  perform pg_temp.ok(
    (select count(*) from public.fn_mark_corrections(
       current_date - 30, current_date - 20)) = 0,
    '27 and a range that excludes them returns nothing');
end $$;

-- =============================================================================
-- 9. A FINALISED REGISTER CAN BE REOPENED (0121)
--
-- The defect this proves is fixed: a class teacher marked a child wrongly,
-- pressed Finalize, and NOTHING at any privilege level could clear
-- attendance_daily.is_locked. fn_mark_attendance's upsert carries
-- `where not ad.is_locked`, so the owner's correction reported
-- {"marked": 0, "skipped": 1} and the register did not change. The attendance
-- percentage on the RESULT CARD is computed from that table, so the wrong
-- figure went home every term afterwards.
--
-- It belongs in THIS file and not in a new one, because the whole point of the
-- fix is the corrections report: reopening the day is only useful if the
-- correction that follows is visible and attributed, which is rules 1 to 8
-- above applied to a day that had been closed.
--
-- A DIFFERENT DATE from section 5 on purpose. Reusing today would leave two
-- corrections in the report and make assertion 17's single-row select a
-- coin toss depending on which ran last.
-- =============================================================================
do $$
declare
  v_a uuid; v_sess uuid; v_class uuid; v_class_b uuid; v_staff uuid;
  v_ct uuid := '00000000-0000-0000-0000-00000000cc05';
  v_e1 uuid; v_e2 uuid; v_n int; r record; v_status text; v_aud record;
  v_day date := current_date - 1;
begin
  perform pg_temp.be('Corr Owner');
  select id into v_a from public.schools where name = 'Corr A';
  select id into v_class_b from public.classes where school_id =
    (select id from public.schools where name = 'Corr B') limit 1;
  select id into v_sess from public.academic_sessions where school_id = v_a limit 1;
  select id into v_class from public.classes where school_id = v_a limit 1;
  select e.id into v_e1 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Ali Raza';
  select e.id into v_e2 from public.enrollments e
    join public.students s on s.id = e.student_id where s.full_name = 'Sana Iqbal';

  -- A CLASS TEACHER, assigned to that class, because they are the one who can
  -- create this state. Without the assignment fn_may_manage_class refuses the
  -- finalize and the test would prove nothing about the interesting case.
  insert into public.staff (school_id, full_name, designation, employee_no, status, joined_on)
    values (v_a, 'Corr Teacher Staff', 'Class Teacher', 'CT-1', 'active', current_date - 100)
    returning id into v_staff;
  insert into auth.users (id, email) values (v_ct, 'cct@corr.test')
    on conflict (id) do nothing;
  alter table public.profiles disable trigger user;
  insert into public.profiles (id, full_name, role, school_id, staff_id)
    values (v_ct, 'Corr Class Teacher', 'class_teacher', v_a, v_staff)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role = excluded.role, staff_id = excluded.staff_id,
                                   active = true;
  alter table public.profiles enable trigger user;
  insert into public.teacher_assignments (school_id, staff_id, session_id, class_id, section_id)
    values (v_a, v_staff, v_sess, v_class, null);

  -- --- The state the school gets into -------------------------------------
  perform pg_temp.be('Corr Class Teacher');
  perform public.fn_mark_attendance(v_day, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_e1, 'status', 'absent'),
    jsonb_build_object('enrollment_id', v_e2, 'status', 'present')));
  v_n := public.fn_finalize_attendance(v_sess, v_class, null, v_day);
  perform pg_temp.ok(v_n = 2, '28 a class teacher can finalise their own class');

  -- THE DEFECT, asserted rather than described. If a later change ever makes
  -- fn_mark_attendance write through a lock, this fails and the lock has
  -- stopped meaning anything.
  perform pg_temp.ok(
    (public.fn_mark_attendance(v_day, jsonb_build_array(
       jsonb_build_object('enrollment_id', v_e1, 'status', 'leave')),
       'father produced a leave application')->>'skipped')::int = 1,
    '29 and a correction to that day is then skipped, not applied');
  select status::text into v_status from public.attendance_daily
   where enrollment_id = v_e1 and attendance_date = v_day;
  perform pg_temp.ok(v_status = 'absent', '30 the wrong mark is still on the register');

  -- --- Who may reopen it ---------------------------------------------------
  -- Not the person who locked it. If the teacher could reopen their own day,
  -- finalising would mean nothing at all.
  begin
    perform public.fn_unlock_attendance(v_sess, v_class, null, v_day,
                                        'I want to change my own mark');
    raise exception 'FAIL  31 a class teacher reopened the day they finalised';
  exception when insufficient_privilege then
    raise notice 'PASS  31 a class teacher cannot reopen the day they finalised';
  end;

  perform pg_temp.be('Corr Owner');
  -- A reason, and a real one. Every other correction path in this schema
  -- demands one and this is the one somebody will be asked about later.
  begin
    perform public.fn_unlock_attendance(v_sess, v_class, null, v_day, 'oops');
    raise exception 'FAIL  32 a four-character reason was accepted';
  exception when others then
    if sqlstate = '42501' then raise; end if;
    raise notice 'PASS  32 reopening without a real reason is refused';
  end;

  -- Another school's class, as an owner who is genuinely an owner. The scope
  -- check has to be on the ids, not on the role.
  begin
    perform public.fn_unlock_attendance(v_sess, v_class_b, null, v_day,
                                        'a class in somebody else''s school');
    raise exception 'FAIL  33 an owner reopened another school''s register';
  exception when insufficient_privilege then
    raise notice 'PASS  33 nor another school''s register';
  end;

  -- --- The fix ------------------------------------------------------------
  v_n := public.fn_unlock_attendance(v_sess, v_class, null, v_day,
           'father produced the leave application the next morning');
  perform pg_temp.ok(v_n = 2, '34 the owner reopens the day, and is told how many rows');

  perform pg_temp.ok(
    (public.fn_mark_attendance(v_day, jsonb_build_array(
       jsonb_build_object('enrollment_id', v_e1, 'status', 'leave')),
       'father produced a leave application')->>'marked')::int = 1,
    '35 and the correction now takes');
  select status::text into v_status from public.attendance_daily
   where enrollment_id = v_e1 and attendance_date = v_day;
  perform pg_temp.ok(v_status = 'leave', '36 the register is right');

  -- The point of the whole exercise: it is visible, with what it was and why.
  -- THE DATE RANGE ON THIS FUNCTION IS `updated_at`, NOT `attendance_date`:
  -- it answers "what was corrected this week", not "what corrections touch
  -- last week's register". Both are reasonable and the report returns
  -- attendance_date either way, so the filter here is on the row, and the
  -- range is today because today is when the correction was made. Getting this
  -- wrong is how the first version of this assertion failed.
  select * into r from public.fn_attendance_corrections(current_date, current_date) c
   where c.attendance_date = v_day;
  perform pg_temp.ok(r.was = 'absent' and r.now_is = 'leave'
                 and r.reason = 'father produced a leave application'
                 and r.student_name = 'Ali Raza',
    '37 the correction to a reopened day is in the corrections report');

  -- And the reopening itself is on the record, which is what replaces the
  -- date window this function deliberately does not have.
  select * into v_aud from public.audit_log
   where school_id = v_a and action = 'ATTENDANCE_UNLOCK'
   order by id desc limit 1;
  perform pg_temp.ok(v_aud.reason like 'father produced the leave application%'
                 and v_aud.actor_role = 'owner'
                 and (v_aud.before->>'locked')::boolean
                 and not (v_aud.after->>'locked')::boolean,
    '38 and the reopening is audited, with its reason and who did it');

  -- --- Closing it again ---------------------------------------------------
  v_n := public.fn_finalize_attendance(v_sess, v_class, null, v_day);
  perform pg_temp.ok(v_n = 2, '39 the day can be closed again afterwards');

  -- A principal may reopen too: the pair is "owner or principal", not "owner".
  perform pg_temp.be('Corr Principal');
  perform pg_temp.ok(
    public.fn_unlock_attendance(v_sess, v_class, null, v_day,
      'the principal checked the leave register herself') = 2,
    '40 a principal may reopen it as well');

  -- And a day that is not locked is not silently "reopened". A function that
  -- returned 0 here would report success for a date the school typed wrongly.
  perform pg_temp.be('Corr Owner');
  begin
    perform public.fn_unlock_attendance(v_sess, v_class, null, v_day,
                                        'reopening it a second time');
    raise exception 'FAIL  41 reopening an already-open day reported success';
  exception when others then
    if sqlstate = '42501' then raise; end if;
    raise notice 'PASS  41 a day that is not finalised cannot be reopened';
  end;
end $$;

rollback;
