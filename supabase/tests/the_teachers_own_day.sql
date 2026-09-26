-- =============================================================================
-- The teacher's own day (0151).
--
-- Walked as the real logins: a class teacher, a teacher who only teaches one
-- subject to one section, and a principal. Asserts:
--
--   * the subject teacher sees their class (the portal used to be empty for
--     them) and may set a test in their subject, and not in another
--   * fn_my_day counts today's register for the class teacher only, lists the
--     birthdays and the week's tests of the caller's own classes, and counts
--     the tests waiting to be marked
--   * a teacher can remove an empty, unlocked test they may set, and nothing
--     else: not one with a mark, not a locked one, not a colleague's
--   * a locked test cannot be edited, the total cannot change once a mark is
--     saved, and the head's reopen and the teacher's lock still work
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/the_teachers_own_day.sql
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

create or replace function pg_temp.raises(p_sql text, p_label text, p_like text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_like is not null and sqlerrm not like p_like then
      raise exception 'FAIL  % (refused, but with: %)', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 80);
    return;
  end;
  raise exception 'FAIL  % (it was ALLOWED)', p_label;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

create or replace function pg_temp.k_today() returns date language sql stable as
  $$ select (now() at time zone 'Asia/Karachi')::date $$;

-- --- Fixture -----------------------------------------------------------------
-- Class 4 (no sections): five pupils, Hamna's birthday today, class teacher
-- Sidra. Class 5 A and 5 B: Maths in 5 A taught by Bilal, who is nobody's
-- class teacher. A principal.
do $seed$
declare
  v_school uuid;
  v_own uuid := '00000000-0000-0000-0000-0000000fc001';
  v_ct  uuid := '00000000-0000-0000-0000-0000000fc002';
  v_st  uuid := '00000000-0000-0000-0000-0000000fc003';
  v_pr  uuid := '00000000-0000-0000-0000-0000000fc004';
  v_sess uuid; v_c4 uuid; v_c5 uuid; v_5a uuid; v_5b uuid;
  v_maths5 uuid; v_eng5 uuid; v_stf_ct uuid; v_stf_st uuid; v_fam uuid; v_kid uuid; v_name text; v_i int := 0;
begin
  insert into public.schools (name) values ('Own Day School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own, 'own@day.test'), (v_ct, 'ct@day.test'), (v_st, 'st@day.test'), (v_pr, 'pr@day.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own, 'Day Owner',     'owner',           v_school),
    (v_ct,  'Sidra Teacher', 'class_teacher',   v_school),
    (v_st,  'Bilal Teacher', 'subject_teacher', v_school),
    (v_pr,  'Day Principal', 'principal',       v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2026-2027', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id) values ('Class 4', 4, v_school) returning id into v_c4;
  insert into public.classes (name, level_order, school_id) values ('Class 5', 5, v_school) returning id into v_c5;
  insert into public.sections (class_id, name, school_id) values (v_c5, 'A', v_school) returning id into v_5a;
  insert into public.sections (class_id, name, school_id) values (v_c5, 'B', v_school) returning id into v_5b;
  insert into public.subjects (name, class_id, school_id) values ('Maths', v_c5, v_school) returning id into v_maths5;
  insert into public.subjects (name, class_id, school_id) values ('English', v_c5, v_school) returning id into v_eng5;
  insert into public.subjects (name, class_id, school_id) values ('Urdu', v_c4, v_school);

  insert into public.staff (full_name, designation, school_id) values ('Sidra Teacher', 'Teacher', v_school) returning id into v_stf_ct;
  insert into public.staff (full_name, designation, school_id) values ('Bilal Teacher', 'Teacher', v_school) returning id into v_stf_st;
  alter table public.profiles disable trigger user;
  update public.profiles set staff_id = v_stf_ct where id = v_ct;
  update public.profiles set staff_id = v_stf_st where id = v_st;
  alter table public.profiles enable trigger user;
  perform public.fn_set_class_teacher(v_stf_ct, v_sess, v_c4, null);
  insert into public.subject_teachers (staff_id, session_id, class_id, section_id, subject_id, school_id)
    values (v_stf_st, v_sess, v_c5, v_5a, v_maths5, v_school);

  insert into public.families (school_id, head_name) values (v_school, 'Everyone') returning id into v_fam;
  insert into public.students (full_name, status, school_id, family_id, dob)
    values ('Hamna Masood', 'active', v_school, v_fam, pg_temp.k_today() - interval '9 years') returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, status, school_id)
    values (v_kid, v_sess, v_c4, 'active', v_school);
  foreach v_name in array array['Four One', 'Four Two', 'Four Three', 'Four Four'] loop
    insert into public.students (full_name, status, school_id, family_id) values (v_name, 'active', v_school, v_fam) returning id into v_kid;
    insert into public.enrollments (student_id, session_id, class_id, status, school_id) values (v_kid, v_sess, v_c4, 'active', v_school);
  end loop;
  foreach v_name in array array['Five A One', 'Five A Two', 'Five A Three', 'Five B One'] loop
    v_i := v_i + 1;
    insert into public.students (full_name, status, school_id, family_id, dob)
      values (v_name, 'active', v_school, v_fam, case when v_name = 'Five B One' then pg_temp.k_today() - interval '10 years' end)
      returning id into v_kid;
    insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
      values (v_kid, v_sess, v_c5, case when v_i <= 3 then v_5a else v_5b end, 'active', v_school);
  end loop;

  -- Today's register for Class 4: three of five marked.
  insert into public.attendance_daily (enrollment_id, attendance_date, status, school_id)
    select e.id, pg_temp.k_today(), x.st::public.attendance_status, v_school
      from public.enrollments e join public.students s on s.id = e.student_id
      join (values ('Hamna Masood', 'present'), ('Four One', 'present'), ('Four Two', 'absent')) x(n, st) on x.n = s.full_name;
  raise notice 'fixture ok';
