-- =============================================================================
-- Teacher remarks and position holders.
--
-- The rules this file defends:
--
--  1. A REMARK SURVIVES REGENERATION. This is the reason exam_remarks is its own
--     table rather than a column on result_cards: fn_generate_result_cards does
--     not update rows, it INSERTS a new one with version + 1. A remark on a
--     result card would silently vanish from the printed report the moment
--     anybody regenerated the class, and the teacher would never know.
--  2. TIES SHARE A POSITION, and every tied child is listed. Two children on
--     90% are both first and the next is THIRD — there is no second place. Any
--     other behaviour hands one child a prize and not the other on a coin toss.
--  3. ONLY THE LATEST VERSION COUNTS. Ranking one student's old total against
--     another's new one is the sort of error nobody notices until prize day.
--  4. A child with NO MARK ENTERED is not a position holder — and `percentage`
--     cannot be the test, because fn_generate_result_cards coalesces the mark
--     sum to 0, so "never marked" and "sat and scored nothing" both come out as
--     0.00. In a small class that would put a child with no marks to their name
--     inside the top three. A child who WAS marked and scored zero stays in the
--     ranking, because they are genuinely part of the order.
--  5. THE CLASS TEACHER writes the remark. A subject teacher assigned to the
--     same class may not: they see one subject, and the remark is a judgement
--     about the whole child.
--  6. A withheld result is FLAGGED, so a school does not announce a prize for a
--     child whose result is being held back over unpaid fees.
--  7. The remark sheet lists EVERY child in the class, not only those already
--     written, or a teacher cannot find who is left.
--  8. Nothing crosses a school boundary.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/remarks_positions.sql
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

create or replace function pg_temp.term() returns uuid language sql as $$
  select id from public.exam_terms
   where school_id = public.current_school_id() and name = 'Final' limit 1
$$;
create or replace function pg_temp.cls() returns uuid language sql as $$
  select id from public.classes
   where school_id = public.current_school_id() and name = 'Class 10' limit 1
$$;
create or replace function pg_temp.stu(p_name text) returns uuid language sql as $$
  select id from public.students
   where school_id = public.current_school_id() and full_name = p_name
$$;

-- --- Fixture -----------------------------------------------------------------
-- One class of four, marked so that two tie on 90, then 80, then 70. A fifth
-- child is admitted with NO marks at all. One class teacher and one subject
-- teacher are both assigned to the class, which is what makes assertion 5
-- meaningful — fn_may_manage_class is true for both.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000fa01';
  v_ct uuid := '00000000-0000-0000-0000-00000000fa02';
  v_st uuid := '00000000-0000-0000-0000-00000000fa03';
  v_pa uuid := '00000000-0000-0000-0000-00000000fa04';
  v_ob uuid := '00000000-0000-0000-0000-00000000fa05';
  v_sess uuid; v_cl uuid; v_subj uuid; v_term uuid; v_es uuid;
  v_staff_ct uuid; v_staff_st uuid; v_marks jsonb;
  v_sess_b uuid; v_cl_b uuid;
