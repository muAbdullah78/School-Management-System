-- =============================================================================
-- The result card.
--
-- This suite exists because the generator was confidently wrong in three ways
-- at once, and the arithmetic was plausible enough that nobody would have
-- questioned it. Reproduced on a real database before 0058 was written:
--
--   Arts Child     card said 180/275 = 65.45%  grade C  position 1
--   Science Child  card said 160/275 = 58.18%  grade D  position 2
--   Unmarked Child card said   0/275 =  0.00%  grade F  position 3
--
-- Truth: 90.00% A+, 91.43% A+, and "marks not entered yet". Two A+ pupils shown
-- as a C and a D, the ranking inverted so prize day goes to the wrong child, and
-- a pupil nobody had marked printed as having failed.
--
-- The rules this file defends:
--
--   1. A PUPIL IS MARKED OUT OF THEIR OWN SUBJECTS. The denominator is the
--      papers that pupil sits, not every paper in the class. This is the whole
--      of defect 1, and the assertion uses two streams with DIFFERENT paper
--      totals (Physics 75, Civics 100) because equal totals would let a wrong
--      denominator produce the right answer by accident.
--   2. THE RANKING FOLLOWS THE TRUE PERCENTAGES. Asserted as an ORDER, not as
--      two independent numbers: the old defect got both percentages wrong in a
--      way that also swapped their order, and a test on percentages alone would
--      have caught the first fault and not the second.
--   3. "NOT MARKED" IS NEVER A ZERO. Generation refuses and names the subject
--      and the count. A provisional card excludes unmarked papers from the
--      denominator AND says it is provisional — both, because one without the
--      other is the original defect with a label on it.
--   4. "ABSENT" IS NOT "NOT MARKED". An absent pupil scores zero and the paper
--      STAYS in their denominator. They sat nothing, but a fact was recorded.
--   5. A STREAMED CLASS WITH A STREAMLESS PUPIL IS REFUSED. Otherwise that
--      pupil silently gets a card with half their subjects missing, which is
--      the same wrongness in a new place.
--   6. PRACTICAL MARKS COUNT, in their own column, validated against their own
--      maximum — not against the theory paper's.
--   7. PASS AND FAIL ARE STATED, per subject and overall, and both facts (the
--      aggregate and the number of subjects failed) are recorded so a school
--      with a different promotion rule can apply it.
--   8. ASSESSMENTS COUNT ONLY IF THE TERM SAYS SO, and a term that asks for
--      them when none carry a weight gives the exam the full 100% rather than
--      handing every pupil a zero for a component that does not exist.
--   9. NOTHING CROSSES A SCHOOL BOUNDARY, in both directions.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/exam_computation.sql
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

create or replace function pg_temp.raises(p_sql text, p_needle text) returns boolean
language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return position(lower(p_needle) in lower(sqlerrm)) > 0;
end;
$$;

-- The latest card for a pupil, by name.
create or replace function pg_temp.card(p_name text) returns jsonb language sql as $$
  select rc.frozen from public.result_cards rc
   join public.students s on s.id = rc.student_id
  where rc.school_id = public.current_school_id() and s.full_name = p_name
  order by rc.version desc limit 1
$$;

create or replace function pg_temp.enr(p_name text) returns uuid language sql as $$
  select e.id from public.enrollments e
   join public.students s on s.id = e.student_id
  where e.school_id = public.current_school_id() and s.full_name = p_name
    and e.status = 'active'
  order by e.created_at desc limit 1
$$;

create or replace function pg_temp.paper(p_subject text) returns uuid language sql as $$
  select es.id from public.exam_subjects es
   join public.subjects sub on sub.id = es.subject_id
  where es.school_id = public.current_school_id() and sub.name = p_subject
  limit 1
$$;

