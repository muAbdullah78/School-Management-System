-- =============================================================================
-- The grade scale a school chooses
--
-- THE DEFECT THIS FILE EXISTS FOR. Settings → School profile offers "GPA
-- (10-point)" and `fn_grade_for` never read `school_settings.grade_scale` at
-- all — it always returned A+/A/B/C/D/E/F. A school selected GPA, the form said
-- "Saved.", and every result card, per-subject grade, tabulation sheet and
-- portal reading went on printing letters with no warning anywhere.
--
-- The rules defended here:
--
--   1. Under `letter` nothing moves. An existing school upgrading must see
--      exactly the grades it saw yesterday — this is asserted FIRST, because a
--      new feature that quietly re-grades a term is worse than the gap it fixes.
--   2. Under `gpa10` a paper gets a grade POINT, on the same cut points as the
--      letter scale, so switching is a translation rather than a re-grading.
--   3. THE ONE THAT MATTERS: the card's overall figure is the MEAN of the
--      papers' points, not the band of the aggregate. Two pupils on the same
--      aggregate with different distributions must get different GPAs, because
--      that difference is the entire reason a GPA exists.
--   4. Below the school's own pass mark is 0, matching the letter scale's F.
--   5. An unmarked paper is excluded from the mean, never counted as zero —
--      the rule 0058 established after one coalesce printed two A+ pupils as a
--      C and a D.
--   6. The scale is FROZEN onto the card, so a card issued under one scale still
--      prints that scale after the school switches.
--   7. The setting cannot hold a scale nothing implements.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/grade_scale.sql
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

create or replace function pg_temp.raises(p_sql text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 66);
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

-- The overall figure on a pupil's latest card.
create or replace function pg_temp.card(p_name text) returns text
language sql stable as $$
  select rc.grade
  from public.result_cards rc
  join public.students s on s.id = rc.student_id
  where s.full_name = p_name
  order by rc.version desc
  limit 1;
$$;

-- One paper's grade off the frozen snapshot.
create or replace function pg_temp.paper(p_name text, p_subject text) returns text
language sql stable as $$
  select x.g
  from public.result_cards rc
  join public.students s on s.id = rc.student_id
  cross join lateral (
    select sub->>'grade' as g
    from jsonb_array_elements(rc.frozen->'subjects') sub
    where sub->>'subject' = p_subject
  ) x
  where s.full_name = p_name
  order by rc.version desc
  limit 1;
$$;

-- --- Fixture -----------------------------------------------------------------
-- One class, four papers of 100 each, three pupils. The two that matter carry
-- the SAME aggregate — 280/400 = 70% — with different distributions, which is
-- the whole argument for computing a mean rather than banding the total.
--
--   Even Aisha   70, 70, 70, 70   → points 8, 8, 8, 8   → GPA 8.0
--   Spiky Bilal  95, 95, 45, 45   → points 10, 10, 5, 5 → GPA 7.5
--   Failing Dawood 20, 20, 20, 20 → points 0, 0, 0, 0   → GPA 0.0
do $seed$
declare
  v_school uuid;
  v_owner uuid := '00000000-0000-0000-0000-00000000cc01';
  v_sess uuid; v_class uuid; v_sec uuid; v_term uuid;
  v_names text[] := array['Even Aisha', 'Spiky Bilal', 'Failing Dawood'];
  v_marks int[][] := array[array[70,70,70,70], array[95,95,45,45], array[20,20,20,20]];
  v_papers text[] := array['English', 'Urdu', 'Maths', 'Science'];
  v_sub uuid; v_es uuid; v_stu uuid; v_enr uuid; v_fam uuid;
  i int; j int;
  v_es_ids uuid[] := '{}';