end $seed$;

create or replace function pg_temp.id_of(p_table text, p_name text) returns uuid language plpgsql stable as $$
declare v uuid;
begin
  execute format('select id from public.%I where name = %L and school_id = (select id from public.schools where name = ''Own Day School'')', p_table, p_name) into v;
  return v;
end;
$$;
create or replace function pg_temp.school() returns uuid language sql stable as
  $$ select id from public.schools where name = 'Own Day School' $$;
create or replace function pg_temp.sess() returns uuid language sql stable as
  $$ select id from public.academic_sessions where school_id = pg_temp.school() and is_current $$;
create or replace function pg_temp.sec5(p text) returns uuid language sql stable as
  $$ select id from public.sections where class_id = pg_temp.id_of('classes', 'Class 5') and name = p $$;
create or replace function pg_temp.subj(p_class text, p text) returns uuid language sql stable as
  $$ select id from public.subjects where class_id = pg_temp.id_of('classes', p_class) and name = p $$;

-- =============================================================================
-- 1-4. WHO TEACHES WHAT
-- =============================================================================
do $t$
declare r record; n int;
begin
  perform pg_temp.be('Bilal Teacher');
  select count(*) into n from public.fn_my_assignments();
  perform pg_temp.ok(n = 0, '1. a subject teacher has no class-teacher assignment, as before');
  select * into r from public.fn_my_teaching();
  perform pg_temp.ok(r.class_name = 'Class 5' and r.section_name = 'A' and not r.is_class_teacher
                     and r.subject_name = 'Maths',
    '2. but fn_my_teaching gives them Class 5 A, Maths, which every teacher screen used to leave out');

  perform pg_temp.be('Sidra Teacher');
  select * into r from public.fn_my_teaching();
  perform pg_temp.ok(r.class_name = 'Class 4' and r.section_id is null and r.is_class_teacher and r.subject_id is null,
    '3. the class teacher of Class 4 has the whole class, with no subject');

  -- The subject teacher may set a test in their subject, as the Tests screen
  -- inserts it, under the authenticated role so the row policy is exercised.
  perform pg_temp.be('Bilal Teacher');
  set local role authenticated;
  insert into public.assessments (session_id, class_id, section_id, subject_id, title, assessment_date, max_marks)
    values (pg_temp.sess(), pg_temp.id_of('classes', 'Class 5'), pg_temp.sec5('A'), pg_temp.subj('Class 5', 'Maths'),
            'Maths quiz', pg_temp.k_today() + 2, 10);
  reset role;
  perform pg_temp.ok(exists (select 1 from public.assessments where title = 'Maths quiz'),
    '4. and can set a Maths test for 5 A');
end $t$;

do $t$
begin
  perform pg_temp.be('Bilal Teacher');
  perform pg_temp.raises(format($q$
    set local role authenticated;
    insert into public.assessments (session_id, class_id, section_id, subject_id, title, assessment_date, max_marks)
      values (%L, %L, %L, %L, 'English spelling', %L, 10)$q$,
      pg_temp.sess(), pg_temp.id_of('classes', 'Class 5'), pg_temp.sec5('A'), pg_temp.subj('Class 5', 'English'),
      pg_temp.k_today() + 2),
    '5. but not an English test, which is not theirs');
  reset role;
end $t$;