-- --- Fixture -----------------------------------------------------------------
-- The exact class from the header, in school A, plus a mirror in school B whose
-- numbers differ so a leak cannot look like a pass.
--
-- Papers are deliberately UNEQUAL — Physics 75, Civics 100, English 100 — so a
-- wrong denominator cannot come out right by coincidence.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000000ec001';
  v_ob uuid := '00000000-0000-0000-0000-0000000ec002';
  v_sess uuid; v_cl uuid; v_term uuid;
  v_eng uuid; v_phy uuid; v_civ uuid;
  v_sci uuid; v_arts uuid; v_un uuid; v_abs uuid; v_nostream uuid;
  v_e_sci uuid; v_e_arts uuid; v_e_un uuid; v_e_abs uuid;
  v_es_eng uuid; v_es_phy uuid; v_es_civ uuid;
  v_sess_b uuid; v_cl_b uuid; v_term_b uuid; v_eng_b uuid; v_es_b uuid;
  v_stu_b uuid; v_e_b uuid;
begin
  -- BOTH schools are created before any login is adopted. Creating a school
  -- fires the provisioning trigger, and doing that while already signed in as
  -- another school's owner trips the cross-tenant write guard — correctly.
  insert into public.schools (name) values ('Exam A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Exam B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  insert into auth.users (id, email) values (v_oa, 'oa@exam.test'), (v_ob, 'ob@exam.test');
  insert into public.profiles (id, school_id, full_name, role, active)
    values (v_oa, v_a, 'Exam Owner A', 'owner', true),
           (v_ob, v_b, 'Exam Owner B', 'owner', true);

  -- ---- School A ----
  perform set_config('test.uid', v_oa::text, false);

  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_a, '2025-26', '2025-04-01', '2026-03-31', true) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess, pass_percent = 33
   where school_id = v_a;

  insert into public.classes (school_id, name, level_order) values (v_a, 'Class 9', 9)
    returning id into v_cl;

  insert into public.subjects (school_id, name, class_id, stream, sort_order)
    values (v_a, 'English', v_cl, null, 1) returning id into v_eng;
  -- Physics carries a practical, which is what makes assertion 6 meaningful.
  insert into public.subjects (school_id, name, class_id, stream, is_practical, sort_order)
    values (v_a, 'Physics', v_cl, 'Science', true, 2) returning id into v_phy;
  insert into public.subjects (school_id, name, class_id, stream, sort_order)
    values (v_a, 'Civics', v_cl, 'Arts', 3) returning id into v_civ;

  insert into public.exam_terms (school_id, session_id, name, term_type,
                                 starts_on, ends_on, result_withheld_for_defaulters)
    values (v_a, v_sess, 'Final', 'final', '2026-02-01', '2026-02-15', false)
    returning id into v_term;

  -- English 100/33, Physics 60 theory + 15 practical = 75/25, Civics 100/33.
  v_es_eng := public.fn_upsert_exam_subject(v_term, v_cl, v_eng, 100, 33, 0);
  v_es_phy := public.fn_upsert_exam_subject(v_term, v_cl, v_phy, 60, 25, 15);
  v_es_civ := public.fn_upsert_exam_subject(v_term, v_cl, v_civ, 100, 33, 0);

  insert into public.students (school_id, full_name, status)
    values (v_a, 'Science Child', 'active') returning id into v_sci;
  insert into public.students (school_id, full_name, status)
    values (v_a, 'Arts Child', 'active') returning id into v_arts;
  insert into public.students (school_id, full_name, status)
    values (v_a, 'Unmarked Child', 'active') returning id into v_un;
  insert into public.students (school_id, full_name, status)
    values (v_a, 'Absent Child', 'active') returning id into v_abs;

  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, stream, status)
    values (v_a, v_sci, v_sess, v_cl, '1', 'Science', 'active') returning id into v_e_sci;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, stream, status)
    values (v_a, v_arts, v_sess, v_cl, '2', 'Arts', 'active') returning id into v_e_arts;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, stream, status)
    values (v_a, v_un, v_sess, v_cl, '3', 'Science', 'active') returning id into v_e_un;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, stream, status)
    values (v_a, v_abs, v_sess, v_cl, '4', 'Arts', 'active') returning id into v_e_abs;

  -- Science Child: English 90/100, Physics 55/60 theory + 15/15 practical.
  --   → 90 + 70 = 160 out of 100 + 75 = 175  →  91.43%
  perform public.fn_enter_marks(v_es_eng,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_e_sci, 'marks', 90)));
  perform public.fn_enter_marks(v_es_phy,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_e_sci,
                                         'marks', 55, 'practical_marks', 15)));

  -- Arts Child: English 88/100, Civics 92/100  →  180 of 200  →  90.00%
  perform public.fn_enter_marks(v_es_eng,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_e_arts, 'marks', 88)));
  perform public.fn_enter_marks(v_es_civ,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_e_arts, 'marks', 92)));

  -- Absent Child: absent for English, 40/100 in Civics.
  --   → 0 + 40 = 40 out of 200  →  20.00%, and English STAYS in the denominator.
  perform public.fn_enter_marks(v_es_eng,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_e_abs, 'is_absent', true)));
  perform public.fn_enter_marks(v_es_civ,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_e_abs, 'marks', 40)));

  -- Unmarked Child: nothing at all.

  -- ---- School B: same shape, different numbers ----
  perform set_config('test.uid', v_ob::text, false);

  insert into public.academic_sessions (school_id, name, starts_on, ends_on, is_current)
    values (v_b, '2025-26', '2025-04-01', '2026-03-31', true) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (school_id, name, level_order) values (v_b, 'Class 9', 9)
    returning id into v_cl_b;
  insert into public.subjects (school_id, name, class_id, sort_order)
    values (v_b, 'English', v_cl_b, 1) returning id into v_eng_b;
  insert into public.exam_terms (school_id, session_id, name, term_type)
    values (v_b, v_sess_b, 'Final', 'final') returning id into v_term_b;
  v_es_b := public.fn_upsert_exam_subject(v_term_b, v_cl_b, v_eng_b, 50, 20, 0);
  insert into public.students (school_id, full_name, status)
    values (v_b, 'Other School Child', 'active') returning id into v_stu_b;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    values (v_b, v_stu_b, v_sess_b, v_cl_b, '1', 'active') returning id into v_e_b;
  perform public.fn_enter_marks(v_es_b,
    jsonb_build_array(jsonb_build_object('enrollment_id', v_e_b, 'marks', 10)));
