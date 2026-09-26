-- =============================================================================
-- A result that holds still (0152).
--
-- Walked as the real logins: the owner, the principal, the class teacher of
-- 5 A (Sidra), the Maths teacher of 5 A only (Bilal) and a parent. Asserts:
--
--   * an exam term can be created, corrected and deleted only when empty, with
--     one name per year, dates in order and the withholding switch
--   * a blank box stores nothing and clears a mark that was there; re-saving an
--     unchanged sheet changes nothing; an absent pupil stores no marks
--   * a pupil who is not on the paper, and a pupil of another section, are
--     refused, by name where it helps
--   * releasing locks the class: marks (by the screen and by the table), papers
--     and remarks are all refused until the head withdraws the results
--   * a mark changed after the cards were made, or cleared, makes them out of
--     date, and release refuses until they are made again
--   * the parent sees the class teacher's remark with the released result
--   * the overview and the per-section progress count what the screens show
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/a_result_that_holds_still.sql
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
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 90);
    return;
  end;
  raise exception 'FAIL  % (it was ALLOWED)', p_label;
end;
$$;

create or replace function pg_temp.be(p_name text) returns void language sql as $$
  select set_config('test.uid',
    (select id::text from public.profiles where full_name = p_name), false);
$$;

-- --- Fixture -----------------------------------------------------------------
-- Class 5 with sections A (Nine A roll 9, Ten A roll 10) and B (One B roll 1),
-- Maths and English. Class 4 with one pupil, who is on no Class 5 paper.
do $seed$
declare
  v_school uuid;
  v_own uuid := '00000000-0000-0000-0000-0000000fd001';
  v_pr  uuid := '00000000-0000-0000-0000-0000000fd002';
  v_ct  uuid := '00000000-0000-0000-0000-0000000fd003';
  v_st  uuid := '00000000-0000-0000-0000-0000000fd004';
  v_par uuid := '00000000-0000-0000-0000-0000000fd005';
  v_sess uuid; v_c4 uuid; v_c5 uuid; v_5a uuid; v_5b uuid; v_maths uuid;
  v_stf_ct uuid; v_stf_st uuid; v_fam uuid; v_fam_p uuid; v_kid uuid;
begin
  insert into public.schools (name) values ('Holds Still School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own, 'own@hold.test'), (v_pr, 'pr@hold.test'), (v_ct, 'ct@hold.test'),
    (v_st, 'st@hold.test'), (v_par, 'par@hold.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own, 'Hold Owner',     'owner',           v_school),
    (v_pr,  'Hold Principal', 'principal',       v_school),
    (v_ct,  'Sidra Hold',     'class_teacher',   v_school),
    (v_st,  'Bilal Hold',     'subject_teacher', v_school),
    (v_par, 'Amna Parent',    'parent',          v_school)
    on conflict (id) do update set school_id = excluded.school_id, role = excluded.role,
                                   full_name = excluded.full_name, active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.school_settings (school_id, name) values (v_school, 'Holds Still School')
    on conflict (school_id) do update set name = excluded.name;
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2026-2027', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id) values ('Class 4', 4, v_school) returning id into v_c4;
  insert into public.classes (name, level_order, school_id) values ('Class 5', 5, v_school) returning id into v_c5;
  insert into public.sections (class_id, name, school_id) values (v_c5, 'A', v_school) returning id into v_5a;
  insert into public.sections (class_id, name, school_id) values (v_c5, 'B', v_school) returning id into v_5b;
  insert into public.subjects (name, class_id, school_id, sort_order) values ('Maths', v_c5, v_school, 1) returning id into v_maths;
  insert into public.subjects (name, class_id, school_id, sort_order) values ('English', v_c5, v_school, 2);

  insert into public.staff (full_name, designation, school_id) values ('Sidra Hold', 'Teacher', v_school) returning id into v_stf_ct;
  insert into public.staff (full_name, designation, school_id) values ('Bilal Hold', 'Teacher', v_school) returning id into v_stf_st;
  alter table public.profiles disable trigger user;
  update public.profiles set staff_id = v_stf_ct where id = v_ct;
  update public.profiles set staff_id = v_stf_st where id = v_st;
  alter table public.profiles enable trigger user;
  perform public.fn_set_class_teacher(v_stf_ct, v_sess, v_c5, v_5a);
  insert into public.subject_teachers (staff_id, session_id, class_id, section_id, subject_id, school_id)
    values (v_stf_st, v_sess, v_c5, v_5a, v_maths, v_school);

  insert into public.families (school_id, head_name) values (v_school, 'Others') returning id into v_fam;
  insert into public.families (school_id, head_name) values (v_school, 'Amna Parent') returning id into v_fam_p;
  insert into public.students (full_name, status, school_id, family_id) values ('Nine A', 'active', v_school, v_fam_p) returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, section_id, roll_no, status, school_id)
    values (v_kid, v_sess, v_c5, v_5a, '9', 'active', v_school);
  insert into public.students (full_name, status, school_id, family_id) values ('Ten A', 'active', v_school, v_fam) returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, section_id, roll_no, status, school_id)
    values (v_kid, v_sess, v_c5, v_5a, '10', 'active', v_school);
  insert into public.students (full_name, status, school_id, family_id) values ('One B', 'active', v_school, v_fam) returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, section_id, roll_no, status, school_id)
    values (v_kid, v_sess, v_c5, v_5b, '1', 'active', v_school);
  insert into public.students (full_name, status, school_id, family_id) values ('Four Kid', 'active', v_school, v_fam) returning id into v_kid;
  insert into public.enrollments (student_id, session_id, class_id, status, school_id)
    values (v_kid, v_sess, v_c4, 'active', v_school);

  perform public.fn_link_parent(v_par, v_fam_p);
  raise notice 'fixture ok';
