-- =============================================================================
-- A parent sees the weekly test (0150).
--
-- The defect, as the school reported it: a class teacher set a weekly test for
-- Class 4, marked it and locked it; the office saw the marks and the parent's
-- Results tab said "No results published yet". The portal had no read for a
-- class test at all.
--
-- So this walks the teacher's real path (the row the screen inserts, the marks
-- function, the lock function) as the teacher's login, and then reads it as
-- the parent's login, and asserts:
--
--   * nothing shows while the teacher is still entering marks, except that a
--     test was sat and its marks are on the way
--   * the moment it is locked, the child's own mark is there
--   * the class average and highest appear only when five or more pupils have
--     a mark, because in a smaller class they give away another child's mark
--   * a test in another section, a test the child joined too late for, and a
--     long-forgotten unmarked test are not shown
--   * another family's child is refused, and the refusal cannot be told apart
--     from an invented id
--   * fn_portal_me returns one row per child, with the class teacher, the roll
--     number and the birthday, even when an old enrollment was left active
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/a_parent_sees_the_weekly_test.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create or replace function pg_temp.ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if coalesce(p_cond, false) then raise notice 'PASS  %', p_label;
  else raise exception 'FAIL  %', p_label; end if;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.kid(p text) returns uuid language sql stable as
  $$ select id from public.students where full_name = p $$;

create or replace function pg_temp.enr(p text) returns uuid language sql stable as $$
  select e.id from public.enrollments e
    join public.academic_sessions s on s.id = e.session_id and s.is_current
   where e.student_id = (select id from public.students where full_name = p)
$$;

create or replace function pg_temp.k_today() returns date language sql stable as
  $$ select (now() at time zone 'Asia/Karachi')::date $$;

-- The parent's read, as the parent's login under the authenticated role, so the
-- grant is exercised as well as the function.
create or replace function pg_temp.tests_as(p_parent text, p_kid text) returns jsonb
language plpgsql as $$
declare j jsonb; v_kid uuid := pg_temp.kid(p_kid);
begin
  -- The id is looked up first: a parent cannot read public.students, which is
  -- the point of the portal, so looking it up under their role finds nothing.
  perform pg_temp.be(p_parent);
  set local role authenticated;
  j := public.fn_portal_child_tests(v_kid);
  reset role;
  return j;
end;
$$;

create or replace function pg_temp.test_named(j jsonb, p_title text) returns jsonb
language sql immutable as $$
  select t from jsonb_array_elements(j->'tests') t where t->>'title' = p_title limit 1
$$;

create or replace function pg_temp.next_named(j jsonb, p_title text) returns jsonb
language sql immutable as $$
  select t from jsonb_array_elements(j->'upcoming') t where t->>'title' = p_title limit 1
$$;

-- --- Fixture -----------------------------------------------------------------
-- Class 4 A: Hamna (family A), Zoya (family B), and four more pupils. Class 4 B:
-- one pupil. A class teacher for 4 A. Hamna also has last year's Class 3
-- enrollment, left active, which is the case that used to list her twice.
do $seed$
declare
  v_school uuid;
  v_owner uuid := '00000000-0000-0000-0000-0000000fb001';
  v_par_a uuid := '00000000-0000-0000-0000-0000000fb002';
  v_par_b uuid := '00000000-0000-0000-0000-0000000fb003';
  v_tch   uuid := '00000000-0000-0000-0000-0000000fb004';
  v_sess uuid; v_old uuid; v_c4 uuid; v_c3 uuid; v_4a uuid; v_4b uuid; v_stf uuid;
  v_fam_a uuid; v_fam_b uuid; v_fam_c uuid; v_kid uuid; v_name text;