end;
$seed$;

-- =============================================================================
-- 1. Generation REFUSES while marks are missing, and names what is missing
-- =============================================================================
select pg_temp.be('Exam Owner A');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_generate_result_cards(%L, %L)',
           (select id from public.exam_terms where school_id = public.current_school_id()),
           (select id from public.classes where school_id = public.current_school_id())),
    'Marks are missing'),
  '1. generation refuses while any pupil has an unmarked paper');

select pg_temp.ok(
  (select count(*) from public.result_cards
    where school_id = public.current_school_id()) = 0,
  '2. the refusal wrote NOTHING — a refused generation must not leave half a class carded');

-- The refusal names the subject AND the count, because "Chemistry is missing for
-- 12 pupils" is actionable and a bare "marks are missing" is not.
select pg_temp.ok(
  exists (
    select 1 from public.fn_result_readiness(
      (select id from public.exam_terms where school_id = public.current_school_id()),
      (select id from public.classes where school_id = public.current_school_id()))
    where problem = 'marks not entered' and detail like 'English%' and affected = 1),
  '3. readiness names English, missing for exactly 1 pupil (the unmarked child)');

-- Physics is a SCIENCE paper. The Arts child and the absent Arts child do not
-- sit it, so it must be missing for exactly ONE pupil — the unmarked Science
-- child — and not for three.
select pg_temp.ok(
  exists (
    select 1 from public.fn_result_readiness(
      (select id from public.exam_terms where school_id = public.current_school_id()),
      (select id from public.classes where school_id = public.current_school_id()))
    where problem = 'marks not entered' and detail like 'Physics%' and affected = 1),
  '4. Physics is missing for 1 pupil, not 3 — the Arts children never sat it');