begin
  insert into public.schools (name) values ('Pos A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Pos B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa,'pa@pos.test'), (v_ct,'pct@pos.test'), (v_st,'pst@pos.test'),
    (v_pa,'ppa@pos.test'), (v_ob,'pb@pos.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Pos Owner',    'owner',           v_a),
    (v_ct, 'Pos ClassT',   'class_teacher',   v_a),
    (v_st, 'Pos SubjT',    'subject_teacher', v_a),
    (v_pa, 'Pos Parent',   'parent',          v_a),
    (v_ob, 'Pos Other',    'owner',           v_b)
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
    values ('Class 10', 10, v_a) returning id into v_cl;
  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('Maths', v_cl, 1, v_a) returning id into v_subj;
  insert into public.exam_terms (session_id, name, term_type, school_id)
    values (v_sess, 'Final', 'final', v_a) returning id into v_term;
  insert into public.exam_subjects (exam_term_id, class_id, subject_id, max_marks, school_id)
    values (v_term, v_cl, v_subj, 100, v_a) returning id into v_es;

  -- Both teachers assigned to the same class, and linked to their profiles the
  -- way fn_may_manage_class requires (profiles.staff_id -> staff.id).
  insert into public.staff (full_name, designation, school_id)
    values ('Class Teacher Sahib', 'Class Teacher', v_a) returning id into v_staff_ct;
  insert into public.staff (full_name, designation, school_id)
    values ('Subject Teacher Sahib', 'Subject Teacher', v_a) returning id into v_staff_st;
  alter table public.profiles disable trigger user;
  update public.profiles set staff_id = v_staff_ct where id = v_ct;
  update public.profiles set staff_id = v_staff_st where id = v_st;
  alter table public.profiles enable trigger user;
  insert into public.teacher_assignments (staff_id, session_id, class_id, school_id)
    values (v_staff_ct, v_sess, v_cl, v_a), (v_staff_st, v_sess, v_cl, v_a);

  perform public.fn_admit_student(jsonb_build_object('full_name','Tie One','father_name','F1',
    'father_cnic','35201-4000001-1','session_id',v_sess,'class_id',v_cl,'roll_no','1','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object('full_name','Tie Two','father_name','F2',
    'father_cnic','35201-4000002-2','session_id',v_sess,'class_id',v_cl,'roll_no','2','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object('full_name','Third Kid','father_name','F3',
    'father_cnic','35201-4000003-3','session_id',v_sess,'class_id',v_cl,'roll_no','3','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object('full_name','Fourth Kid','father_name','F4',
    'father_cnic','35201-4000004-4','session_id',v_sess,'class_id',v_cl,'roll_no','4','links','[]'::jsonb));
  -- No marks will be entered for this one.
  perform public.fn_admit_student(jsonb_build_object('full_name','Unmarked Kid','father_name','F5',
    'father_cnic','35201-4000005-5','session_id',v_sess,'class_id',v_cl,'roll_no','5','links','[]'::jsonb));

  select jsonb_agg(jsonb_build_object('enrollment_id', e.id, 'marks',
           case s.full_name when 'Tie One' then 90 when 'Tie Two' then 90
                            when 'Third Kid' then 80 when 'Fourth Kid' then 70 end))
    into v_marks
  from public.enrollments e join public.students s on s.id = e.student_id
  where e.school_id = v_a and s.full_name <> 'Unmarked Kid';

  perform public.fn_enter_marks(v_es, v_marks);
  -- allow_incomplete, on purpose: this fixture deliberately keeps a child with
  -- no marks at all, which is what assertion 9 is about. Since 0058 the
  -- generator REFUSES an incomplete class by default, so the override is how
  -- this suite says "yes, I know, that is the case under test".
  perform public.fn_generate_result_cards(v_term, v_cl, true);

  -- School B, for isolation.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('Class 10', 10, v_b) returning id into v_cl_b;

  perform set_config('test.uid', v_oa::text, false);
end;
$seed$;

-- =============================================================================
-- 1. Ties — the rule a prize distribution turns on
-- =============================================================================
do $$
declare v_n int; r record;
begin
  select count(*) into v_n from public.fn_position_holders(pg_temp.term(), 3);
  perform pg_temp.ok(v_n = 3,
    '1  top three returns three children, not four, despite the tie for first');

  perform pg_temp.ok(
    (select count(*) from public.fn_position_holders(pg_temp.term(), 3)
      where class_position = 1) = 2,
    '2  BOTH children on 90% are first — neither is dropped on a tie-break');

  perform pg_temp.ok(
    not exists (select 1 from public.fn_position_holders(pg_temp.term(), 3)
                 where class_position = 2),
    '3  there is no second place after a two-way tie for first');

  select * into r from public.fn_position_holders(pg_temp.term(), 3)
   where student_name = 'Third Kid';
  perform pg_temp.ok(r.class_position = 3,
    '4  the next child down is THIRD, which is what rank() means');
  perform pg_temp.ok(r.tied_with = 1,
    '5  and tied_with says they are alone at that position');

  perform pg_temp.ok(
    (select tied_with from public.fn_position_holders(pg_temp.term(), 3)
      where student_name = 'Tie One') = 2,
    '6  a tied child reports how many share the position, for the notice board');
end $$;

-- The cutoff, and a child with no marks at all.
do $$
begin
  perform pg_temp.ok(
    not exists (select 1 from public.fn_position_holders(pg_temp.term(), 3)
                 where student_name = 'Fourth Kid'),
    '7  the fourth-placed child is outside the top three');
  perform pg_temp.ok(
    exists (select 1 from public.fn_position_holders(pg_temp.term(), 4)
             where student_name = 'Fourth Kid'),
    '8  ...and inside the top four when asked for four');

  -- Before 0058 an unmarked child scored 0.00, NOT null: the generator coalesced
  -- the mark sum to zero, so "never entered" and "sat and scored nothing" were
  -- indistinguishable in `percentage` and in a small class the unmarked child
  -- landed inside the top three. fn_position_holders worked around it by asking
  -- whether any mark row exists.
  --
  -- 0058 fixed it at the source: an unmarked pupil now has NO percentage and NO
  -- position, and the card says it is provisional. The assertion is inverted
  -- rather than deleted, because the workaround in fn_position_holders is still
  -- there and this is what proves it is no longer load-bearing.
  perform pg_temp.ok(
    (select percentage from public.result_cards rc
      join public.students s2 on s2.id = rc.student_id
      where s2.full_name = 'Unmarked Kid' order by rc.version desc limit 1) is null,
    '9  an unmarked child now has NO percentage at all — 0.00 was the old defect, and '
    || 'it printed a child nobody had marked as having failed');
  perform pg_temp.ok(
    (select (frozen->>'provisional')::boolean from public.result_cards rc
      join public.students s2 on s2.id = rc.student_id
      where s2.full_name = 'Unmarked Kid' order by rc.version desc limit 1),
    '9a and their card says it is provisional');
  perform pg_temp.ok(
    not exists (select 1 from public.fn_position_holders(pg_temp.term(), 99)
                 where student_name = 'Unmarked Kid'),
    '9b a child with no mark entered is never a position holder, at any depth');
  perform pg_temp.ok(
    exists (select 1 from public.fn_position_holders(pg_temp.term(), 99)
             where student_name = 'Fourth Kid'),
    '9c ...while a child who was marked stays in the ranking');
end $$;

-- =============================================================================
-- 2. THE ONE THE TABLE DESIGN EXISTS FOR — a remark survives regeneration
-- =============================================================================
do $$
declare v_versions int;
begin
  perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.stu('Tie One'),
    'Outstanding throughout the year.');
  perform pg_temp.ok(
    (select remark from public.fn_position_holders(pg_temp.term(), 3)
      where student_name = 'Tie One') = 'Outstanding throughout the year.',
    '10 the remark is written and reaches the position-holders view');

  -- Regenerate. fn_generate_result_cards INSERTS a new version rather than
  -- updating, which is exactly why a remark stored on result_cards would be
  -- lost here without anybody noticing.
  perform public.fn_generate_result_cards(pg_temp.term(), pg_temp.cls(), true);
  select count(distinct version) into v_versions from public.result_cards
   where exam_term_id = pg_temp.term();
  perform pg_temp.ok(v_versions = 2,
    '11 regenerating really does make a second version (the risk is real)');

  perform pg_temp.ok(
    (select remark from public.fn_position_holders(pg_temp.term(), 3)
      where student_name = 'Tie One') = 'Outstanding throughout the year.',
    '12 ...and the remark survives it, because it is not stored on the card');