begin
  insert into public.schools (name) values ('Weekly Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'own@weekly.test'), (v_par_a, 'a@weekly.test'),
    (v_par_b, 'b@weekly.test'), (v_tch, 't@weekly.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner, 'Weekly Owner',   'owner',         v_school),
    (v_par_a, 'Humna Mahnoor',  'parent',        v_school),
    (v_par_b, 'Zoya Parent',    'parent',        v_school),
    (v_tch,   'Sidra Teacher',  'class_teacher', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  insert into public.school_settings (school_id, name) values (v_school, 'Weekly Test School')
    on conflict (school_id) do update set name = excluded.name;

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', false, v_school) returning id into v_old;
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2026-2027', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 3', 3, v_school) returning id into v_c3;
  insert into public.classes (name, level_order, school_id)
    values ('Class 4', 4, v_school) returning id into v_c4;
  insert into public.sections (class_id, name, school_id) values (v_c4, 'A', v_school) returning id into v_4a;
  insert into public.sections (class_id, name, school_id) values (v_c4, 'B', v_school) returning id into v_4b;
  insert into public.subjects (name, class_id, school_id) values ('Maths', v_c4, v_school);
  insert into public.subjects (name, class_id, school_id) values ('English', v_c4, v_school);

  insert into public.staff (full_name, designation, school_id)
    values ('Sidra Teacher', 'Teacher', v_school) returning id into v_stf;
  alter table public.profiles disable trigger user;
  update public.profiles set staff_id = v_stf where id = v_tch;
  alter table public.profiles enable trigger user;
  perform public.fn_set_class_teacher(v_stf, v_sess, v_c4, v_4a);

  insert into public.families (school_id, head_name) values (v_school, 'Masood') returning id into v_fam_a;
  insert into public.families (school_id, head_name) values (v_school, 'Zoya Parent') returning id into v_fam_b;
  insert into public.families (school_id, head_name) values (v_school, 'Others') returning id into v_fam_c;

  -- Hamna's ninth birthday is today, in Karachi.
  insert into public.students (full_name, status, school_id, family_id, dob)
    values ('Hamna Masood', 'active', v_school, v_fam_a, pg_temp.k_today() - interval '9 years')
    returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, section_id, roll_no, status, school_id)
    values (v_kid, v_old, v_c3, null, '7', 'active', v_school);
  insert into public.enrollments (student_id, session_id, class_id, section_id, roll_no, status, school_id)
    values (v_kid, v_sess, v_c4, v_4a, '12', 'active', v_school);

  insert into public.students (full_name, status, school_id, family_id)
    values ('Zoya Khan', 'active', v_school, v_fam_b) returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, section_id, roll_no, status, school_id)
    values (v_kid, v_sess, v_c4, v_4a, '13', 'active', v_school);

  foreach v_name in array array['Pupil One', 'Pupil Two', 'Pupil Three', 'Pupil Four'] loop
    insert into public.students (full_name, status, school_id, family_id)
      values (v_name, 'active', v_school, v_fam_c) returning id into v_kid;
    insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
      values (v_kid, v_sess, v_c4, v_4a, 'active', v_school);
  end loop;

  insert into public.students (full_name, status, school_id, family_id)
    values ('Section B Pupil', 'active', v_school, v_fam_c) returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_kid, v_sess, v_c4, v_4b, 'active', v_school);

  perform public.fn_link_parent(v_par_a, v_fam_a);
  perform public.fn_link_parent(v_par_b, v_fam_b);
  raise notice 'fixture ok';
end $seed$;

create or replace function pg_temp.sess() returns uuid language sql stable as
  $$ select id from public.academic_sessions where name = '2026-2027'
       and school_id = (select id from public.schools where name = 'Weekly Test School') $$;
create or replace function pg_temp.c4() returns uuid language sql stable as
  $$ select id from public.classes where name = 'Class 4'
       and school_id = (select id from public.schools where name = 'Weekly Test School') $$;
create or replace function pg_temp.sec(p text) returns uuid language sql stable as
  $$ select id from public.sections where class_id = pg_temp.c4() and name = p $$;