select pg_temp.ok(
  not exists (
    select 1 from public.fn_result_readiness(
      (select id from public.exam_terms where school_id = public.current_school_id()),
      (select id from public.classes where school_id = public.current_school_id()))
    where problem = 'marks not entered' and detail like 'Civics%'),
  '5. Civics is missing for nobody — both Arts children were marked');

-- =============================================================================
-- 2. The marksheet only lists pupils who sit the paper
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.fn_exam_marksheet(pg_temp.paper('Physics'))) = 2,
  '6. the Physics marksheet lists the 2 Science pupils, not the whole class');

select pg_temp.ok(
  not exists (select 1 from public.fn_exam_marksheet(pg_temp.paper('Physics'))
               where full_name in ('Arts Child', 'Absent Child')),
  '7. no Arts pupil appears on a Science marksheet');

select pg_temp.ok(
  (select count(*) from public.fn_exam_marksheet(pg_temp.paper('English'))) = 4,
  '8. the English marksheet lists all four — a subject with no stream is everyone''s');

select pg_temp.ok(
  (select practical_max from public.fn_exam_marksheet(pg_temp.paper('Physics')) limit 1) = 15
  and (select practical_max from public.fn_exam_marksheet(pg_temp.paper('English')) limit 1) = 0,
  '9. the marksheet reports the practical maximum, so the screen knows whether to show the column');

-- =============================================================================
-- 3. A practical mark is validated against ITS OWN maximum
-- =============================================================================
select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_enter_marks(%L, %L::jsonb)', pg_temp.paper('Physics'),
      jsonb_build_array(jsonb_build_object(
        'enrollment_id', pg_temp.enr('Science Child'), 'marks', 50, 'practical_marks', 20))),
    'Practical marks must be between 0 and 15'),
  '10. a practical of 20 against a maximum of 15 is refused — not silently accepted '
  || 'because the theory paper happens to be out of 60');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_enter_marks(%L, %L::jsonb)', pg_temp.paper('English'),
      jsonb_build_array(jsonb_build_object(
        'enrollment_id', pg_temp.enr('Arts Child'), 'marks', 50, 'practical_marks', 5))),
    'no practical component'),
  '11. a practical mark on a subject with no practical is refused, with a message that says why');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_upsert_exam_subject(%L, %L, %L, 100, 33, 20)',
      (select id from public.exam_terms where school_id = public.current_school_id()),
      (select id from public.classes where school_id = public.current_school_id()),
      (select id from public.subjects where school_id = public.current_school_id()
                                        and name = 'English')),
    'having a practical'),
  '12. a paper cannot be given practical marks for a subject not flagged as practical');

-- =============================================================================
-- 4. Now mark the last pupil and generate for real
-- =============================================================================
select public.fn_enter_marks(pg_temp.paper('English'),
  jsonb_build_array(jsonb_build_object('enrollment_id', pg_temp.enr('Unmarked Child'), 'marks', 30)));
select public.fn_enter_marks(pg_temp.paper('Physics'),
  jsonb_build_array(jsonb_build_object('enrollment_id', pg_temp.enr('Unmarked Child'),
                                       'marks', 20, 'practical_marks', 5)));

select public.fn_generate_result_cards(
  (select id from public.exam_terms where school_id = public.current_school_id()),
  (select id from public.classes  where school_id = public.current_school_id())) as generated \gset

select pg_temp.ok(
  (:'generated'::jsonb->>'generated')::int = 4
  and (:'generated'::jsonb->>'missing_marks')::int = 0,
  '13. all four cards generated, with nothing reported missing');

-- THE DEFECT, both halves. Marked out of their OWN subjects...
select pg_temp.ok(
  (pg_temp.card('Science Child')->>'total_max')::numeric = 175
  and (pg_temp.card('Science Child')->>'total_marks')::numeric = 160
  and (pg_temp.card('Science Child')->>'percentage')::numeric = 91.43,
  '14. the Science pupil is 160 out of 175 = 91.43%, not 160 out of 275 = 58.18%');

select pg_temp.ok(
  (pg_temp.card('Arts Child')->>'total_max')::numeric = 200
  and (pg_temp.card('Arts Child')->>'percentage')::numeric = 90.00,
  '15. the Arts pupil is 180 out of 200 = 90.00%, not 180 out of 275 = 65.45%');

