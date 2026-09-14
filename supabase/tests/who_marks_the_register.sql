-- =============================================================================
-- Who marks the register, who sets a test, and what the head can see.
--
-- Migrations 0134 and 0135 take two things away from the principal and give
-- them one thing back. This suite exists because all three are the kind of
-- change that looks done in the UI and is not done in the database: a hidden
-- button is not a revoked right, and the whole point of taking marking away
-- from the head is that the register means something afterwards.
--
-- So every refusal here is tested AS `authenticated`, through the real policy
-- and the real function, and each one has to be refused FOR THE RIGHT REASON.
-- A suite that accepts any exception passes on a typo.
--
-- WHAT IS DELIBERATELY ASSERTED AS STILL ALLOWED, and matters as much:
--
--   * the principal can still REOPEN a finalised day. That is 0121 and it is
--     the remedy for a child marked absent by mistake, which otherwise follows
--     them onto every result card ever printed.
--   * the OWNER can still mark. 0134's header gives the reasoning at length;
--     the short version is that 'owner' is the signup account rather than a job
--     title, a school of this size often has only that one account with any
--     authority, and no screen offers marking to it anyway. It is asserted here
--     so that if somebody later decides to close the hatch, this file tells
--     them exactly where and what they are changing.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/who_marks_the_register.sql
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

create or replace function pg_temp.be(p_name text) returns void language plpgsql as $$
begin
  perform set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
end;
$$;

-- Refused, and saying the right thing. "permission denied" and a syntax error
-- both raise, and a suite that cannot tell them apart passes on a typo.
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

create or replace function pg_temp.allowed(p_sql text) returns boolean language plpgsql as $$
begin
  set local role authenticated;
  execute p_sql;
  reset role;
  return true;
exception when others then
  raise notice '  (refused: %)', sqlerrm;
  reset role;
  return false;
end;
$$;

-- Counting AS `authenticated`. A count run as the table owner ignores row
-- security entirely, so a read test that forgets this passes on a table with
-- no policy at all.
create or replace function pg_temp.count_as_user(p_sql text)
returns bigint language plpgsql as $$
declare n bigint;
begin
  set local role authenticated;
  execute p_sql into n;
  reset role;
  return n;
exception when others then
  reset role;
  raise notice '  (read refused: %)', sqlerrm;
  return -1;
end;
$$;

create temp table t (k text primary key, v uuid);
create temp table d (k text primary key, v date);

do $seed$
declare
  s1  uuid := gen_random_uuid();
  own uuid := '00000000-0000-0000-0000-0000000f0001';
  hed uuid := '00000000-0000-0000-0000-0000000f0002';
  ct  uuid := '00000000-0000-0000-0000-0000000f0003';
  st  uuid := '00000000-0000-0000-0000-0000000f0004';
  obs uuid := '00000000-0000-0000-0000-0000000f0005';
  par uuid := '00000000-0000-0000-0000-0000000f0006';
  ses uuid; c4 uuid; c5 uuid; sec4 uuid; sec5 uuid;
  fam uuid; stu uuid; enr uuid; enr5 uuid; stu5 uuid;
  maths uuid; urdu uuid;
  ct_staff uuid; st_staff uuid;
  -- Karachi, because every date bound in the product is Karachi and a test
  -- using current_date is wrong for five hours of every day.
  today date := (now() at time zone 'Asia/Karachi')::date;