create or replace function pg_temp.subj(p text) returns uuid language sql stable as
  $$ select id from public.subjects where class_id = pg_temp.c4() and name = p $$;
create or replace function pg_temp.school() returns uuid language sql stable as
  $$ select id from public.schools where name = 'Weekly Test School' $$;

-- =============================================================================
-- 1-6. THE TEACHER'S PATH, AND WHAT THE PARENT SEES AT EACH STEP
-- =============================================================================
do $t$
declare v_t uuid; j jsonb; t jsonb;
begin
  j := pg_temp.tests_as('Humna Mahnoor', 'Hamna Masood');
  perform pg_temp.ok(jsonb_array_length(j->'tests') = 0 and jsonb_array_length(j->'upcoming') = 0,
    '1. before any test, the parent sees no tests and nothing coming up');

  -- The row the Tests screen inserts, as the teacher.
  perform pg_temp.be('Sidra Teacher');
  insert into public.assessments (session_id, class_id, section_id, subject_id, title,
                                  assessment_date, max_marks, school_id)
    values (pg_temp.sess(), pg_temp.c4(), pg_temp.sec('A'), pg_temp.subj('Maths'),
            'Weekly test 1', pg_temp.k_today() - 2, 20, pg_temp.school())
    returning id into v_t;

  perform public.fn_enter_assessment_marks(v_t, jsonb_build_array(
    jsonb_build_object('enrollment_id', pg_temp.enr('Hamna Masood'), 'marks', 18),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil One'), 'marks', 10),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil Two'), 'marks', 12),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil Three'), 'marks', 14),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil Four'), 'marks', 16),
    jsonb_build_object('enrollment_id', pg_temp.enr('Zoya Khan'), 'is_absent', true)));

  j := pg_temp.tests_as('Humna Mahnoor', 'Hamna Masood');
  t := pg_temp.next_named(j, 'Weekly test 1');
  perform pg_temp.ok(jsonb_array_length(j->'tests') = 0,
    '2. marked but not locked: no mark reaches the parent yet');
  perform pg_temp.ok(t->>'status' = 'awaiting' and not (t ? 'marks'),
    '3. but the parent is told it was sat and the marks are on the way, with no mark in it');

  perform pg_temp.be('Sidra Teacher');
  perform public.fn_lock_assessment(v_t);

  j := pg_temp.tests_as('Humna Mahnoor', 'Hamna Masood');
  t := pg_temp.test_named(j, 'Weekly test 1');
  perform pg_temp.ok(t is not null and (t->>'marks')::numeric = 18 and (t->>'max_marks')::numeric = 20
                     and t->>'subject' = 'Maths' and (t->>'date')::date = pg_temp.k_today() - 2,
    '4. locked: the parent sees 18 out of 20 in Maths, on the day it was sat');
  perform pg_temp.ok((t->>'class_marked')::int = 5 and (t->>'class_average')::numeric = 14.0
                     and (t->>'class_highest')::numeric = 18,
    '5. five pupils sat it: the average (18+10+12+14+16)/5 = 14 and the highest 18, the absentee left out');
  perform pg_temp.ok(pg_temp.next_named(j, 'Weekly test 1') is null,
    '6. and it is no longer listed as waiting for marks');
end $t$;

-- =============================================================================
-- 7-8. AN ABSENT CHILD, AND ANOTHER FAMILY
-- =============================================================================
do $t$
declare j jsonb; t jsonb; m_real text; m_fake text;
begin
  j := pg_temp.tests_as('Zoya Parent', 'Zoya Khan');
  t := pg_temp.test_named(j, 'Weekly test 1');
  perform pg_temp.ok((t->>'is_absent')::boolean and t->'marks' = 'null'::jsonb,
    '7. the absent child''s parent sees Absent, not a zero');

  perform pg_temp.be('Humna Mahnoor');
  begin
    perform public.fn_portal_child_tests(pg_temp.kid('Zoya Khan'));
  exception when others then m_real := sqlerrm; end;
  begin
    perform public.fn_portal_child_tests(gen_random_uuid());
  exception when others then m_fake := sqlerrm; end;
  perform pg_temp.ok(m_real is not null and m_real is not distinct from m_fake,
    '8. another family''s child is refused, with the same words as an invented id');