select pg_temp.ok(
  pg_temp.card('Science Child')->>'grade' = 'A+'
  and pg_temp.card('Arts Child')->>'grade' = 'A+',
  '16. both are A+ — the old denominator turned them into a C and a D');

-- ...and ranked in the true order. Asserted as an ORDER: the old defect got both
-- percentages wrong in a way that also swapped them, and testing the numbers
-- alone would have caught one fault and not the other.
select pg_temp.ok(
  (pg_temp.card('Science Child')->>'position')::int
    < (pg_temp.card('Arts Child')->>'position')::int,
  '17. the Science pupil (91.43%) is ahead of the Arts pupil (90.00%) — the old '
  || 'card had them the other way round and prize day would have gone to the wrong child');

select pg_temp.ok(
  (pg_temp.card('Science Child')->>'position')::int = 1,
  '18. and the Science pupil is first');

-- =============================================================================
-- 5. A pupil's card carries only their own subjects
-- =============================================================================
select pg_temp.ok(
  (select count(*) from jsonb_array_elements(pg_temp.card('Science Child')->'subjects')) = 2,
  '19. the Science card has two subjects — English and Physics');

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(pg_temp.card('Science Child')->'subjects') j
               where j->>'subject' = 'Civics'),
  '20. Civics is not on a Science pupil''s card at all');

select pg_temp.ok(
  not exists (select 1 from jsonb_array_elements(pg_temp.card('Arts Child')->'subjects') j
               where j->>'subject' = 'Physics'),
  '21. Physics is not on an Arts pupil''s card');

-- =============================================================================
-- 6. Theory and practical are kept apart AND combined
-- =============================================================================
select pg_temp.ok(
  (select (j->>'marks')::numeric = 55 and (j->>'practical')::numeric = 15
          and (j->>'obtained')::numeric = 70 and (j->>'out_of')::numeric = 75
     from jsonb_array_elements(pg_temp.card('Science Child')->'subjects') j
    where j->>'subject' = 'Physics'),
  '22. Physics shows theory 55, practical 15, obtained 70 of 75 — separate and combined, '
  || 'so a board-style card can print either');

-- =============================================================================
-- 7. Absent scores zero and STAYS in the denominator
-- =============================================================================
select pg_temp.ok(
  (pg_temp.card('Absent Child')->>'total_max')::numeric = 200
  and (pg_temp.card('Absent Child')->>'total_marks')::numeric = 40
  and (pg_temp.card('Absent Child')->>'percentage')::numeric = 20.00,
  '23. the absent pupil is 40 of 200 = 20% — being absent is a zero, not an exemption');

select pg_temp.ok(
  (select (j->>'is_absent')::boolean and (j->>'marked')::boolean
     from jsonb_array_elements(pg_temp.card('Absent Child')->'subjects') j
    where j->>'subject' = 'English'),
  '24. an absent paper is recorded as marked AND absent — the two facts a zero cannot carry');

select pg_temp.ok(
  (pg_temp.card('Absent Child')->>'provisional')::boolean = false,
  '25. an absent pupil''s card is NOT provisional — nothing about it is pending');

-- =============================================================================
-- 8. Pass and fail, per subject and overall
-- =============================================================================
select pg_temp.ok(
  pg_temp.card('Science Child')->>'result' = 'PASS'
  and (pg_temp.card('Science Child')->>'failed_subjects')::int = 0,
  '26. the Science pupil passes, with no subject failed');

-- Absent Child: 0 in English (pass 33) and 40 in Civics (pass 33). One failed
-- subject, aggregate 20% against a 33% pass mark.
select pg_temp.ok(
  pg_temp.card('Absent Child')->>'result' = 'FAIL'
  and (pg_temp.card('Absent Child')->>'failed_subjects')::int = 1,
  '27. the absent pupil fails, and the card says in HOW MANY subjects — both facts, '
  || 'so a school promoting on aggregate alone can still apply its own rule');