end $$;

-- Only the latest version is ranked, so regeneration must not duplicate anybody.
do $$
begin
  perform pg_temp.ok(
    (select count(*) from public.fn_position_holders(pg_temp.term(), 99)) = 4,
    '13 two versions do not produce two rows per child — only the latest counts');
  perform pg_temp.ok(
    (select count(*) from (
       select student_name from public.fn_position_holders(pg_temp.term(), 99)
       group by student_name having count(*) > 1) d) = 0,
    '14 ...and no child appears twice');
end $$;

-- =============================================================================
-- 3. The remark sheet a teacher fills in
-- =============================================================================
do $$
declare v_n int; r record;
begin
  select count(*) into v_n from public.fn_exam_remarks(pg_temp.term(), pg_temp.cls());
  perform pg_temp.ok(v_n = 5,
    '15 the sheet lists EVERY child in the class, not only those with remarks');

  select * into r from public.fn_exam_remarks(pg_temp.term(), pg_temp.cls())
   where student_name = 'Tie One';
  perform pg_temp.ok(r.remark = 'Outstanding throughout the year.'
                 and r.remark_by_name = 'Pos Owner',
    '16 with the remark and who wrote it — the first question when one is disputed');
  perform pg_temp.ok(r.percentage = 90.00 and r.class_position = 1,
    '17 and the child''s own result beside it, so the remark is not written blind');

  perform pg_temp.ok(
    (select remark from public.fn_exam_remarks(pg_temp.term(), pg_temp.cls())
      where student_name = 'Unmarked Kid') is null,
    '18 a child with no remark appears with a blank one, not omitted');
end $$;