do $t$
begin
  perform pg_temp.be('Bilal Teacher');
  perform pg_temp.raises(format($q$
    set local role authenticated;
    insert into public.assessments (session_id, class_id, section_id, subject_id, title, assessment_date, max_marks)
      values (%L, %L, null, %L, 'Maths for all of Class 5', %L, 10)$q$,
      pg_temp.sess(), pg_temp.id_of('classes', 'Class 5'), pg_temp.subj('Class 5', 'Maths'), pg_temp.k_today() + 2),
    '5b. nor a Maths test for the whole of Class 5: he teaches 5 A, and it would let him mark 5 B');
  reset role;
  perform pg_temp.ok(not public.fn_may_set_a_test(pg_temp.sess(), pg_temp.id_of('classes', 'Class 5'), null,
                                                  pg_temp.subj('Class 5', 'Maths')),
    '5c. fn_may_set_a_test says no to a whole-class test from a section''s teacher');
  perform pg_temp.be('Sidra Teacher');
  perform pg_temp.ok(public.fn_may_set_a_test(pg_temp.sess(), pg_temp.id_of('classes', 'Class 4'), null, null),
    '5d. while the class teacher of the whole of Class 4 may set one for all of it');
end $t$;

-- =============================================================================
-- 6-11. THE DAY
-- =============================================================================
do $t$
declare j jsonb; c jsonb;
begin
  -- A test Sidra set for yesterday and never marked, and one for tomorrow.
  perform pg_temp.be('Sidra Teacher');
  insert into public.assessments (session_id, class_id, subject_id, title, assessment_date, max_marks, school_id)
    values (pg_temp.sess(), pg_temp.id_of('classes', 'Class 4'), pg_temp.subj('Class 4', 'Urdu'),
            'Imla', pg_temp.k_today() - 1, 10, pg_temp.school()),
           (pg_temp.sess(), pg_temp.id_of('classes', 'Class 4'), null, 'General knowledge', pg_temp.k_today() + 1, 20, pg_temp.school());

  j := public.fn_my_day();
  c := j->'classes'->0;
  perform pg_temp.ok(jsonb_array_length(j->'classes') = 1 and c->>'class_name' = 'Class 4'
                     and (c->>'pupils')::int = 5 and (c->>'is_class_teacher')::boolean,
    '6. Sidra''s day: one class, Class 4, five pupils');
  perform pg_temp.ok((c->'register'->>'marked')::int = 3 and (c->'register'->>'present')::int = 2
                     and (c->'register'->>'absent')::int = 1 and not (c->'register'->>'locked')::boolean,
    '7. today''s register: three of five marked, two present, one absent, not locked');
  perform pg_temp.ok(jsonb_array_length(j->'birthdays') = 1 and j->'birthdays'->0->>'full_name' = 'Hamna Masood'
                     and (j->'birthdays'->0->>'turning')::int = 9,
    '8. Hamna turns nine today, and Class 5''s birthday is not on Sidra''s list');
  perform pg_temp.ok((j->>'to_mark')::int = 1
                     and exists (select 1 from jsonb_array_elements(j->'upcoming') u where u->>'title' = 'General knowledge')
                     and not exists (select 1 from jsonb_array_elements(j->'upcoming') u where u->>'title' = 'Maths quiz'),
    '9. one test to mark, tomorrow''s test is coming up, and the Maths quiz in Class 5 is not hers');

  perform pg_temp.be('Bilal Teacher');
  j := public.fn_my_day();
  c := j->'classes'->0;
  perform pg_temp.ok(jsonb_array_length(j->'classes') = 1 and c->>'section_name' = 'A'
                     and (c->>'pupils')::int = 3 and c->'register' = 'null'::jsonb
                     and c->'subjects' = '["Maths"]'::jsonb,
    '10. Bilal''s day: 5 A, three pupils, Maths, and no register to be asked about');
  perform pg_temp.ok(jsonb_array_length(j->'birthdays') = 0
                     and exists (select 1 from jsonb_array_elements(j->'upcoming') u where u->>'title' = 'Maths quiz'),
    '11. the 5 B birthday is not his class, and his Maths quiz is coming up');

  perform pg_temp.be('Day Principal');
  perform pg_temp.raises('select public.fn_my_day()', '12. a principal has no teacher''s day', '%teacher%');
end $t$;