select pg_temp.ok(
  (select (j->>'passed')::boolean = false
     from jsonb_array_elements(pg_temp.card('Absent Child')->'subjects') j
    where j->>'subject' = 'English')
  and (select (j->>'passed')::boolean = true
     from jsonb_array_elements(pg_temp.card('Absent Child')->'subjects') j
    where j->>'subject' = 'Civics'),
  '28. pass_marks finally does something: per-subject pass and fail on the card');

-- Unmarked Child, now marked: English 30/100 (fail, pass 33), Physics 25/75
-- (obtained 25, pass 25 → PASS, exactly on the mark).
select pg_temp.ok(
  (select (j->>'passed')::boolean = true
     from jsonb_array_elements(pg_temp.card('Unmarked Child')->'subjects') j
    where j->>'subject' = 'Physics'),
  '29. exactly ON the pass mark is a PASS, not a fail — an off-by-one here fails a real child');

-- =============================================================================
-- 9. Provisional cards: both halves, or neither
-- =============================================================================
-- Wipe one mark to recreate the incomplete state, then generate on purpose.
delete from public.mark_entries
 where exam_subject_id = pg_temp.paper('Civics')
   and enrollment_id = pg_temp.enr('Arts Child');

select public.fn_generate_result_cards(
  (select id from public.exam_terms where school_id = public.current_school_id()),
  (select id from public.classes  where school_id = public.current_school_id()),
  true) as prov \gset

select pg_temp.ok(
  (:'prov'::jsonb->>'provisional')::boolean = true
  and (:'prov'::jsonb->>'missing_marks')::int = 1,
  '30. an explicit provisional run reports that it WAS provisional and how much was missing');

select pg_temp.ok(
  (pg_temp.card('Arts Child')->>'provisional')::boolean = true
  and (pg_temp.card('Arts Child')->>'unmarked_subjects')::int = 1,
  '31. the affected card says it is provisional — a school must never hand out a '
  || 'partial card that looks final');

select pg_temp.ok(
  (pg_temp.card('Arts Child')->>'total_max')::numeric = 100
  and (pg_temp.card('Arts Child')->>'percentage')::numeric = 88.00,
  '32. and the missing paper leaves the DENOMINATOR too — 88 of 100, not 88 of 200. '
  || 'A provisional card that still divides by the full total is the original defect with a label');

select pg_temp.ok(
  pg_temp.card('Arts Child')->>'position' is null,
  '33. a provisional card carries no position — ranking an incomplete result against '
  || 'complete ones is how a prize goes to the wrong child');

select pg_temp.ok(
  (pg_temp.card('Science Child')->>'provisional')::boolean = false
  and (pg_temp.card('Science Child')->>'position')::int = 1,
  '34. the pupils who ARE complete keep a real card and a real position in the same run');

-- Put it back.
select public.fn_enter_marks(pg_temp.paper('Civics'),
  jsonb_build_array(jsonb_build_object('enrollment_id', pg_temp.enr('Arts Child'), 'marks', 92)));

-- =============================================================================
-- 10. A streamed class with a streamless pupil is REFUSED
-- =============================================================================
do $$
declare v_s uuid; v_e uuid;
begin
  insert into public.students (school_id, full_name, status)
    values (public.current_school_id(), 'No Stream Child', 'active') returning id into v_s;
  insert into public.enrollments (school_id, student_id, session_id, class_id, roll_no, status)
    values (public.current_school_id(), v_s,
            (select current_session_id from public.school_settings
              where school_id = public.current_school_id()),
            (select id from public.classes where school_id = public.current_school_id()),
            '9', 'active')
    returning id into v_e;
end;
$$;

select pg_temp.ok(
  exists (select 1 from public.fn_result_readiness(
            (select id from public.exam_terms where school_id = public.current_school_id()),
            (select id from public.classes where school_id = public.current_school_id()))
           where problem = 'pupils without a stream'
             and detail like '%No Stream Child%' and affected = 1),
  '35. readiness names the pupil who has no stream, rather than a count');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_generate_result_cards(%L, %L, true)',
           (select id from public.exam_terms where school_id = public.current_school_id()),
           (select id from public.classes where school_id = public.current_school_id())),
    'no stream set'),
  '36. a missing stream is refused even with allow_incomplete — it is a WRONG card, '
  || 'not an incomplete one, and no override should let it through');