end $t$;

-- =============================================================================
-- 9-14. WHAT IS LEFT OUT, AND WHY
-- =============================================================================
do $t$
declare v_t uuid;
begin
  -- A small test: only two marks, everybody else absent.
  perform pg_temp.be('Sidra Teacher');
  insert into public.assessments (session_id, class_id, section_id, subject_id, title,
                                  assessment_date, max_marks, school_id)
    values (pg_temp.sess(), pg_temp.c4(), pg_temp.sec('A'), pg_temp.subj('English'),
            'Spelling', pg_temp.k_today() - 1, 10, pg_temp.school())
    returning id into v_t;
  perform public.fn_enter_assessment_marks(v_t, jsonb_build_array(
    jsonb_build_object('enrollment_id', pg_temp.enr('Hamna Masood'), 'marks', 7),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil One'), 'marks', 9),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil Two'), 'is_absent', true),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil Three'), 'is_absent', true),
    jsonb_build_object('enrollment_id', pg_temp.enr('Pupil Four'), 'is_absent', true),
    jsonb_build_object('enrollment_id', pg_temp.enr('Zoya Khan'), 'is_absent', true)));
  perform public.fn_lock_assessment(v_t);

  -- Coming up, today, and long forgotten.
  insert into public.assessments (session_id, class_id, section_id, subject_id, title,
                                  assessment_date, max_marks, school_id)
    values (pg_temp.sess(), pg_temp.c4(), pg_temp.sec('A'), pg_temp.subj('Maths'),
            'Tables quiz', pg_temp.k_today() + 5, 25, pg_temp.school()),
           (pg_temp.sess(), pg_temp.c4(), null, pg_temp.subj('English'),
            'Dictation', pg_temp.k_today(), 10, pg_temp.school()),
           (pg_temp.sess(), pg_temp.c4(), pg_temp.sec('A'), pg_temp.subj('Maths'),
            'Forgotten test', pg_temp.k_today() - 20, 10, pg_temp.school());
end $t$;

do $t$
declare v_t uuid; j jsonb; t jsonb;
begin
  -- A locked test in section B, written as the owner (the 4 A teacher does not
  -- teach 4 B), with the 4 B pupil's mark.
  perform pg_temp.be('Weekly Owner');
  insert into public.assessments (session_id, class_id, section_id, subject_id, title,
                                  assessment_date, max_marks, is_locked, school_id)
    values (pg_temp.sess(), pg_temp.c4(), pg_temp.sec('B'), pg_temp.subj('Maths'),
            'Section B test', pg_temp.k_today() - 3, 20, true, pg_temp.school())
    returning id into v_t;
  insert into public.mark_entries (assessment_id, enrollment_id, marks, max_marks, is_locked, school_id)
    values (v_t, pg_temp.enr('Section B Pupil'), 11, 20, true, pg_temp.school());

  -- A locked whole-class test from before Hamna had a row: no mark for her.
  insert into public.assessments (session_id, class_id, section_id, subject_id, title,
                                  assessment_date, max_marks, is_locked, school_id)
    values (pg_temp.sess(), pg_temp.c4(), pg_temp.sec('A'), pg_temp.subj('Maths'),
            'Before she joined', pg_temp.k_today() - 4, 20, true, pg_temp.school())
    returning id into v_t;
  insert into public.mark_entries (assessment_id, enrollment_id, marks, max_marks, is_locked, school_id)
    values (v_t, pg_temp.enr('Pupil One'), 12, 20, true, pg_temp.school());

  j := pg_temp.tests_as('Humna Mahnoor', 'Hamna Masood');

  t := pg_temp.test_named(j, 'Spelling');
  perform pg_temp.ok((t->>'marks')::numeric = 7 and (t->>'class_marked')::int = 2
                     and t->'class_average' = 'null'::jsonb and t->'class_highest' = 'null'::jsonb,
    '9. two pupils sat it: her 7 out of 10, and NO average or highest, which would give away the other mark');
  perform pg_temp.ok((j->'tests'->0->>'title') = 'Spelling' and (j->'tests'->1->>'title') = 'Weekly test 1',
    '10. newest first');
  perform pg_temp.ok(pg_temp.next_named(j, 'Tables quiz')->>'status' = 'upcoming'
                     and pg_temp.next_named(j, 'Dictation')->>'status' = 'today',
    '11. a test in five days is coming up, and a whole-class test today says today');
  perform pg_temp.ok(pg_temp.next_named(j, 'Forgotten test') is null,
    '12. a test sat twenty days ago and never marked is not dangled in front of the parent');
  perform pg_temp.ok(pg_temp.test_named(j, 'Section B test') is null,
    '13. a test for section B does not reach a child in section A');
  perform pg_temp.ok(pg_temp.test_named(j, 'Before she joined') is null,
    '14. a test with no mark row for her is not shown as one she sat');