begin
  perform set_config('test.uid', '', false);
  insert into public.schools (name) values ('Grade Scale School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_owner, 'o@grades.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id)
    values (v_owner, 'Grades Owner', 'owner', v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);
  -- pass_percent 33, the Pakistani default, so 20% is a fail and 45% is not.
  insert into public.school_settings (school_id, name, pass_percent, grade_scale)
    values (v_school, 'Grade Scale School', 33, 'letter')
    on conflict (school_id) do update set pass_percent = 33, grade_scale = 'letter';

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 9', 9, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.exam_terms (school_id, session_id, name)
    values (v_school, v_sess, 'Term 1') returning id into v_term;

  for j in 1..4 loop
    insert into public.subjects (school_id, name, sort_order)
      values (v_school, v_papers[j], j) returning id into v_sub;
    insert into public.exam_subjects (school_id, exam_term_id, class_id, subject_id,
                                      max_marks, pass_marks)
      values (v_school, v_term, v_class, v_sub, 100, 33) returning id into v_es;
    v_es_ids := v_es_ids || v_es;
  end loop;

  for i in 1..3 loop
    insert into public.families (school_id, head_name)
      values (v_school, v_names[i] || ' Parent') returning id into v_fam;
    insert into public.students (full_name, father_name, status, school_id, family_id)
      values (v_names[i], v_names[i] || ' Parent', 'active', v_school, v_fam)
      returning id into v_stu;
    insert into public.enrollments (student_id, session_id, class_id, section_id,
                                    status, school_id)
      values (v_stu, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;
    for j in 1..4 loop
      insert into public.mark_entries (school_id, exam_subject_id, enrollment_id,
                                       marks, max_marks)
        values (v_school, v_es_ids[j], v_enr, v_marks[i][j], 100);
    end loop;
  end loop;

  create table public._gs (k text primary key, v uuid);
  insert into public._gs values ('school', v_school), ('term', v_term),
                                ('class', v_class), ('sess', v_sess),
                                ('es1', v_es_ids[1]);
  raise notice 'fixture: two pupils on 280/400, distributed differently';
end $seed$;

-- =============================================================================
-- 1. Under `letter`, nothing has moved
-- =============================================================================
select public.fn_generate_result_cards(
  (select v from public._gs where k = 'term'),
  (select v from public._gs where k = 'class'), false);

select pg_temp.ok(pg_temp.card('Even Aisha') = 'B',
  '1. 70% is still a B under the letter scale — an upgrade must not re-grade a term');
select pg_temp.ok(pg_temp.card('Spiky Bilal') = 'B',
  '2. and so is the pupil with the same aggregate, which is exactly what the '
  || 'letter scale is for and exactly what a GPA is not');
select pg_temp.ok(pg_temp.card('Failing Dawood') = 'F',
  '3. 20% is an F, below the school''s pass mark of 33');
select pg_temp.ok(pg_temp.paper('Spiky Bilal', 'English') = 'A+',
  '4. and the per-subject grades are letters too — 95 is an A+');

-- =============================================================================
-- 2. Switch to gpa10. THE ASSERTION THIS FILE IS FOR.
-- =============================================================================
update public.school_settings set grade_scale = 'gpa10'
 where school_id = (select v from public._gs where k = 'school');

select pg_temp.ok(public.fn_grade_for(95) = '10' and public.fn_grade_for(70) = '8'
                  and public.fn_grade_for(45) = '5' and public.fn_grade_for(20) = '0',
  '5. fn_grade_for finally reads the setting: 95→10, 70→8, 45→5, 20→0 (below pass)');

select public.fn_generate_result_cards(
  (select v from public._gs where k = 'term'),
  (select v from public._gs where k = 'class'), false);

select pg_temp.ok(pg_temp.card('Even Aisha') = '8.0',
  '6. four papers at 70 give a GPA of 8.0');

select pg_temp.ok(pg_temp.card('Spiky Bilal') = '7.5',
  '7. THE ONE THAT MATTERS: the same 280/400 aggregate, distributed 95/95/45/45, '
  || 'gives 7.5 and not 8.0. Banding the aggregate would have returned 8.0 for '
  || 'both and discarded the only thing a GPA carries');

select pg_temp.ok(pg_temp.card('Failing Dawood') = '0.0',
  '8. four papers below the pass mark give 0.0, matching the letter scale''s F');

select pg_temp.ok(pg_temp.paper('Spiky Bilal', 'English') = '10'
                  and pg_temp.paper('Spiky Bilal', 'Maths') = '5',
  '9. per-paper grade points: 95→10 and 45→5 on the same card');

select pg_temp.ok(
  (select (frozen->>'percentage')::numeric from public.result_cards rc
    join public.students s on s.id = rc.student_id
   where s.full_name = 'Spiky Bilal' order by rc.version desc limit 1) = 70,
  '10. and the percentage is untouched — the scale changes the grade, not the marks');

-- =============================================================================
-- 3. The scale travels with the card
-- =============================================================================
select pg_temp.ok(
  (select frozen->>'grade_scale' from public.result_cards rc
    join public.students s on s.id = rc.student_id
   where s.full_name = 'Even Aisha' order by rc.version desc limit 1) = 'gpa10',
  '11. the card records which scale produced it');

do $frozen$
declare v_old text;
begin
  -- The FIRST card, generated while the school was on letters, must still say
  -- letters. Without the frozen scale the print label on every card ever issued
  -- would flip the moment somebody changed a dropdown.
  select rc.frozen->>'grade_scale' into v_old
  from public.result_cards rc
  join public.students s on s.id = rc.student_id
  where s.full_name = 'Even Aisha'
  order by rc.version asc limit 1;
  if coalesce(v_old, 'letter') <> 'letter' then
    raise exception 'FAIL  12. the earlier card now claims to be %', v_old;
  end if;
  raise notice 'PASS  12. and version 1, issued under letters, still says letter — '
    'so a reprint agrees with the paper the family is holding';
end $frozen$;

-- =============================================================================
-- 4. An unmarked paper is excluded from the mean, not counted as zero
-- =============================================================================
do $unmarked$
declare v_gpa text;
begin
  -- Delete one of Aisha's four marks and generate a PROVISIONAL card. Three
  -- papers at 70 is still 8.0. Counting the missing paper as zero would give
  -- (8+8+8+0)/4 = 6.0 and print a good pupil as mediocre.
  delete from public.mark_entries me
   using public.enrollments e, public.students s
   where me.enrollment_id = e.id and s.id = e.student_id
     and s.full_name = 'Even Aisha'
     and me.exam_subject_id = (select v from public._gs where k = 'es1');

  perform public.fn_generate_result_cards(
    (select v from public._gs where k = 'term'),
    (select v from public._gs where k = 'class'), true);

  v_gpa := pg_temp.card('Even Aisha');
  if v_gpa <> '8.0' then
    raise exception
      'FAIL  13. a provisional card gives GPA % — an unmarked paper is being '
      'counted as a zero, which is the 0058 defect wearing a GPA', v_gpa;
  end if;
  raise notice 'PASS  13. a provisional card averages the MARKED papers — 8.0, not 6.0';
end $unmarked$;

select pg_temp.ok(
  (select (frozen->>'provisional')::boolean from public.result_cards rc
    join public.students s on s.id = rc.student_id
   where s.full_name = 'Even Aisha' order by rc.version desc limit 1),
  '14. and it says PROVISIONAL, so nobody mistakes it for the final figure');

-- =============================================================================
-- 5. The setting cannot hold a scale nothing implements
-- =============================================================================
select pg_temp.raises(
  format('update public.school_settings set grade_scale = ''percentage'' '
         || 'where school_id = %L', (select v from public._gs where k = 'school')),
  '15. a scale no function implements is refused — a third dropdown option '
  || 'added without a branch in fn_grade_for would silently fall through to '
  || 'letters, which is this whole defect arriving again by another route');

select pg_temp.ok(
  (select grade_scale from public.school_settings
    where school_id = (select v from public._gs where k = 'school')) = 'gpa10',
  '16. and the refusal left the school''s setting alone');

rollback;