select public.fn_set_enrollment_stream(pg_temp.enr('No Stream Child'), 'Science', 'BISE-2026-0099');

select pg_temp.ok(
  not exists (select 1 from public.fn_result_readiness(
                (select id from public.exam_terms where school_id = public.current_school_id()),
                (select id from public.classes where school_id = public.current_school_id()))
              where problem = 'pupils without a stream'),
  '37. setting the stream clears the blocker');

-- =============================================================================
-- 11. Board registration number reaches the card
-- =============================================================================
select public.fn_enter_marks(pg_temp.paper('English'),
  jsonb_build_array(jsonb_build_object('enrollment_id', pg_temp.enr('No Stream Child'), 'marks', 60)));
select public.fn_enter_marks(pg_temp.paper('Physics'),
  jsonb_build_array(jsonb_build_object('enrollment_id', pg_temp.enr('No Stream Child'),
                                       'marks', 40, 'practical_marks', 10)));

select public.fn_generate_result_cards(
  (select id from public.exam_terms where school_id = public.current_school_id()),
  (select id from public.classes  where school_id = public.current_school_id()));

select pg_temp.ok(
  pg_temp.card('No Stream Child')->>'bise_reg_no' = 'BISE-2026-0099'
  and pg_temp.card('No Stream Child')->>'stream' = 'Science',
  '38. the board registration number and the stream are on the card — two columns that '
  || 'existed from the start with no screen able to fill them');

select pg_temp.ok(
  pg_temp.card('Science Child')->>'bise_reg_no' is null,
  '39. a pupil with no board number simply has none — not an empty string to print');

select pg_temp.ok(
  (select count(*) from public.fn_class_streams(
     (select id from public.classes where school_id = public.current_school_id()))) = 5
  and exists (select 1 from public.fn_class_streams(
                (select id from public.classes where school_id = public.current_school_id()))
              where full_name = 'No Stream Child' and bise_reg_no = 'BISE-2026-0099'),
  '40. the class stream list shows every pupil, so a school can work down one screen');

-- =============================================================================
-- 12. Case and whitespace in a stream name do not silently exclude anybody
-- =============================================================================
select public.fn_set_enrollment_stream(pg_temp.enr('Science Child'), '  science  ', null);

select pg_temp.ok(
  (select count(*) from public.fn_exam_marksheet(pg_temp.paper('Physics'))) = 3,
  '41. "  science  " still matches the subject stream "Science" — a school that types it '
  || 'two ways would otherwise find every streamed paper mysteriously empty');

select public.fn_set_enrollment_stream(pg_temp.enr('Science Child'), 'Science', null);

-- =============================================================================
-- 13. Assessments count only if the term asks, and never as a zero
-- =============================================================================
do $$
declare v_asm uuid;
begin
  insert into public.assessments (school_id, session_id, class_id, subject_id, title,
                                  max_marks, weightage)
  values (public.current_school_id(),
          (select current_session_id from public.school_settings
            where school_id = public.current_school_id()),
          (select id from public.classes where school_id = public.current_school_id()),
          (select id from public.subjects where school_id = public.current_school_id()
                                            and name = 'English'),
          'Monthly Test 1', 20, 1)
  returning id into v_asm;

  -- The Science pupil scores full marks on it; the Arts pupil scores nothing at
  -- all on it — no mark_entries row, which is the case that used to become a zero.
  insert into public.mark_entries (school_id, assessment_id, enrollment_id, marks, max_marks)
  values (public.current_school_id(), v_asm, pg_temp.enr('Science Child'), 20, 20);
end;
$$;

-- With the weight still 0 the assessment must change nothing.
select public.fn_generate_result_cards(
  (select id from public.exam_terms where school_id = public.current_school_id()),
  (select id from public.classes  where school_id = public.current_school_id()));

