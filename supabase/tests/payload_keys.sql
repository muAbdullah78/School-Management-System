-- =============================================================================
-- A key the database does not recognise is lost data, not a harmless extra.
--
-- WHY THIS FILE EXISTS
--
-- Found by making the mistake, not by reading. A seed script sent `practical`
-- where fn_enter_marks reads `practical_marks`. The function accepted the call,
-- reported success, and wrote NULL into the practical column for a whole class.
-- Nothing raised, nothing logged, and the marksheet simply showed an empty
-- practical column, which reads as "nobody has entered the practicals yet".
--
-- WHAT THE FOUR ACTUALLY DID, measured. The first draft of this suite asserted
-- that a misspelt attendance status marks a class present and a misspelt amount
-- posts a receipt for nothing. Both were wrong, and running it is what showed
-- that:
--
--   fn_enter_marks             SILENT. `practical` stores NULL; `absent` for
--                              `is_absent` stores false, so a child who sat no
--                              paper is recorded as having scored nothing,
--                              which prints as a FAIL on a card that goes home.
--   fn_enter_assessment_marks  the same, on a class test.
--   fn_mark_attendance         already refused, by the NOT NULL constraint on
--                              attendance_daily.status.
--   fn_record_bulk_payments    already refused, with "Amount for <name> must be
--                              more than zero".
--
-- Two lose data silently; two are saved by a constraint that happens to be
-- there. 0101 covers all four anyway, because the two that refuse say the wrong
-- thing about why ("must be more than zero" to a clerk who typed an amount is a
-- morning wasted), and because being saved by a constraint is luck rather than
-- a rule.
--
-- So this suite asserts what is actually true of each: that the four correct
-- payloads still go through, that the two silent ones now REFUSE rather than
-- writing, and that all four name the key that was wrong.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/payload_keys.sql
-- =============================================================================

\set ON_ERROR_STOP on

begin;

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- Fixture: one class, one pupil, one paper ------------------------------
do $seed$
declare
  v_school uuid; v_owner uuid := '00000000-0000-0000-0000-0000000000b7';
  v_sess uuid; v_class uuid; v_sec uuid; v_stu uuid; v_enr uuid;
  v_subj uuid; v_term uuid; v_es uuid; v_assess uuid;