-- Blank means remove, rather than storing an empty string that prints as a gap.
do $$
begin
  perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.stu('Tie One'), '   ');
  perform pg_temp.ok(
    (select count(*) from public.exam_remarks
      where student_id = pg_temp.stu('Tie One')) = 0,
    '19 a blank remark removes the row rather than storing an empty string');

  perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.stu('Tie One'), 'Restored.');
  perform pg_temp.ok(
    (select remark from public.exam_remarks
      where student_id = pg_temp.stu('Tie One')) = 'Restored.',
    '20 and writing again re-creates it, rather than failing on the unique key');
end $$;

-- =============================================================================
-- 4. Who may write the remark
-- =============================================================================
do $$
begin
  -- The class teacher: yes. This is their remark.
  perform pg_temp.be('Pos ClassT');
  perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.stu('Tie Two'),
    'Much improved this term.');
  raise notice 'PASS  21 the class teacher may write a remark for their own class';

  -- The subject teacher is assigned to the SAME class, so fn_may_manage_class
  -- returns true for them. The role check is what stops them, and that is the
  -- point of testing it here rather than trusting the scope check.
  perform pg_temp.be('Pos SubjT');
  begin
    perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.stu('Third Kid'), 'Sneaky');
    raise exception 'FAIL  22 a subject teacher wrote a report-card remark';
  exception when insufficient_privilege then
    raise notice 'PASS  22 a subject teacher on the same class is still refused';
  end;

  perform pg_temp.be('Pos Parent');
  begin
    perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.stu('Third Kid'), 'Nope');
    raise exception 'FAIL  23 a parent wrote a remark';
  exception when insufficient_privilege then
    raise notice 'PASS  23 a parent cannot write a remark';
  end;
  begin
    perform public.fn_position_holders(pg_temp.term(), 3);
    raise exception 'FAIL  24 a parent read the position holders';
  exception when insufficient_privilege then
    raise notice 'PASS  24 nor read the position holders';
  end;

  perform pg_temp.be('Pos Owner');
end $$;

-- A locked term is a published result: changing the remark afterwards changes
-- what a parent was already shown.
do $$
begin
  update public.exam_terms set is_locked = true where id = pg_temp.term();
  begin
    perform public.fn_set_exam_remark(pg_temp.term(), pg_temp.stu('Tie One'), 'Too late');
    raise exception 'FAIL  25 a remark was changed on a locked term';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  25 a locked exam term refuses remark changes';
  end;
  update public.exam_terms set is_locked = false where id = pg_temp.term();
end $$;

-- =============================================================================
-- 5. Withheld results are flagged before the prize is announced
-- =============================================================================
do $$
declare v_flagged int;
begin
  -- Withhold for defaulters, bill the class, and regenerate so the frozen
  -- snapshot carries the flag.
  update public.exam_terms set result_withheld_for_defaulters = true
   where id = pg_temp.term();

  -- Give the top child a debt through the ordinary billing path.
  insert into public.adjustments (student_id, amount, reason, created_by, school_id)
  values (pg_temp.stu('Tie One'), 5000, 'unpaid dues',
          (select id from public.profiles where full_name = 'Pos Owner'),
          public.current_school_id());

  perform public.fn_generate_result_cards(pg_temp.term(), pg_temp.cls(), true);

  select count(*) into v_flagged from public.fn_position_holders(pg_temp.term(), 3)
   where withheld;
  perform pg_temp.ok(v_flagged = 1,
    '26 a position holder whose result is withheld over fees is flagged as such');
  perform pg_temp.ok(
    (select withheld from public.fn_position_holders(pg_temp.term(), 3)
      where student_name = 'Tie Two') = false,
    '27 ...and a child who owes nothing is not');
end $$;

-- =============================================================================
-- 6. Tenant isolation
-- =============================================================================
do $$
declare v_term_a uuid; v_stu_a uuid;
begin
  v_term_a := pg_temp.term();
  v_stu_a  := pg_temp.stu('Tie One');

  perform pg_temp.be('Pos Other');
  begin
    perform public.fn_position_holders(v_term_a, 3);
    raise exception 'FAIL  28 school B read school A''s position holders';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  28 school B cannot read school A''s position holders';
  end;
  begin
    perform public.fn_set_exam_remark(v_term_a, v_stu_a, 'Injected');
    raise exception 'FAIL  29 school B wrote a remark on school A''s student';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  29 school B cannot write a remark on school A''s student';
  end;
  perform pg_temp.ok(
    (select count(*) from public.exam_remarks
      where school_id = public.current_school_id()) = 0,
    '30 school B''s own remark table is empty');

  perform pg_temp.be('Pos Owner');
end $$;

rollback;