end $t$;

-- =============================================================================
-- 15-17. WHO ELSE MAY CALL IT, AND fn_portal_me
-- =============================================================================
do $t$
declare j jsonb; c jsonb; v_ok boolean := false;
begin
  perform pg_temp.be('Sidra Teacher');
  begin
    perform public.fn_portal_child_tests(pg_temp.kid('Hamna Masood'));
    v_ok := true;
  exception when others then null; end;
  perform pg_temp.ok(not v_ok, '15. a teacher is not a parent, and the portal read refuses them');

  perform pg_temp.be('Humna Mahnoor');
  set local role authenticated;
  j := public.fn_portal_me();
  reset role;
  perform pg_temp.ok(jsonb_array_length(j->'children') = 1,
    '16. one row for Hamna, although last year''s Class 3 enrollment was left active');
  c := j->'children'->0;
  perform pg_temp.ok(c->>'class_name' = 'Class 4' and c->>'section_name' = 'A'
                     and c->>'roll_no' = '12' and c->>'class_teacher' = 'Sidra Teacher'
                     and (c->>'dob')::date = (pg_temp.k_today() - interval '9 years')::date,
    '17. this year''s class, roll 12, class teacher Sidra Teacher, and the birthday');
end $t$;

-- =============================================================================
-- 18. A SCHOOL THAT HAS STOPPED PAYING CLOSES ITS PORTAL (0106), STILL
--
-- 0106 patched that line into the live fn_portal_me, not into 0033's text, so
-- a rewrite from the file would quietly reopen the portal. The first draft of
-- 0150 did exactly that and CI's verify.sql caught it; this keeps it caught.
-- =============================================================================
do $t$
declare v_kid uuid := pg_temp.kid('Hamna Masood'); m_me text; m_tests text;
begin
  update public.subscriptions set status = 'trialing', trial_ends_on = current_date - 14,
         period_start = null, period_end = null
   where school_id = pg_temp.school();
  perform pg_temp.be('Humna Mahnoor');
  begin perform public.fn_portal_me(); exception when others then m_me := sqlerrm; end;
  begin perform public.fn_portal_child_tests(v_kid); exception when others then m_tests := sqlerrm; end;
  perform pg_temp.ok(m_me like '%portal for this school is closed%'
                     and m_tests like '%portal for this school is closed%',
    '18. an unpaid school''s parent gets the closed notice from the entry point and from the tests');
end $t$;

select 'ALL WEEKLY TEST ASSERTIONS PASSED' as result;
rollback;