begin
  insert into public.schools (id, name, city) values (s1, 'Register Authority School', 'Sialkot');
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (s1, 'growth', 'active', today + 90);
  insert into auth.users (id, email) values
    (own, 'owner@auth.test'), (hed, 'head@auth.test'), (ct, 'ct@auth.test'),
    (st, 'st@auth.test'), (obs, 'obs@auth.test'), (par, 'par@auth.test')
  on conflict (id) do nothing;

  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (s1, '2026-2027', today - 60, today + 240, true) returning id into ses;
  insert into public.classes (school_id, name, level_order) values
    (s1, 'Class 4', 4) returning id into c4;
  insert into public.classes (school_id, name, level_order) values
    (s1, 'Class 5', 5) returning id into c5;
  insert into public.sections (school_id, class_id, name) values (s1, c4, 'A') returning id into sec4;
  insert into public.sections (school_id, class_id, name) values (s1, c5, 'A') returning id into sec5;
  insert into public.subjects (school_id, class_id, name) values (s1, c4, 'Maths') returning id into maths;
  insert into public.subjects (school_id, class_id, name) values (s1, c4, 'Urdu') returning id into urdu;

  insert into public.families (school_id, head_name) values (s1, 'Auth Family') returning id into fam;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-A1', 'Four Child', fam, today - 30, 'active') returning id into stu;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (s1, stu, ses, c4, sec4, '1') returning id into enr;
  insert into public.students (school_id, gr_no, full_name, family_id, admission_date, status)
    values (s1, 'GR-A2', 'Five Child', fam, today - 30, 'active') returning id into stu5;
  insert into public.enrollments (school_id, student_id, session_id, class_id, section_id, roll_no)
    values (s1, stu5, ses, c5, sec5, '1') returning id into enr5;

  insert into public.staff (school_id, full_name, designation) values (s1, 'Class Teacher', 'Teacher')
    returning id into ct_staff;
  insert into public.staff (school_id, full_name, designation) values (s1, 'Subject Teacher', 'Teacher')
    returning id into st_staff;

  alter table public.profiles disable trigger user;
  insert into public.profiles (id, school_id, full_name, role, staff_id, family_id) values
    (own, s1, 'Auth Owner',     'owner',           null,     null),
    (hed, s1, 'Auth Head',      'principal',       null,     null),
    (ct,  s1, 'Auth CT',        'class_teacher',   ct_staff, null),
    (st,  s1, 'Auth ST',        'subject_teacher', st_staff, null),
    (obs, s1, 'Auth Observer',  'readonly',        null,     null),
    (par, s1, 'Auth Parent',    'parent',          null,     fam);
  alter table public.profiles enable trigger user;

  -- The class teacher owns Class 4 A. The subject teacher teaches Maths in
  -- Class 4 and nothing else, which is what makes assertion 12 mean something.
  insert into public.teacher_assignments (school_id, session_id, class_id, section_id, staff_id)
    values (s1, ses, c4, sec4, ct_staff);
  insert into public.subject_teachers (school_id, session_id, class_id, subject_id, staff_id)
    values (s1, ses, c4, maths, st_staff);

  insert into t values ('s1',s1),('own',own),('hed',hed),('ct',ct),('st',st),('obs',obs),
                       ('par',par),('ses',ses),('c4',c4),('c5',c5),('sec4',sec4),('sec5',sec5),
                       ('enr',enr),('enr5',enr5),('maths',maths),('urdu',urdu),('stu',stu);
  insert into d values ('today', today);
end $seed$;

-- =============================================================================
-- 1-6. The daily register
-- =============================================================================
do $reg$
declare
  v_enr uuid := (select v from t where k='enr');
  v_ses uuid := (select v from t where k='ses');
  v_c4  uuid := (select v from t where k='c4');
  v_s4  uuid := (select v from t where k='sec4');
  v_day date := (select v from d where k='today');
  v_marks text := format('[{"enrollment_id":"%s","status":"present"}]', v_enr);