end $seed$;

create or replace function pg_temp.school() returns uuid language sql stable as
  $$ select id from public.schools where name = 'Holds Still School' $$;
create or replace function pg_temp.sess() returns uuid language sql stable as
  $$ select id from public.academic_sessions where school_id = pg_temp.school() and name = '2026-2027' $$;
create or replace function pg_temp.c5() returns uuid language sql stable as
  $$ select id from public.classes where school_id = pg_temp.school() and name = 'Class 5' $$;
create or replace function pg_temp.enr(p_name text) returns uuid language sql stable as $$
  select e.id from public.enrollments e join public.students s on s.id = e.student_id
   where s.full_name = p_name and e.school_id = pg_temp.school() and e.session_id = pg_temp.sess()
$$;
create or replace function pg_temp.kid(p_name text) returns uuid language sql stable as
  $$ select id from public.students where full_name = p_name and school_id = pg_temp.school() $$;
create or replace function pg_temp.term() returns uuid language sql stable as
  $$ select id from public.exam_terms where school_id = pg_temp.school() and name like 'First Term%' $$;
create or replace function pg_temp.paper(p_subject text) returns uuid language sql stable as $$
  select es.id from public.exam_subjects es join public.subjects s on s.id = es.subject_id
   where es.exam_term_id = pg_temp.term() and s.name = p_subject
$$;
-- One marks row, as the screen sends it.
create or replace function pg_temp.m(p_name text, p_marks numeric, p_absent boolean default false)
returns jsonb language sql stable as $$
  select jsonb_build_object('enrollment_id', pg_temp.enr(p_name), 'marks', p_marks,
                            'practical_marks', null, 'is_absent', p_absent)
$$;
create or replace function pg_temp.mark_of(p_subject text, p_name text) returns public.mark_entries
language sql stable as $$
  select * from public.mark_entries where exam_subject_id = pg_temp.paper(p_subject)
     and enrollment_id = pg_temp.enr(p_name)
$$;

-- =============================================================================
-- 1-4. The exam term
-- =============================================================================
do $t$
declare v_id uuid;
begin
  perform pg_temp.be('Hold Owner');
  v_id := public.fn_save_exam_term(null, pg_temp.sess(), 'First Term', 'first', null, null, true);
  perform pg_temp.ok(v_id is not null, '1. the office creates First Term');
end $t$;