-- =============================================================================
-- 13-17. REMOVING A TEST SET BY MISTAKE
-- =============================================================================
do $t$
declare v_empty uuid; v_marked uuid; v_hamna uuid;
begin
  perform pg_temp.be('Sidra Teacher');
  insert into public.assessments (session_id, class_id, title, assessment_date, max_marks, school_id)
    values (pg_temp.sess(), pg_temp.id_of('classes', 'Class 4'), 'Test 1 (twice)', pg_temp.k_today(), 20, pg_temp.school())
    returning id into v_empty;
  perform public.fn_delete_my_test(v_empty);
  perform pg_temp.ok(not exists (select 1 from public.assessments where id = v_empty),
    '13. an empty test set by mistake is removed by its teacher');

  insert into public.assessments (session_id, class_id, title, assessment_date, max_marks, school_id)
    values (pg_temp.sess(), pg_temp.id_of('classes', 'Class 4'), 'Weekly test 1', pg_temp.k_today(), 20, pg_temp.school())
    returning id into v_marked;
  select e.id into v_hamna from public.enrollments e join public.students s on s.id = e.student_id
   where s.full_name = 'Hamna Masood';
  perform public.fn_enter_assessment_marks(v_marked, jsonb_build_array(
    jsonb_build_object('enrollment_id', v_hamna, 'marks', 18)));
  perform pg_temp.raises(format('select public.fn_delete_my_test(%L)', v_marked),
    '14. a test with a mark in it is not removed', '%Marks have been entered%');

  perform pg_temp.be('Bilal Teacher');
  perform pg_temp.raises(format('select public.fn_delete_my_test(%L)',
      (select id from public.assessments where title = 'General knowledge')),
    '15. a colleague''s test is not removed', '%class and subject you teach%');

  perform pg_temp.be('Day Principal');
  perform pg_temp.raises(format('select public.fn_delete_my_test(%L)',
      (select id from public.assessments where title = 'General knowledge')),
    '16. and a principal uses the overview, not the teacher''s button');
end $t$;

-- =============================================================================
-- 17-22. A LOCKED TEST IS FROZEN, AND SAVED MARKS FIX THE TOTAL
-- =============================================================================
do $t$
declare v_t uuid; v_gk uuid;
begin
  select id into v_t from public.assessments where title = 'Weekly test 1';
  select id into v_gk from public.assessments where title = 'General knowledge';

  perform pg_temp.be('Sidra Teacher');
  perform pg_temp.raises(format('update public.assessments set max_marks = 25 where id = %L', v_t),
    '17. the total cannot change once a mark is saved out of it', '%out of 20, so the total cannot change to 25.%');
  update public.assessments set max_marks = 25, title = 'General knowledge quiz' where id = v_gk;
  perform pg_temp.ok((select max_marks from public.assessments where id = v_gk) = 25,
    '18. a test with no marks yet can still have its total and title corrected');

  -- Everyone marked, then locked by the teacher.
  perform public.fn_enter_assessment_marks(v_t, (
    select jsonb_agg(jsonb_build_object('enrollment_id', e.id, 'marks', 10))
      from public.enrollments e where e.class_id = pg_temp.id_of('classes', 'Class 4')));
  perform public.fn_lock_assessment(v_t);
  perform pg_temp.ok((select is_locked from public.assessments where id = v_t),
    '19. the teacher''s lock still works');

  perform pg_temp.raises(format('update public.assessments set title = ''Renamed'' where id = %L', v_t),
    '20. a locked test cannot be renamed', '%locked%');
  perform pg_temp.raises(format('update public.assessments set assessment_date = assessment_date - 1 where id = %L', v_t),
    '21. nor re-dated', '%locked%');
  perform pg_temp.raises(format('select public.fn_delete_my_test(%L)', v_t),
    '22. nor removed', '%locked%');

  perform pg_temp.be('Day Principal');
  perform public.fn_unlock_assessment(v_t, 'one mark was entered against the wrong child');
  perform pg_temp.ok(not (select is_locked from public.assessments where id = v_t),
    '23. and the head''s reopen still works');
end $t$;

-- =============================================================================
-- 24. A LOCKED REGISTER IS REPORTED AS LOCKED
-- =============================================================================
do $t$
declare j jsonb;
begin
  insert into public.attendance_daily (enrollment_id, attendance_date, status, school_id)
    select e.id, pg_temp.k_today(), 'present', pg_temp.school()
      from public.enrollments e
     where e.class_id = pg_temp.id_of('classes', 'Class 4')
       and not exists (select 1 from public.attendance_daily ad
                        where ad.enrollment_id = e.id and ad.attendance_date = pg_temp.k_today());
  update public.attendance_daily set is_locked = true
   where attendance_date = pg_temp.k_today()
     and enrollment_id in (select id from public.enrollments where class_id = pg_temp.id_of('classes', 'Class 4'));
  perform pg_temp.be('Sidra Teacher');
  j := public.fn_my_day();
  perform pg_temp.ok((j->'classes'->0->'register'->>'marked')::int = 5
                     and (j->'classes'->0->'register'->>'locked')::boolean,
    '24. every pupil marked and locked, and the day says so');
end $t$;

select 'ALL TEACHER''S OWN DAY ASSERTIONS PASSED' as result;
rollback;