begin
  perform pg_temp.be('Auth Head');
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select public.fn_mark_attendance(%L::date, %L::jsonb)', v_day, v_marks),
      'marked by the class teacher'),
    '1. a principal cannot mark the daily register');

  -- THE FUNCTION IS ONLY HALF OF IT. fn_mark_attendance is SECURITY DEFINER
  -- and bypasses row security, so a policy left unchanged would let the same
  -- person do the same thing over PostgREST with no function involved. 0024
  -- recorded exactly this fault for these tables in 2024 and answered it by
  -- revoking the table grant outright, which is why the refusal below says
  -- "permission denied" rather than naming a policy: the grant is checked
  -- first and there is nothing left for the policy to refuse.
  --
  -- 0134 rewrote the policies anyway. A revoke is one ALTER away from being
  -- undone by a future migration restoring a convenience grant, and a policy
  -- that still named the principal would then be the only thing between the
  -- office and the register. Asserted as "refused", not as "refused by the
  -- policy", because which of the two doors is shut first is not the property
  -- that matters.
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('insert into public.attendance_daily (enrollment_id, attendance_date, status) '
             || 'values (%L::uuid, %L::date, ''present'')', v_enr, v_day),
      'permission denied'),
    '2. nor by writing the table directly, going round the function');

  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select public.fn_finalize_attendance(%L::uuid, %L::uuid, %L::uuid, %L::date)',
             v_ses, v_c4, v_s4, v_day),
      'finalised by the teacher'),
    '3. nor finalise one, which would let the office shut a register at 9am '
    || 'with three pupils marked');

  perform pg_temp.be('Auth CT');
  perform pg_temp.ok(
    pg_temp.allowed(format('select public.fn_mark_attendance(%L::date, %L::jsonb)', v_day, v_marks)),
    '4. the class teacher marks their own register, which is the whole point');

  perform pg_temp.be('Auth ST');
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select public.fn_mark_attendance(%L::date, ''[{"enrollment_id":"%s","status":"absent"}]''::jsonb)',
             v_day, (select v from t where k='enr5')),
      'your assigned class'),
    '5. a teacher is still scoped to their own class, not just to the role');

  -- The hatch, asserted rather than assumed. See this file's header.
  perform pg_temp.be('Auth Owner');
  perform pg_temp.ok(
    pg_temp.allowed(format('select public.fn_mark_attendance(%L::date, %L::jsonb)', v_day, v_marks)),
    '6. the OWNER can still mark, deliberately. 0134 says why, and says that '
    || 'deleting ''owner'' from fn_may_write_register is the one-line change '
    || 'if that is ever decided against');
end $reg$;

-- =============================================================================
-- 7. What the principal KEEPS
-- =============================================================================
do $keeps$
declare
  v_ses uuid := (select v from t where k='ses');
  v_c4  uuid := (select v from t where k='c4');
  v_s4  uuid := (select v from t where k='sec4');
  v_day date := (select v from d where k='today');
begin
  perform pg_temp.be('Auth CT');
  perform public.fn_finalize_attendance(v_ses, v_c4, v_s4, v_day);

  perform pg_temp.be('Auth Head');
  perform pg_temp.ok(
    pg_temp.allowed(
      format('select public.fn_unlock_attendance(%L::uuid, %L::uuid, %L::uuid, %L::date, %L)',
             v_ses, v_c4, v_s4, v_day, 'marked absent in error')),
    '7. a principal can still REOPEN a finalised day. Reopening is an approval, '
    || 'not a marking, and without it a child marked absent by mistake stays '
    || 'absent on every result card ever printed');
end $keeps$;

-- =============================================================================
-- 8-11. The head's screen
-- =============================================================================
do $grid$
declare
  v_ses uuid := (select v from t where k='ses');
  v_day date := (select v from d where k='today');
  v4 record; v5 record;
begin
  perform pg_temp.be('Auth Head');
  select * into v4 from public.fn_attendance_day(v_ses, v_day) where class_name = 'Class 4';
  select * into v5 from public.fn_attendance_day(v_ses, v_day) where class_name = 'Class 5';

  perform pg_temp.ok(v4.pupils = 1 and v4.marked = 1 and v4.state = 'unlocked',
    '8. a marked but reopened class reads as "done but unlocked"');
  perform pg_temp.ok(v5.pupils = 1 and v5.marked = 0 and v5.state = 'none',
    '9. a class nobody touched reads as "not done", counted against its ROLL '
    || 'rather than against its attendance rows. An unmarked child is not a '
    || 'row, so counting rows would make an empty register look complete');

  perform pg_temp.be('Auth CT');
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select * from public.fn_attendance_day(%L::uuid, %L::date)', v_ses, v_day),
      'whole school'),
    '10. a teacher cannot read the whole school''s register at once');

  perform pg_temp.be('Auth Observer');
  perform pg_temp.ok(
    pg_temp.count_as_user(format(
      'select count(*) from public.fn_attendance_day(%L::uuid, %L::date)', v_ses, v_day)) = 2,
    '11. an observer CAN, because 0059 settled readonly as a role that sees '
    || 'the oversight screens and writes nothing');