select pg_temp.ok(
  (pg_temp.card('Science Child')->>'percentage')::numeric = 91.43
  and (pg_temp.card('Science Child')->>'assessment_weight_pct')::numeric = 0,
  '42. an assessment with a weight the TERM does not ask for changes nothing — the '
  || 'default must be exactly the old behaviour, or every existing card shifts on upgrade');

update public.exam_terms set assessment_weight_pct = 20
 where school_id = public.current_school_id();

select public.fn_generate_result_cards(
  (select id from public.exam_terms where school_id = public.current_school_id()),
  (select id from public.classes  where school_id = public.current_school_id()));

-- Science pupil: exam 91.43%, assessment 100%  →  91.43*0.8 + 100*0.2 = 93.14
select pg_temp.ok(
  (pg_temp.card('Science Child')->>'exam_percentage')::numeric = 91.43
  and (pg_temp.card('Science Child')->>'assessment_percentage')::numeric = 100.00
  and (pg_temp.card('Science Child')->>'percentage')::numeric = 93.14,
  '43. with the term asking for 20%: 91.43 x 0.8 + 100 x 0.2 = 93.14, and BOTH '
  || 'components are on the card so the arithmetic can be checked by hand');

-- Arts pupil sat no weighted assessment. The exam must carry the whole result.
select pg_temp.ok(
  (pg_temp.card('Arts Child')->>'percentage')::numeric = 90.00
  and (pg_temp.card('Arts Child')->>'assessment_weight_pct')::numeric = 0
  and pg_temp.card('Arts Child')->>'assessment_percentage' is null,
  '44. a pupil with no weighted assessment gets 100% from the exam — NOT a zero for '
  || '20% of their result, which is what a naive weighting would have handed them');

update public.exam_terms set assessment_weight_pct = 0
 where school_id = public.current_school_id();

-- =============================================================================
-- 14. The card says which card it is
-- =============================================================================
select pg_temp.ok(
  (pg_temp.card('Science Child')->>'version')::int >= 2
  and pg_temp.card('Science Child')->>'generated_at' is not null,
  '45. the frozen snapshot carries its version and the moment it was generated, so two '
  || 'cards in circulation after a correction can be told apart');

-- =============================================================================
-- 15. Nothing crosses a school boundary, in BOTH directions
-- =============================================================================
select pg_temp.ok(
  (select count(*) from public.result_cards where school_id = public.current_school_id()) =
  (select count(*) from public.result_cards rc
    join public.students s on s.id = rc.student_id
   where s.school_id = public.current_school_id()),
  '46. every card in school A belongs to a school A pupil');

select pg_temp.ok(
  not exists (
    select 1 from public.fn_class_streams(
      (select id from public.classes where school_id = public.current_school_id()))
    where full_name = 'Other School Child'),
  '47. school A''s class list cannot see school B''s pupil');

select pg_temp.be('Exam Owner B');

select pg_temp.ok(
  (select count(*) from public.result_cards where school_id = public.current_school_id()) = 0,
  '48. school B has no result cards — school A generating a class did not touch it');

select pg_temp.ok(
  not exists (
    select 1 from public.fn_class_streams(
      (select id from public.classes where school_id = public.current_school_id()))
    where full_name in ('Science Child', 'Arts Child', 'Absent Child')),
  '49. and school B''s class list cannot see school A''s pupils — the reverse direction, '
  || 'because a filter scoped to whichever school was created first passes one way only');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_generate_result_cards(%L, %L, true)',
           (select id from public.exam_terms where school_id <> public.current_school_id() limit 1),
           (select id from public.classes where school_id <> public.current_school_id() limit 1)),
    'not found in this school'),
  '50. school B cannot generate result cards for school A''s class');

select pg_temp.ok(
  pg_temp.raises(
    format('select public.fn_set_enrollment_stream(%L, %L)',
           (select e.id from public.enrollments e
             join public.students s on s.id = e.student_id
            where s.full_name = 'Science Child'), 'Arts'),
    'not found in this school'),
  '51. school B cannot set the stream on school A''s pupil');

rollback;