select pg_temp.raises(
  $$ select public.fn_save_exam_term(null, pg_temp.sess(), '  first term ', 'first', null, null, true) $$,
  '2a. a second term with the same name in the same year is refused', '%already has a term called%');
select pg_temp.raises(
  $$ select public.fn_save_exam_term(null, pg_temp.sess(), 'Mid Term', 'mid', '2026-10-10', '2026-10-01', true) $$,
  '2b. a term that ends before it starts is refused', '%cannot end before it starts%');
select pg_temp.raises(
  $$ select public.fn_save_exam_term(null, pg_temp.sess(), 'Mid Term', 'mid', '2026-10-10', null, true) $$,
  '2c. one date without the other is refused', '%both the start and the end date%');

do $t$
begin
  perform pg_temp.be('Hold Owner');
  perform public.fn_save_exam_term(pg_temp.term(), null, 'First Term 2026', 'first',
                                   '2026-10-01', '2026-10-10', false);
  perform pg_temp.ok(exists (select 1 from public.exam_terms where id = pg_temp.term()
                               and name = 'First Term 2026' and not result_withheld_for_defaulters
                               and starts_on = '2026-10-01'),
    '3. the term is renamed, dated, and its withholding switched off');
end $t$;

select pg_temp.be('Sidra Hold');
select pg_temp.raises(
  $$ select public.fn_save_exam_term(pg_temp.term(), null, 'Mine', 'first', null, null, true) $$,
  '4. a teacher cannot change an exam term', '%Not permitted%');

do $t$
begin
  perform pg_temp.be('Hold Owner');
  perform public.fn_upsert_exam_subject(pg_temp.term(), pg_temp.c5(),
    (select id from public.subjects where name = 'Maths' and school_id = pg_temp.school()), 100, 33, 0, null, null);
  perform public.fn_upsert_exam_subject(pg_temp.term(), pg_temp.c5(),
    (select id from public.subjects where name = 'English' and school_id = pg_temp.school()), 100, 33, 0, null, null);
end $t$;

-- =============================================================================
-- 5-9. A blank box is not a zero
-- =============================================================================
do $t$
declare j jsonb;
begin
  perform pg_temp.be('Hold Owner');
  j := public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(
         pg_temp.m('Nine A', 80), pg_temp.m('Ten A', null), pg_temp.m('One B', 50, true)), null);
  perform pg_temp.ok((pg_temp.mark_of('Maths', 'Ten A')).id is null,
    '5. a blank box stores no row, so it is not a zero');
  perform pg_temp.ok((pg_temp.mark_of('Maths', 'One B')).is_absent
                     and (pg_temp.mark_of('Maths', 'One B')).marks is null,
    '6. an absent pupil stores no marks beside the absence');
  perform pg_temp.ok((j->>'marked')::int = 2 and (j->>'cleared')::int = 0,
    '7. the save reports two saved and nothing cleared');
  perform pg_temp.ok(exists (select 1 from public.fn_result_readiness(pg_temp.term(), pg_temp.c5())
                              where problem = 'marks not entered' and detail = 'Maths: 1 pupil'),
    '8. the blank pupil is still on the "marks not entered" list');
end $t$;

do $t$
declare v_before timestamptz; j jsonb;
begin
  perform pg_temp.be('Hold Owner');
  v_before := (pg_temp.mark_of('Maths', 'Nine A')).changed_at;
  j := public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(
         pg_temp.m('Nine A', 80), pg_temp.m('Ten A', null), pg_temp.m('One B', null, true)), null);
  perform pg_temp.ok((j->>'written')::int = 0 and (pg_temp.mark_of('Maths', 'Nine A')).changed_at = v_before,
    '9a. saving the same sheet again changes nothing');
  j := public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(pg_temp.m('Nine A', null)), null);
  perform pg_temp.ok((j->>'cleared')::int = 1 and (pg_temp.mark_of('Maths', 'Nine A')).id is null,
    '9b. emptying a box clears the mark that was there');
  perform public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(pg_temp.m('Nine A', 80)), null);
end $t$;