end $grid$;

-- =============================================================================
-- 12-17. Subject attendance
-- =============================================================================
do $subj$
declare
  v_ses uuid := (select v from t where k='ses');
  v_c4  uuid := (select v from t where k='c4');
  v_s4  uuid := (select v from t where k='sec4');
  v_day date := (select v from d where k='today');
  v_enr uuid := (select v from t where k='enr');
  v_maths uuid := (select v from t where k='maths');
  v_urdu  uuid := (select v from t where k='urdu');
  v_marks text := format('[{"enrollment_id":"%s","status":"absent"}]', v_enr);
  r record;
begin
  perform pg_temp.be('Auth ST');
  perform pg_temp.ok(
    pg_temp.allowed(format(
      'select public.fn_mark_subject_attendance(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::date,%L::jsonb)',
      v_ses, v_c4, v_s4, v_maths, v_day, v_marks)),
    '12. the subject teacher marks their own subject');

  perform pg_temp.ok(
    pg_temp.refused_saying(format(
      'select public.fn_mark_subject_attendance(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::date,%L::jsonb)',
      v_ses, v_c4, v_s4, v_urdu, v_day, v_marks),
      'assigned to teach'),
    '13. and not a subject somebody else teaches in the same class');

  perform pg_temp.be('Auth Head');
  perform pg_temp.ok(
    pg_temp.refused_saying(format(
      'select public.fn_mark_subject_attendance(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::date,%L::jsonb)',
      v_ses, v_c4, v_s4, v_maths, v_day, v_marks),
      'marked by the subject teacher'),
    '14. a principal cannot mark subject attendance either');

  select * into r from public.fn_subject_attendance_day(v_ses, v_day);
  perform pg_temp.ok(r.subject_name = 'Maths' and r.absent = 1 and r.pupils = 1,
    '15. the head sees what was marked, with the counts');

  perform pg_temp.ok(
    (select count(*) from public.fn_subject_attendance_day(v_ses, v_day)) = 1,
    '16. AND ONLY WHAT WAS MARKED. Urdu was not marked and does not appear. '
    || 'This register is optional, so an unmarked subject is not outstanding; '
    || 'listing every one would put forty red rows on the head''s screen every '
    || 'morning and teach them to stop reading it');

  -- The daily register must be untouched by any of this. Two answers to "was
  -- this child present today" is the failure 0097 and 0100 exist to prevent,
  -- and the subject register records an ABSENCE for a child the class teacher
  -- marked PRESENT, which is exactly the pair that would collide.
  perform pg_temp.ok(
    (select status from public.attendance_daily
      where enrollment_id = v_enr and attendance_date = v_day) = 'present',
    '17. and the daily register still says present, because subject attendance '
    || 'is a separate question and never a second opinion about the same one');
end $subj$;

do $subjread$
declare
  v_ses uuid := (select v from t where k='ses');
  v_day date := (select v from d where k='today');
begin
  perform pg_temp.be('Auth Parent');
  perform pg_temp.ok(
    pg_temp.count_as_user('select count(*) from public.attendance_subject') <= 0,
    '18. a parent reads no subject attendance at all. A second attendance '
    || 'figure reaching a father is precisely the confusion this must not cause');

  perform pg_temp.be('Auth CT');
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select * from public.fn_subject_attendance_day(%L::uuid, %L::date)', v_ses, v_day),
      'shown to the head'),
    '19. and a class teacher does not get the school-wide panel');
end $subjread$;

-- =============================================================================
-- 20-26. Tests
-- =============================================================================
do $tests$
declare
  v_ses uuid := (select v from t where k='ses');
  v_c4  uuid := (select v from t where k='c4');
  v_s4  uuid := (select v from t where k='sec4');
  v_maths uuid := (select v from t where k='maths');
  v_day date := (select v from d where k='today');
  v_new text;
