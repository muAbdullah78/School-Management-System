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

rollback;