-- =============================================================================
-- 10-14. Whose marks
-- =============================================================================
select pg_temp.be('Hold Owner');
select pg_temp.raises(
  $$ select public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(pg_temp.m('Four Kid', 40)), null) $$,
  '10. a pupil of another class is not on this paper and is refused', '%not on this paper%');

select pg_temp.be('Bilal Hold');
select pg_temp.raises(
  $$ select public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(pg_temp.m('One B', 40)), null) $$,
  '11. the Maths teacher of 5 A cannot mark a 5 B pupil', '%sections you teach%One B%');
do $t$
begin
  perform pg_temp.be('Bilal Hold');
  perform public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(pg_temp.m('Ten A', 70)), null);
  perform pg_temp.ok((pg_temp.mark_of('Maths', 'Ten A')).marks = 70,
    '12. but marks his own section''s pupil');
end $t$;
select pg_temp.raises(
  $$ select public.fn_enter_marks(pg_temp.paper('English'), jsonb_build_array(pg_temp.m('Ten A', 40)), null) $$,
  '13. and cannot enter English, which he does not teach', '%class and subject you teach%');

do $t$
begin
  perform pg_temp.be('Sidra Hold');
  perform public.fn_enter_marks(pg_temp.paper('English'), jsonb_build_array(
    pg_temp.m('Nine A', 66), pg_temp.m('Ten A', 55)), null);
  perform pg_temp.ok((pg_temp.mark_of('English', 'Nine A')).marks = 66,
    '14a. the class teacher of 5 A marks any subject for 5 A');
end $t$;
select pg_temp.be('Sidra Hold');
select pg_temp.raises(
  $$ select public.fn_enter_marks(pg_temp.paper('English'), jsonb_build_array(pg_temp.m('One B', 40)), null) $$,
  '14b. and not for 5 B', '%sections you teach%');

-- =============================================================================
-- 15-18. What the screens read
-- =============================================================================
do $t$
declare r record; v_a uuid; v_rows int;
begin
  perform pg_temp.be('Bilal Hold');
  select id into v_a from public.sections where name = 'A' and class_id = pg_temp.c5();
  select count(*) into v_rows from public.fn_exam_marksheet(pg_temp.paper('Maths')) x where x.section_id = v_a;
  perform pg_temp.ok(v_rows = 2, '15. the marksheet carries each pupil''s section, so a section''s teacher sees their own');

  select * into r from public.fn_exam_paper_progress(pg_temp.term(), pg_temp.c5()) p
   where p.exam_subject_id = pg_temp.paper('Maths') and p.section_id = v_a;
  perform pg_temp.ok(r.pupils = 2 and r.entered = 2, '16. Maths progress in 5 A: 2 of 2');
  select * into r from public.fn_exam_paper_progress(pg_temp.term(), pg_temp.c5()) p
   where p.exam_subject_id = pg_temp.paper('Maths') and p.section_id <> v_a;
  perform pg_temp.ok(r.pupils = 1 and r.entered = 1 and r.absent = 1, '17. Maths progress in 5 B: 1 of 1, absent');
end $t$;

do $t$
declare v_names text;
begin
  perform pg_temp.be('Hold Owner');
  perform public.fn_enter_marks(pg_temp.paper('English'), jsonb_build_array(pg_temp.m('One B', 60)), null);
  select string_agg(student_name, ',' order by ord) into v_names
    from (select student_name, row_number() over () as ord
            from public.fn_exam_remarks(pg_temp.term(), pg_temp.c5())) x;
  perform pg_temp.ok(v_names = 'Nine A,Ten A,One B',
    '18. the remark list runs by section, then roll 9 before roll 10');
end $t$;

-- =============================================================================
-- 19-22. Cards, the overview, and the remark
-- =============================================================================
-- The whole file is one transaction, so now() never moves. Time is put back by
-- hand: the marks were entered two hours ago and the cards made one hour ago,
-- so a change made "now" is after both, as it is on a real school day.
alter table public.mark_entries disable trigger trg_marks_changed_at;
update public.mark_entries set changed_at = changed_at - interval '2 hours'
 where school_id = pg_temp.school();