begin
  v_new := format(
    'insert into public.assessments (session_id, class_id, section_id, subject_id, title, '
    || 'assessment_date, max_marks) values (%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L,%L::date,20)',
    v_ses, v_c4, v_s4, v_maths, 'Head''s Test', v_day);

  perform pg_temp.be('Auth Head');
  perform pg_temp.ok(pg_temp.refused_saying(v_new, 'row-level security'),
    '20. a principal cannot create a test');

  perform pg_temp.be('Auth ST');
  perform pg_temp.ok(
    pg_temp.allowed(format(
      'insert into public.assessments (session_id, class_id, section_id, subject_id, title, '
      || 'assessment_date, max_marks) values (%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L,%L::date,20)',
      v_ses, v_c4, v_s4, v_maths, 'Weekly Test 1', v_day - 3)),
    '21. the subject teacher can, for their own subject');

  -- SCHEDULING. A future date is allowed, which is the feature; entering marks
  -- against it is not, which is what makes the feature safe.
  perform pg_temp.ok(
    pg_temp.allowed(format(
      'insert into public.assessments (session_id, class_id, section_id, subject_id, title, '
      || 'assessment_date, max_marks) values (%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L,%L::date,20)',
      v_ses, v_c4, v_s4, v_maths, 'Saturday Test', v_day + 4)),
    '22. and can schedule one for a day that has not happened yet');

  perform pg_temp.ok(
    pg_temp.refused_saying(format(
      'insert into public.assessments (session_id, class_id, section_id, subject_id, title, '
      || 'assessment_date, max_marks) values (%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L,%L::date,20)',
      v_ses, v_c4, v_s4, v_maths, 'Mistyped Year', v_day + 500),
      'more than a year away'),
    '23. but not for 2031, which is what a mistyped year looks like. A test '
    || 'four years out never appears in the unmarked list and is never noticed '
    || 'again');

  perform pg_temp.ok(
    pg_temp.refused_saying(format(
      'insert into public.assessments (session_id, class_id, section_id, subject_id, title, '
      || 'assessment_date, max_marks) values (%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L,%L::date,20)',
      v_ses, v_c4, v_s4, v_maths, 'Before The Year', v_day - 90),
      'before the academic year'),
    '24. nor before the academic year began');
end $tests$;

do $marking$
declare
  v_future uuid := (select id from public.assessments where title = 'Saturday Test');
  v_past   uuid := (select id from public.assessments where title = 'Weekly Test 1');
  v_enr    uuid := (select v from t where k='enr');
  v_marks  text := format('[{"enrollment_id":"%s","marks":15,"is_absent":false}]', v_enr);
begin
  perform pg_temp.be('Auth ST');
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select public.fn_enter_assessment_marks(%L::uuid, %L::jsonb)', v_future, v_marks),
      'scheduled for'),
    '25. a paper that has not been sat has no marks');

  perform pg_temp.be('Auth Head');
  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select public.fn_enter_assessment_marks(%L::uuid, %L::jsonb)', v_past, v_marks),
      'marked by the teacher who set it'),
    '26. and a principal does not enter marks for one that has');

  perform pg_temp.ok(
    pg_temp.refused_saying(format('select public.fn_lock_assessment(%L::uuid)', v_past),
                           'locked by the teacher'),
    '27. nor lock it, which is the teacher saying they have finished');
end $marking$;

-- =============================================================================
-- 28-33. The two dashboards
-- =============================================================================
do $chase$
declare
  v_ses uuid := (select v from t where k='ses');
  v_day date := (select v from d where k='today');
  r record;
  n integer;
begin
  perform pg_temp.be('Auth ST');
  select count(*) into n from public.fn_my_unmarked_tests(v_ses);
  perform pg_temp.ok(n = 1,
    '28. the teacher is chased for the paper they set three days ago and have '
    || 'not marked');

  select * into r from public.fn_my_unmarked_tests(v_ses);
  perform pg_temp.ok(r.title = 'Weekly Test 1' and r.days_late = 3,
    '29. with how late it is, because "unmarked" without "since when" is not a '
    || 'thing anybody acts on');

  -- Partially marked still counts. The common failure is not a blank test, it
  -- is twenty of thirty-four and then the bell went.
  perform public.fn_enter_assessment_marks(
    (select id from public.assessments where title = 'Weekly Test 1'),
    format('[{"enrollment_id":"%s","marks":15,"is_absent":false}]',
           (select v from t where k='enr'))::jsonb);
  select count(*) into n from public.fn_my_unmarked_tests(v_ses);
  perform pg_temp.ok(n = 0,
    '30. and stops being chased once every pupil has a mark or an absence');

  perform pg_temp.be('Auth Head');
  perform pg_temp.ok(
    pg_temp.refused_saying(format('select * from public.fn_my_unmarked_tests(%L::uuid)', v_ses),
                           'teacher''s own list'),
    '31. a principal has no papers of their own, and is told so rather than '
    || 'shown an empty list that reads as "nothing to mark"');