begin
  insert into public.schools (name) values ('Payload Key School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'k1@keys.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Keys Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;
  perform set_config('test.uid', v_owner::text, false);

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_school;
  insert into public.classes (name, level_order, school_id)
    values ('Class 9', 9, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.students (full_name, status, school_id)
    values ('Key Test Pupil', 'active', v_school) returning id into v_stu;
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;

  insert into public.subjects (name, school_id, is_practical)
    values ('Physics', v_school, true) returning id into v_subj;
  insert into public.exam_terms (name, session_id, school_id, starts_on, ends_on)
    values ('Mid Term', v_sess, v_school, date '2026-03-01', date '2026-03-10')
    returning id into v_term;
  v_es := public.fn_upsert_exam_subject(v_term, v_class, v_subj, 75, 25, 25,
                                        date '2026-03-02', '9am');

  raise notice 'fixture ok';
end $seed$;

-- =============================================================================
-- 1. The correct payload still goes through, with the practical intact
--
-- First, because a guard that refuses everything also passes every "does it
-- refuse?" test. This is the assertion that would catch an allow-list typed
-- with a wrong key in it.
-- =============================================================================
do $t$
declare
  v_es uuid; v_enr uuid; j jsonb; v_prac numeric;
begin
  select es.id into v_es from public.exam_subjects es
    join public.exam_terms t on t.id = es.exam_term_id
   where t.school_id = (select id from public.schools where name = 'Payload Key School');
  select e.id into v_enr from public.enrollments e
    join public.students s on s.id = e.student_id
   where s.full_name = 'Key Test Pupil';

  j := public.fn_enter_marks(v_es, jsonb_build_array(jsonb_build_object(
        'enrollment_id', v_enr, 'marks', 70, 'practical_marks', 24, 'is_absent', false)));

  select me.practical_marks into v_prac from public.mark_entries me
   where me.exam_subject_id = v_es and me.enrollment_id = v_enr;
  if v_prac <> 24 then
    raise exception 'FAIL: a correct payload did not store the practical mark (got %)', v_prac;
  end if;

  raise notice '1. the correct payload goes through, practical and all — ok';
end $t$;

-- =============================================================================
-- 2. The exact mistake that started this: `practical` for `practical_marks`
-- =============================================================================
do $t$
declare v_es uuid; v_enr uuid; v_ok boolean := false; v_msg text;
begin
  select es.id into v_es from public.exam_subjects es
    join public.exam_terms t on t.id = es.exam_term_id
   where t.school_id = (select id from public.schools where name = 'Payload Key School');
  select e.id into v_enr from public.enrollments e
    join public.students s on s.id = e.student_id
   where s.full_name = 'Key Test Pupil';

  begin
    perform public.fn_enter_marks(v_es, jsonb_build_array(jsonb_build_object(
      'enrollment_id', v_enr, 'marks', 70, 'practical', 24, 'is_absent', false)));
    v_ok := true;
  exception when others then
    v_msg := sqlerrm;
  end;

  if v_ok then
    raise exception 'FAIL: `practical` was accepted and silently thrown away. '
                    'That is a whole class of practical marks lost with a '
                    'success message on screen.';
  end if;
  -- The message has to NAME the key. "Invalid input" sends somebody hunting.
  if v_msg not like '%practical%' then
    raise exception 'FAIL: the refusal does not name the key that was wrong: %', v_msg;
  end if;
  if v_msg not like '%practical_marks%' then
    raise exception 'FAIL: the refusal does not say what it does read, so the '
                    'caller cannot fix it: %', v_msg;
  end if;

  raise notice '2. a misspelt practical is refused, by name — ok';
end $t$;

-- =============================================================================
-- 3. Attendance: `state` for `status` names the key instead of the constraint
--
-- This one never wrote a bad row: attendance_daily.status is NOT NULL, so the
-- insert failed. What it did do was report a constraint violation, which tells
-- the caller nothing about the key they got wrong. Both properties are asserted
-- here, because the second is the improvement and the first is what must not
-- regress.
-- =============================================================================
do $t$
declare v_enr uuid; v_ok boolean := false; v_msg text; v_marked int;
begin
  select e.id into v_enr from public.enrollments e
    join public.students s on s.id = e.student_id
   where s.full_name = 'Key Test Pupil';

  begin
    perform public.fn_mark_attendance(current_date, jsonb_build_array(jsonb_build_object(
      'enrollment_id', v_enr, 'state', 'absent')));
    v_ok := true;
  exception when others then
    v_msg := sqlerrm;
  end;

  if v_ok then
    raise exception 'FAIL: `state` was accepted for `status`.';
  end if;
  if v_msg not like '%state%' then
    raise exception 'FAIL: the refusal blames something other than the key that '
                    'was wrong, which is what it did before 0101: %', v_msg;
  end if;
  select count(*) into v_marked from public.attendance_daily
   where enrollment_id = v_enr and attendance_date = current_date;
  if v_marked <> 0 then
    raise exception 'FAIL: the refused call still wrote % attendance row(s)', v_marked;
  end if;

  -- and the correct one works
  perform public.fn_mark_attendance(current_date, jsonb_build_array(jsonb_build_object(
    'enrollment_id', v_enr, 'status', 'absent')));
  if not exists (select 1 from public.attendance_daily
                  where enrollment_id = v_enr and attendance_date = current_date
                    and status = 'absent') then
    raise exception 'FAIL: the correct attendance payload no longer works';
  end if;

  raise notice '3. a misspelt attendance status is refused BY NAME, and writes nothing — ok';
end $t$;

-- =============================================================================
-- 4. Bulk payments: `amt` for `amount` blamed the amount, not the key
--
-- This one also never wrote a bad row: the function refused with "Amount for
-- <name> must be more than zero". Accurate about the value it saw and useless
-- about the cause, to a clerk who is looking at an amount they definitely
-- typed.
-- =============================================================================
do $t$
declare v_stu uuid; v_ok boolean := false; v_msg text; v_before int; v_after int;
begin
  select id into v_stu from public.students where full_name = 'Key Test Pupil';
  select count(*) into v_before from public.payments;

  begin
    perform public.fn_record_bulk_payments(
      jsonb_build_array(jsonb_build_object('student_id', v_stu, 'amt', 500)), 'cash', 'test');
    v_ok := true;
  exception when others then
    v_msg := sqlerrm;
  end;

  if v_ok then
    raise exception 'FAIL: `amt` was accepted for `amount`.';
  end if;
  if v_msg not like '%amt%' then
    raise exception 'FAIL: the refusal still blames the amount rather than '
                    'naming the key: %', v_msg;
  end if;
  select count(*) into v_after from public.payments;
  if v_after <> v_before then
    raise exception 'FAIL: the refused bulk payment still wrote % payment row(s)',
      v_after - v_before;
  end if;

  raise notice '4. a misspelt payment amount is refused BY NAME, and writes nothing — ok';
end $t$;

-- =============================================================================
-- 4b. The OTHER silent one: `absent` for `is_absent`
--
-- Worth its own block because it is the case with the sharpest consequence and
-- it is not the one that started this. Before 0101 it was accepted and stored
-- as false, so a child who sat no paper was recorded as having scored nothing.
-- On a printed card that is a FAIL, and it goes home.
-- =============================================================================
do $t$
declare v_es uuid; v_enr uuid; v_ok boolean := false; v_msg text; v_rows int;
begin
  select es.id into v_es from public.exam_subjects es
    join public.exam_terms t on t.id = es.exam_term_id
   where t.school_id = (select id from public.schools where name = 'Payload Key School');
  select e.id into v_enr from public.enrollments e
    join public.students s on s.id = e.student_id
   where s.full_name = 'Key Test Pupil';
  select count(*) into v_rows from public.mark_entries where exam_subject_id = v_es;

  begin
    perform public.fn_enter_marks(v_es, jsonb_build_array(jsonb_build_object(
      'enrollment_id', v_enr, 'marks', null, 'absent', true)));
    v_ok := true;
  exception when others then
    v_msg := sqlerrm;
  end;

  if v_ok then
    raise exception 'FAIL: `absent` was accepted for `is_absent`. A child who '
                    'sat no paper is now on record as having scored nothing, '
                    'which prints as a FAIL on the card that goes home.';
  end if;
  if v_msg not like '%absent%' then
    raise exception 'FAIL: the refusal does not name the key: %', v_msg;
  end if;

  raise notice '4b. a misspelt absence flag is refused, by name — ok';
end $t$;

-- =============================================================================
-- 5. The shared rule is not reachable by a signed-in user
--
-- It takes a payload and an allow-list and decides nothing about permissions,
-- so exposing it is pointless rather than dangerous. It is revoked because the
-- fn__ prefix means internal, and a convention with an exception is a habit.
-- =============================================================================
do $t$
declare v_leaks text := '';
begin
  if has_function_privilege('anon', 'public.fn__only_these_keys(jsonb, text[], text)', 'execute') then
    v_leaks := v_leaks || 'anon ';
  end if;
  if has_function_privilege('authenticated', 'public.fn__only_these_keys(jsonb, text[], text)', 'execute') then
    v_leaks := v_leaks || 'authenticated ';
  end if;
  if v_leaks <> '' then
    raise exception 'FAIL: fn__only_these_keys is executable by: %', v_leaks;
  end if;
  raise notice '5. the shared rule is revoked from the client roles — ok';
end $t$;

-- =============================================================================
-- 6. Every payload function that should refuse, does
--
-- By catalogue, so adding a fifth list-of-rows function and forgetting the
-- guard fails here. The three importers and fn_admit_student are excluded by
-- name with the reason, because refusing an unknown column in a CSV importer
-- would break the feature it exists for.
-- =============================================================================
do $t$
declare v_missing text;
begin
  select string_agg(x.name, ', ' order by x.name) into v_missing
  from (values ('fn_enter_marks'), ('fn_enter_assessment_marks'),
               ('fn_mark_attendance'), ('fn_record_bulk_payments')) as x(name)
  where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = x.name
      and p.prosrc like '%fn__only_these_keys%');
  if v_missing is not null then
    raise exception 'FAIL: these accept a key they do not read: %', v_missing;
  end if;

  -- And the guard has to sit AFTER the permission gate, not before it. A caller
  -- who may not do the thing should be told that and nothing else, and the
  -- first draft of 0101 got this backwards.
  select string_agg(p.proname, ', ' order by p.proname) into v_missing
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosrc like '%fn__only_these_keys%'
    and p.proname <> 'fn__only_these_keys'
    and position('Not permitted' in p.prosrc) > position('fn__only_these_keys' in p.prosrc);
  if v_missing is not null then
    raise exception 'FAIL: % validates the payload before checking permission', v_missing;
  end if;

  raise notice '6. all four refuse, and each authorises first — ok';
end $t$;

rollback;
\echo 'PAYLOAD KEYS: ALL TESTS PASSED'