alter table public.mark_entries enable trigger trg_marks_changed_at;

do $t$
declare j jsonb; r record;
begin
  perform pg_temp.be('Hold Owner');
  j := public.fn_generate_result_cards(pg_temp.term(), pg_temp.c5(), false);
  update public.result_cards set generated_at = generated_at - interval '1 hour'
   where school_id = pg_temp.school();
  perform pg_temp.ok((j->>'generated')::int = 3 and not (j->>'provisional')::boolean,
    '19. every mark is in, so three complete cards');
  select * into r from public.fn_exam_term_overview(pg_temp.term()) o where o.class_id = pg_temp.c5();
  perform pg_temp.ok(r.papers = 2 and r.pupils = 3 and r.marks_expected = 6 and r.marks_entered = 6
                     and r.cards = 3 and r.released = 0 and r.out_of_date = 0,
    '20. the overview: 2 papers, 3 pupils, 6 of 6 marks, 3 cards, none released, none out of date');
end $t$;

do $t$
begin
  perform pg_temp.be('Sidra Hold');
  perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.kid('Nine A'), 'A bright and careful pupil.');
  perform pg_temp.ok(exists (select 1 from public.exam_remarks where student_id = pg_temp.kid('Nine A')),
    '21. the class teacher writes the remark');
end $t$;
select pg_temp.be('Bilal Hold');
select pg_temp.raises(
  $$ select public.fn_set_exam_remark(pg_temp.term(), pg_temp.kid('Ten A'), 'Good.') $$,
  '22. a subject teacher does not write the report-card remark', '%remark%');

-- =============================================================================
-- 23-31. Released means held
-- =============================================================================
do $t$
declare n int;
begin
  perform pg_temp.be('Hold Principal');
  n := public.fn_publish_results(pg_temp.term(), pg_temp.c5());
  perform pg_temp.ok(n = 3, '23. the principal releases three results');
  perform pg_temp.ok(not exists (select 1 from public.mark_entries me
                                   join public.exam_subjects es on es.id = me.exam_subject_id
                                  where es.exam_term_id = pg_temp.term() and not me.is_locked),
    '24. releasing locked every mark of the class');
  perform pg_temp.ok((select out_of_date from public.fn_exam_term_overview(pg_temp.term())
                       where class_id = pg_temp.c5()) = 0,
    '25. the lock is not a change: the cards are not out of date because of it');
end $t$;

select pg_temp.be('Hold Owner');
select pg_temp.raises(
  $$ select public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(pg_temp.m('Ten A', 90)), null) $$,
  '26. the marks screen refuses a released class', '%released to parents%');
select pg_temp.raises(
  $$ update public.mark_entries set marks = 99 where id = (pg_temp.mark_of('Maths', 'Nine A')).id $$,
  '27. and so does the table, whatever the path', '%released to parents%');
select pg_temp.raises(
  $$ select public.fn_upsert_exam_subject(pg_temp.term(), pg_temp.c5(),
       (select id from public.subjects where name = 'Maths' and school_id = pg_temp.school()), 75, 25, 0, null, null) $$,
  '28a. a released class''s paper cannot be changed', '%released to parents%');
select pg_temp.raises(
  $$ delete from public.exam_subjects where id = pg_temp.paper('Maths') $$,
  '28b. nor removed', '%released to parents%');
select pg_temp.be('Sidra Hold');
select pg_temp.raises(
  $$ select public.fn_set_exam_remark(pg_temp.term(), pg_temp.kid('Nine A'), 'Changed after release.') $$,
  '29. a released result''s remark cannot change', '%released to parents%');

do $t$
declare j jsonb; v_kid uuid := pg_temp.kid('Nine A');
begin
  perform pg_temp.be('Amna Parent');
  set local role authenticated;
  j := public.fn_portal_child_results(v_kid);
  reset role;
  perform pg_temp.ok(j->0->>'remark' = 'A bright and careful pupil.',
    '30. the parent sees the class teacher''s remark with the result');
end $t$;