end $chase$;

do $overview$
declare
  v_ses uuid := (select v from t where k='ses');
  v_day date := (select v from d where k='today');
  v_sched text; v_marked text;
begin
  perform pg_temp.be('Auth Head');
  select state into v_marked from public.fn_tests_overview(v_ses, v_day - 30, v_day + 30)
   where title = 'Weekly Test 1';
  select state into v_sched from public.fn_tests_overview(v_ses, v_day - 30, v_day + 30)
   where title = 'Saturday Test';

  perform pg_temp.ok(v_marked = 'marked' and v_sched = 'scheduled',
    '32. the head sees one test marked and one still to come, which is the '
    || 'calendar working in both directions');

  perform pg_temp.ok(
    pg_temp.refused_saying(
      format('select * from public.fn_tests_overview(%L::uuid, %L::date, %L::date)',
             v_ses, v_day - 3000, v_day),
      'a year at a time'),
    '33. and cannot ask for a decade, which on a school connection is a '
    || 'spinner with no end');
end $overview$;

-- =============================================================================
-- 34. The anchor a frozen migration reads is still CODE
-- =============================================================================
do $anchor$
declare
  v_src  text;
  v_code text;
begin
  /*
   * MIGRATION 0085 IS A TEXT PATCH ON fn_enter_assessment_marks AND IT IS
   * FROZEN INSIDE BUNDLE 7. Its idempotency guard reads
   *
   *     if v_old like '%fn_may_mark_subject%' then   (skip, already done)
   *
   * so a body that no longer contains that name is one 0085 does not
   * recognise: it tries its regexp, matches nothing, and raises. A bundle is
   * ONE transaction, so that rolls back the whole of bundle 7, and verify.sql
   * tells a school in several of its FAIL messages to "re-run bundle 7". The
   * repair path dead-ends on exactly the database that needed it.
   *
   * 0135's first draft did precisely this by calling fn_may_set_a_test
   * instead, and CI caught it. This assertion exists so the next person does
   * not have to.
   *
   * COMMENTS ARE STRIPPED BEFORE LOOKING, and that is the point of the
   * assertion rather than a detail. pg_get_functiondef returns the comments
   * too, so a body that merely MENTIONS fn_may_mark_subject while calling
   * something else satisfies 0085 by accident and satisfies nothing else. That
   * is a guard passed by a comment, which is worse than no guard: it goes on
   * passing after somebody deletes the code. What has to be true is that the
   * call is still there.
   */
  v_src := pg_get_functiondef(
    'public.fn_enter_assessment_marks(uuid, jsonb, text)'::regprocedure);
  v_code := regexp_replace(v_src, '--[^' || chr(10) || ']*', '', 'g');

  if position('fn_may_mark_subject' in v_code) = 0 then
    raise exception 'FAIL  34. fn_enter_assessment_marks no longer CALLS '
                    'fn_may_mark_subject. Migration 0085 is a frozen text '
                    'patch on this function and keys its idempotency guard on '
                    'that name, so re-pasting bundle 7 will raise and roll the '
                    'whole bundle back. verify.sql tells schools to re-run '
                    'bundle 7, so this breaks the repair path. See the long '
                    'note in 0135 above the two checks.';
  end if;
  raise notice 'ok  34. the anchor migration 0085 reads is still a call, not a comment';
end $anchor$;

rollback;
\echo 'WHO MARKS THE REGISTER: ALL TESTS PASSED'