select pg_temp.be('Hold Owner');
select pg_temp.raises(
  $$ select public.fn_delete_exam_term(pg_temp.term()) $$,
  '31. a term with result cards cannot be deleted', '%result card%');

-- =============================================================================
-- 32-37. Withdraw, correct, and the cards catch up
-- =============================================================================
do $t$
declare n int;
begin
  perform pg_temp.be('Hold Principal');
  n := public.fn_unpublish_results(pg_temp.term(), pg_temp.c5());
  perform pg_temp.ok(n = 3 and not exists (select 1 from public.mark_entries me
                                   join public.exam_subjects es on es.id = me.exam_subject_id
                                  where es.exam_term_id = pg_temp.term() and me.is_locked),
    '32. withdrawing unlocks every mark of the class');
  perform pg_temp.be('Hold Owner');
  perform public.fn_enter_marks(pg_temp.paper('Maths'), jsonb_build_array(pg_temp.m('Ten A', 75)),
                                're-totalled question 4');
  perform pg_temp.ok(exists (select 1 from public.fn_result_readiness(pg_temp.term(), pg_temp.c5())
                              where problem = 'cards out of date' and affected = 1),
    '33. a mark changed after the cards makes them out of date, for that one pupil');
  perform pg_temp.ok((pg_temp.mark_of('Maths', 'Ten A')).corrected_from = 70
                     and (pg_temp.mark_of('Maths', 'Ten A')).correction_reason = 're-totalled question 4',
    '34. the change is recorded as a correction, with its reason');
end $t$;

select pg_temp.be('Hold Principal');
select pg_temp.raises(
  $$ select public.fn_publish_results(pg_temp.term(), pg_temp.c5()) $$,
  '35. release refuses cards that no longer match the marks', '%changed for 1 pupil%');

do $t$
declare n int;
begin
  perform pg_temp.be('Hold Owner');
  perform public.fn_generate_result_cards(pg_temp.term(), pg_temp.c5(), false);
  perform pg_temp.be('Hold Principal');
  n := public.fn_publish_results(pg_temp.term(), pg_temp.c5());
  perform pg_temp.ok(n = 3, '36. made again, they release');

  -- A mark cleared after the cards: nothing has a newer changed_at, and the
  -- count of marked papers is what gives it away.
  perform public.fn_unpublish_results(pg_temp.term(), pg_temp.c5());
  perform pg_temp.be('Hold Owner');
  perform public.fn_enter_marks(pg_temp.paper('English'), jsonb_build_array(pg_temp.m('One B', null)), null);
  perform pg_temp.ok(exists (select 1 from public.fn_result_readiness(pg_temp.term(), pg_temp.c5())
                              where problem = 'cards out of date' and affected = 1),
    '37. a mark cleared after the cards makes them out of date too');
end $t$;

-- =============================================================================
-- 38-39. An empty term goes; a term with marks does not
-- =============================================================================
do $t$
declare v_id uuid;
begin
  perform pg_temp.be('Hold Owner');
  v_id := public.fn_save_exam_term(null, pg_temp.sess(), 'Spare Term', 'other', null, null, true);
  perform public.fn_delete_exam_term(v_id);
  perform pg_temp.ok(not exists (select 1 from public.exam_terms where id = v_id),
    '38. an empty term can be deleted');

  v_id := public.fn_save_exam_term(null, pg_temp.sess(), 'Mid Term', 'mid', null, null, true);
  perform public.fn_upsert_exam_subject(v_id, pg_temp.c5(),
    (select id from public.subjects where name = 'Maths' and school_id = pg_temp.school()), 50, 17, 0, null, null);
  perform public.fn_enter_marks(
    (select id from public.exam_subjects where exam_term_id = v_id),
    jsonb_build_array(pg_temp.m('Nine A', 40)), null);
  begin
    perform public.fn_delete_exam_term(v_id);
    raise exception 'FAIL  39. a term with marks in it was deleted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    perform pg_temp.ok(sqlerrm like '%mark(s) entered%', '39. a term with marks in it cannot be deleted');
  end;
end $t$;

select 'ALL RESULT-THAT-HOLDS-STILL ASSERTIONS PASSED' as result;
rollback;
