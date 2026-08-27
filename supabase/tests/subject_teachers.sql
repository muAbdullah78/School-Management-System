-- =============================================================================
-- Who may write a mark?
--
-- THE DEFECT THIS FILE EXISTS FOR. fn_enter_marks — the function that writes the
-- marks printed on the result card, the certificate and the tabulation sheet —
-- had no class scope at all. Its only gate was has_role, so any class_teacher or
-- subject_teacher in the school could enter or overwrite ANY class's exam marks
-- in ANY subject. Its sibling fn_enter_assessment_marks, which writes the weekly
-- test marks nobody keeps, HAS been class-scoped since 0048.
--
-- That asymmetry is the whole point: the guarded path was the one that did not
-- matter. Found by comparing the two functions, not by reading either.
--
-- The rules defended here:
--
--   1. The office (owner / principal / admin_clerk) may mark anything.
--   2. A class teacher may mark every subject OF THEIR OWN CLASS — a school has
--      to be able to finish a card when a colleague is away.
--   3. A class teacher may NOT mark another class. This is the hole.
--   4. A subject teacher may mark their own class+subject.
--   5. A subject teacher may NOT mark a different SUBJECT of the same class.
--   6. A teacher with no assignment at all may mark nothing, and is told which
--      screen fixes it.
--   7. The same rule governs assessment marks, so the two paths cannot drift.
--   8. THE DIRECT TABLE, not just the function: a teacher with the anon key can
--      POST at /rest/v1/mark_entries, so RLS must carry the same rule.
--   9. Nothing crosses a school boundary — neither the register nor the check.
--  10. The register itself: replace-set semantics, a subject that belongs to
--      another class refused, and the empty rows returned because they are the
--      work list.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/subject_teachers.sql
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

-- Did that statement refuse? Used for every negative case, because "it did not
-- write" and "it refused" are different facts and only the second is a boundary.
create or replace function pg_temp.raises(p_sql text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'PASS  % (refused: %)', p_label, left(sqlerrm, 70);
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

-- --- Fixture -----------------------------------------------------------------
-- Two classes so "another class" is testable, two subjects in one of them so
-- "another subject" is too, and a second school for isolation.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_own uuid := '00000000-0000-0000-0000-00000005b001';
  v_ct  uuid := '00000000-0000-0000-0000-00000005b002';
  v_st  uuid := '00000000-0000-0000-0000-00000005b003';
  v_no  uuid := '00000000-0000-0000-0000-00000005b004';
  v_ob  uuid := '00000000-0000-0000-0000-00000005b005';
  v_sess uuid; v_c9 uuid; v_c10 uuid; v_sec9 uuid;
  v_phy uuid; v_isl uuid; v_c10sub uuid;
  v_term uuid; v_es_phy uuid; v_es_isl uuid; v_es_c10 uuid;
  v_asmt uuid;
  v_stf_ct uuid; v_stf_st uuid; v_stf_no uuid;
  v_sess_b uuid; v_c_b uuid; v_sub_b uuid;
begin
  insert into public.schools (name) values ('Subj A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Subj B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_own,'sown@subj.test'), (v_ct,'sct@subj.test'), (v_st,'sst@subj.test'),
    (v_no,'sno@subj.test'), (v_ob,'sob@subj.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_own, 'Subj Owner',     'owner',           v_a),
    (v_ct,  'Subj ClassT',    'class_teacher',   v_a),
    (v_st,  'Subj SubjT',     'subject_teacher', v_a),
    (v_no,  'Subj Nobody',    'subject_teacher', v_a),
    (v_ob,  'Subj OtherOwn',  'owner',           v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_own::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  update public.school_settings set current_session_id = v_sess where school_id = v_a;

  insert into public.classes (name, level_order, school_id)
    values ('Class 9', 9, v_a) returning id into v_c9;
  insert into public.classes (name, level_order, school_id)
    values ('Class 10', 10, v_a) returning id into v_c10;
  insert into public.sections (class_id, name, school_id)
    values (v_c9, 'A', v_a) returning id into v_sec9;

  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('Physics', v_c9, 1, v_a) returning id into v_phy;
  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('Islamiat', v_c9, 2, v_a) returning id into v_isl;
  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('Physics', v_c10, 1, v_a) returning id into v_c10sub;

  insert into public.exam_terms (session_id, name, term_type, school_id)
    values (v_sess, 'First Term', 'first', v_a) returning id into v_term;
  insert into public.exam_subjects (exam_term_id, class_id, subject_id, max_marks, school_id)
    values (v_term, v_c9, v_phy, 100, v_a) returning id into v_es_phy;
  insert into public.exam_subjects (exam_term_id, class_id, subject_id, max_marks, school_id)
    values (v_term, v_c9, v_isl, 100, v_a) returning id into v_es_isl;
  insert into public.exam_subjects (exam_term_id, class_id, subject_id, max_marks, school_id)
    values (v_term, v_c10, v_c10sub, 100, v_a) returning id into v_es_c10;
  insert into public.assessments (session_id, class_id, subject_id, title,
                                  assessment_date, max_marks, school_id)
    values (v_sess, v_c9, v_phy, 'Weekly test', current_date, 20, v_a)
    returning id into v_asmt;

  -- Staff rows, and the profiles pointed at them. profiles.staff_id is what
  -- my_staff_id() reads, so without this link a teacher matches nothing.
  insert into public.staff (full_name, designation, school_id)
    values ('Subj ClassT', 'Teacher', v_a) returning id into v_stf_ct;
  insert into public.staff (full_name, designation, school_id)
    values ('Subj SubjT', 'Teacher', v_a) returning id into v_stf_st;
  insert into public.staff (full_name, designation, school_id)
    values ('Subj Nobody', 'Teacher', v_a) returning id into v_stf_no;
  alter table public.profiles disable trigger user;
  update public.profiles set staff_id = v_stf_ct where id = v_ct;
  update public.profiles set staff_id = v_stf_st where id = v_st;
  update public.profiles set staff_id = v_stf_no where id = v_no;
  alter table public.profiles enable trigger user;

  -- ClassT owns Class 9 section A. SubjT teaches Physics to Class 9.
  -- Nobody is assigned nothing, deliberately.
  perform public.fn_set_class_teacher(v_stf_ct, v_sess, v_c9, v_sec9);
  perform public.fn_set_subject_teachers(v_sess, v_c9, null, v_phy, array[v_stf_st]);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Ali Raza','father_name','Raza Sahib','father_cnic','35201-4000001-1',
    'session_id',v_sess,'class_id',v_c9,'section_id',v_sec9,'roll_no','1','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Bilal Khan','father_name','Khan Sahib','father_cnic','35201-4000002-2',
    'session_id',v_sess,'class_id',v_c10,'roll_no','1','links','[]'::jsonb));

  -- School B.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess_b;
  update public.school_settings set current_session_id = v_sess_b where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('Class 9', 9, v_b) returning id into v_c_b;
  insert into public.subjects (name, class_id, sort_order, school_id)
    values ('Physics', v_c_b, 1, v_b) returning id into v_sub_b;

  perform set_config('test.uid', v_own::text, false);
  raise notice 'fixture ok';
end $seed$;

-- Handles, so the tests below read as sentences.
create or replace function pg_temp.es(p_class text, p_subject text) returns uuid language sql as $$
  select es.id from public.exam_subjects es
   join public.classes c on c.id = es.class_id
   join public.subjects s on s.id = es.subject_id
   join public.schools sch on sch.id = es.school_id
  where c.name = p_class and s.name = p_subject and sch.name = 'Subj A';
$$;

create or replace function pg_temp.enr(p_student text) returns uuid language sql as $$
  select e.id from public.enrollments e
   join public.students st on st.id = e.student_id
  where st.full_name = p_student;
$$;

create or replace function pg_temp.marks(p_enr uuid, p_marks numeric) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('enrollment_id', p_enr, 'marks', p_marks));
$$;

-- =============================================================================
-- 1. The office may mark anything
-- =============================================================================
do $t$
begin
  perform pg_temp.be('Subj Owner');
  perform public.fn_enter_marks(pg_temp.es('Class 9', 'Physics'),
                                pg_temp.marks(pg_temp.enr('Ali Raza'), 71));
  perform public.fn_enter_marks(pg_temp.es('Class 10', 'Physics'),
                                pg_temp.marks(pg_temp.enr('Bilal Khan'), 55));
  perform pg_temp.ok(
    (select count(*) from public.mark_entries where marks in (71, 55)) = 2,
    '1. the owner may enter marks for every class');
end $t$;

-- =============================================================================
-- 2. A class teacher may mark EVERY subject of their own class
--
-- Not a loophole — a deliberate rule. A card has to be finishable when the
-- Islamiat teacher is on leave, and the class teacher is the person the school
-- holds responsible for that card.
-- =============================================================================
do $t$
begin
  perform pg_temp.be('Subj ClassT');
  perform public.fn_enter_marks(pg_temp.es('Class 9', 'Islamiat'),
                                pg_temp.marks(pg_temp.enr('Ali Raza'), 64));
  perform pg_temp.ok(
    (select marks from public.mark_entries
      where exam_subject_id = pg_temp.es('Class 9', 'Islamiat')
        and enrollment_id = pg_temp.enr('Ali Raza')) = 64,
    '2. the class teacher may mark any subject of their own class');
end $t$;

-- =============================================================================
-- 3. THE HOLE: a class teacher may NOT mark another class
--
-- Before 0085 this succeeded. The class teacher of Class 9 could rewrite Class
-- 10's board result and the only trace would be a corrected_from nobody reads.
-- =============================================================================
do $t$
begin
  perform pg_temp.be('Subj ClassT');
  perform pg_temp.raises(
    format($q$select public.fn_enter_marks(%L::uuid, %s::jsonb)$q$,
           pg_temp.es('Class 10', 'Physics'),
           quote_literal(pg_temp.marks(pg_temp.enr('Bilal Khan'), 99)::text)),
    '3. a class teacher entering ANOTHER class''s exam marks');
  -- And the mark is untouched, not merely un-refused.
  perform pg_temp.ok(
    (select marks from public.mark_entries
      where exam_subject_id = pg_temp.es('Class 10', 'Physics')) = 55,
    '3b. Class 10''s mark is still the one the office entered');
end $t$;

-- =============================================================================
-- 4. A subject teacher may mark their own class and subject
-- =============================================================================
do $t$
begin
  perform pg_temp.be('Subj SubjT');
  perform public.fn_enter_marks(pg_temp.es('Class 9', 'Physics'),
                                pg_temp.marks(pg_temp.enr('Ali Raza'), 82),
                                'remarked after recheck');
  perform pg_temp.ok(
    (select marks from public.mark_entries
      where exam_subject_id = pg_temp.es('Class 9', 'Physics')
        and enrollment_id = pg_temp.enr('Ali Raza')) = 82,
    '4. the subject teacher may mark their own class and subject');
end $t$;

-- =============================================================================
-- 5. And NOT another subject of that same class
--
-- The class is right and the subject is not. Nothing in the product recorded
-- which subjects a subject_teacher taught, so this could not have been checked
-- before the register existed.
-- =============================================================================
do $t$
begin
  perform pg_temp.be('Subj SubjT');
  perform pg_temp.raises(
    format($q$select public.fn_enter_marks(%L::uuid, %s::jsonb)$q$,
           pg_temp.es('Class 9', 'Islamiat'),
           quote_literal(pg_temp.marks(pg_temp.enr('Ali Raza'), 12)::text)),
    '5. the Physics teacher entering the same class''s Islamiat marks');
  perform pg_temp.ok(
    (select marks from public.mark_entries
      where exam_subject_id = pg_temp.es('Class 9', 'Islamiat')) = 64,
    '5b. the Islamiat mark is unchanged');
end $t$;

-- =============================================================================
-- 6. A teacher with no assignment may mark nothing — and is TOLD what to do
--
-- The message is asserted, not just the refusal. "permission denied" sends a
-- teacher to the vendor; naming the screen sends them to the office.
-- =============================================================================
do $t$
declare v_msg text := '';
begin
  perform pg_temp.be('Subj Nobody');
  begin
    perform public.fn_enter_marks(pg_temp.es('Class 9', 'Physics'),
                                  pg_temp.marks(pg_temp.enr('Ali Raza'), 5));
    raise exception 'FAIL  6. an unassigned teacher was allowed to enter marks';
  exception when others then
    v_msg := sqlerrm;
  end;
  perform pg_temp.ok(v_msg like '%class and subject you teach%',
    '6. an unassigned teacher is refused');
  perform pg_temp.ok(v_msg like '%Subject Teachers%',
    '6b. and the refusal names the screen that fixes it');
end $t$;

-- =============================================================================
-- 7. The assessment path obeys the same rule
--
-- It was already class-scoped. 0085 narrowed it to class AND subject so the two
-- paths cannot drift — which is how the exam path came to be the unguarded one.
-- =============================================================================
do $t$
declare v_asmt uuid;
begin
  select a.id into v_asmt from public.assessments a
   join public.schools s on s.id = a.school_id where s.name = 'Subj A';

  perform pg_temp.be('Subj SubjT');
  perform public.fn_enter_assessment_marks(
    v_asmt, pg_temp.marks(pg_temp.enr('Ali Raza'), 17));
  perform pg_temp.ok(
    (select marks from public.mark_entries
      where assessment_id = v_asmt and enrollment_id = pg_temp.enr('Ali Raza')) = 17,
    '7. the Physics teacher may mark the Physics class test');

  perform pg_temp.be('Subj Nobody');
  perform pg_temp.raises(
    format($q$select public.fn_enter_assessment_marks(%L::uuid, %s::jsonb)$q$,
           v_asmt, quote_literal(pg_temp.marks(pg_temp.enr('Ali Raza'), 1)::text)),
    '7b. an unassigned teacher on the assessment path too');
end $t$;

-- =============================================================================
-- 8. THE DIRECT TABLE, in two layers
--
-- Every mark-entry function above is SECURITY DEFINER, so it bypasses RLS
-- entirely. The question this section answers is what happens when somebody
-- skips the function and POSTs at /rest/v1/mark_entries with the anon key, which
-- any signed-in teacher can do.
--
-- LAYER ONE, and the current answer: `authenticated` has SELECT on mark_entries
-- and no INSERT or UPDATE. 0001 grants all four verbs on every table in public,
-- but mark_entries was created in 0005 — after that blanket grant and before
-- 0025 made it the default for future tables — so it fell between the two and
-- was never granted. The REST write path is therefore closed by PRIVILEGE, not
-- by policy, and that is worth knowing: it means marks_insert and marks_update
-- have never actually fired in production, the same shape as the dead
-- schools_update_platform policy 0083 dropped.
--
-- Asserted rather than assumed, because "it is closed" and "it is closed for the
-- reason I think" are different claims.
--
-- LAYER TWO: the policy still has to be right, because the grant is one ALTER
-- away from existing and nobody would think to re-check the policy when adding
-- it. So the grant is given INSIDE this transaction (which rolls back) and the
-- direct write is attempted as `authenticated` — with RLS applying, since RLS
-- does not apply to the table owner and running as the owner is the commonest
-- way a test like this passes over a wide-open table.
-- =============================================================================
do $t$
begin
  perform pg_temp.ok(
    has_table_privilege('authenticated', 'public.mark_entries', 'select'),
    '8. a signed-in teacher can READ marks over REST (by design — RLS narrows it)');
  perform pg_temp.ok(
    not has_table_privilege('authenticated', 'public.mark_entries', 'insert')
    and not has_table_privilege('authenticated', 'public.mark_entries', 'update'),
    '8b. and cannot WRITE them over REST at all: the grant does not exist');
end $t$;

-- Layer two. Granted here and only here; the rollback at the end of this file
-- takes it away again.
do $t$
declare v_ns text;
begin
  select nspname into v_ns from pg_namespace where nspname like 'pg\_temp%' limit 1;
  execute format('grant usage on schema %I to authenticated', v_ns);
end $t$;
grant insert, update on public.mark_entries to authenticated;

set local role authenticated;

do $t$
declare v_before numeric; v_after numeric; v_es uuid;
begin
  v_es := pg_temp.es('Class 10', 'Physics');
  select marks into v_before from public.mark_entries where exam_subject_id = v_es;

  perform pg_temp.be('Subj ClassT');
  -- The class teacher of Class 9 rewrites Class 10's mark DIRECTLY. RLS makes an
  -- UPDATE with no matching policy affect ZERO ROWS SILENTLY — no error — so the
  -- assertion must be about the value and never about an exception.
  update public.mark_entries set marks = 100 where exam_subject_id = v_es;

  select marks into v_after from public.mark_entries where exam_subject_id = v_es;
  perform pg_temp.ok(v_after = v_before,
    '8c. with the grant given, the POLICY still refuses another class''s mark');
end $t$;

do $t$
declare v_es uuid; v_before numeric; v_after numeric;
begin
  -- Their OWN class, to prove 8c refused for the right reason rather than
  -- refusing everything. A backstop that blocks the legitimate write too would
  -- pass 8c and break the product.
  v_es := pg_temp.es('Class 9', 'Islamiat');
  select marks into v_before from public.mark_entries
   where exam_subject_id = v_es and enrollment_id = pg_temp.enr('Ali Raza');

  perform pg_temp.be('Subj ClassT');
  update public.mark_entries set marks = 66
   where exam_subject_id = v_es and enrollment_id = pg_temp.enr('Ali Raza');

  select marks into v_after from public.mark_entries
   where exam_subject_id = v_es and enrollment_id = pg_temp.enr('Ali Raza');
  perform pg_temp.ok(v_before = 64 and v_after = 66,
    '8d. and ALLOWS the same teacher''s own class — the policy is not just "deny"');
end $t$;

do $t$
begin
  perform pg_temp.be('Subj Nobody');
  begin
    insert into public.mark_entries (exam_subject_id, enrollment_id, marks, max_marks)
    values (pg_temp.es('Class 9', 'Physics'), pg_temp.enr('Bilal Khan'), 90, 100);
    raise exception 'FAIL  8e. an unassigned teacher inserted a mark row directly';
  exception when others then
    -- INSERT with no matching policy RAISES, unlike UPDATE. Anything that is not
    -- an RLS refusal is a different failure and must not be swallowed.
    if sqlerrm like '%row-level security%' or sqlstate = '42501' then
      raise notice 'PASS  8e. RLS refuses a direct INSERT by an unassigned teacher';
    else
      raise;
    end if;
  end;
end $t$;

reset role;

-- =============================================================================
-- 9. Nothing crosses a school boundary
-- =============================================================================
do $t$
declare v_sess_b uuid; v_c_b uuid; v_sub_b uuid; v_stf uuid;
begin
  select s.id into v_sess_b from public.academic_sessions s
    join public.schools sc on sc.id = s.school_id where sc.name = 'Subj B';
  select c.id into v_c_b from public.classes c
    join public.schools sc on sc.id = c.school_id where sc.name = 'Subj B';
  select sub.id into v_sub_b from public.subjects sub
    join public.schools sc on sc.id = sub.school_id where sc.name = 'Subj B';
  select st.id into v_stf from public.staff st
    join public.schools sc on sc.id = st.school_id where sc.name = 'Subj A' limit 1;

  -- A's owner tries to write into B's register.
  perform pg_temp.be('Subj Owner');
  perform pg_temp.raises(
    format($q$select public.fn_set_subject_teachers(%L::uuid, %L::uuid, null, %L::uuid, array[%L::uuid])$q$,
           v_sess_b, v_c_b, v_sub_b, v_stf),
    '9. writing another school''s subject register');
  perform pg_temp.raises(
    format($q$select public.fn_subject_teachers(%L::uuid)$q$, v_sess_b),
    '9b. reading another school''s subject register');

  -- And the decision function refuses another school's ids outright rather than
  -- falling through to "no assignment found", which would be the same answer for
  -- the wrong reason.
  perform pg_temp.ok(
    public.fn_may_mark_subject(v_sess_b, v_c_b, null, v_sub_b) = false,
    '9c. fn_may_mark_subject says no to another school''s class');
end $t$;

-- =============================================================================
-- 10. The register itself
-- =============================================================================
do $t$
declare
  v_sess uuid; v_c9 uuid; v_c10 uuid; v_phy uuid; v_c10sub uuid;
  v_stf_ct uuid; v_stf_st uuid; j jsonb; v_row jsonb;
begin
  select s.id into v_sess from public.academic_sessions s
    join public.schools sc on sc.id = s.school_id where sc.name = 'Subj A';
  select id into v_c9  from public.classes where name = 'Class 9'
    and school_id = (select id from public.schools where name = 'Subj A');
  select id into v_c10 from public.classes where name = 'Class 10'
    and school_id = (select id from public.schools where name = 'Subj A');
  select id into v_phy from public.subjects where name = 'Physics' and class_id = v_c9;
  select id into v_c10sub from public.subjects where name = 'Physics' and class_id = v_c10;
  select id into v_stf_ct from public.staff where full_name = 'Subj ClassT';
  select id into v_stf_st from public.staff where full_name = 'Subj SubjT';

  perform pg_temp.be('Subj Owner');

  -- A subject that belongs to another class is refused. subjects.class_id makes
  -- this checkable, and without the check the office would create a row granting
  -- marks on a paper the class never sits.
  perform pg_temp.raises(
    format($q$select public.fn_set_subject_teachers(%L::uuid, %L::uuid, null, %L::uuid, array[%L::uuid])$q$,
           v_sess, v_c9, v_c10sub, v_stf_st),
    '10. a subject that belongs to a different class');

  -- REPLACE, not add: setting two teachers then one leaves one.
  perform public.fn_set_subject_teachers(v_sess, v_c9, null, v_phy,
                                         array[v_stf_st, v_stf_ct]);
  perform pg_temp.ok(
    (select count(*) from public.subject_teachers
      where session_id = v_sess and class_id = v_c9 and subject_id = v_phy) = 2,
    '10b. two teachers can share one subject');

  perform public.fn_set_subject_teachers(v_sess, v_c9, null, v_phy, array[v_stf_st]);
  perform pg_temp.ok(
    (select count(*) from public.subject_teachers
      where session_id = v_sess and class_id = v_c9 and subject_id = v_phy) = 1,
    '10c. setting the list REPLACES it — a teacher can be removed');

  -- An empty array clears it. Passing null does too, and both have to work,
  -- because a screen sending "nobody" is the normal way to unassign.
  perform public.fn_set_subject_teachers(v_sess, v_c9, null, v_phy, array[]::uuid[]);
  perform pg_temp.ok(
    (select count(*) from public.subject_teachers
      where session_id = v_sess and class_id = v_c9 and subject_id = v_phy) = 0,
    '10d. an empty list clears the subject');
  perform public.fn_set_subject_teachers(v_sess, v_c9, null, v_phy, array[v_stf_st]);

  -- The read returns EVERY class+subject, including the ones nobody teaches —
  -- those empty rows are the work list, and a screen that hid them would hide
  -- the thing the office opened it to do.
  j := public.fn_subject_teachers(v_sess);
  perform pg_temp.ok(jsonb_array_length(j->'rows') = 3,
    '10e. the register lists all three class+subject pairs, assigned or not');

  select e into v_row from jsonb_array_elements(j->'rows') e
   where e->>'subject_name' = 'Islamiat';
  perform pg_temp.ok(jsonb_array_length(v_row->'teachers') = 0,
    '10f. an unassigned subject comes back with an empty teacher list, not missing');

  select e into v_row from jsonb_array_elements(j->'rows') e
   where e->>'class_name' = 'Class 9' and e->>'subject_name' = 'Physics';
  perform pg_temp.ok(v_row->'teachers'->0->>'staff_name' = 'Subj SubjT',
    '10g. and an assigned one names the teacher');
end $t$;

-- =============================================================================
-- 11. A teacher cannot assign themselves
--
-- The most obvious way round the whole thing: if a subject_teacher could write
-- the register, the register would grant nothing.
-- =============================================================================
do $t$
declare v_sess uuid; v_c9 uuid; v_isl uuid; v_stf uuid;
begin
  select s.id into v_sess from public.academic_sessions s
    join public.schools sc on sc.id = s.school_id where sc.name = 'Subj A';
  select id into v_c9 from public.classes where name = 'Class 9'
    and school_id = (select id from public.schools where name = 'Subj A');
  select id into v_isl from public.subjects where name = 'Islamiat' and class_id = v_c9;
  select id into v_stf from public.staff where full_name = 'Subj Nobody';

  perform pg_temp.be('Subj Nobody');
  perform pg_temp.raises(
    format($q$select public.fn_set_subject_teachers(%L::uuid, %L::uuid, null, %L::uuid, array[%L::uuid])$q$,
           v_sess, v_c9, v_isl, v_stf),
    '11. a teacher assigning themselves a subject');
end $t$;

do $$ begin raise notice 'ALL SUBJECT TEACHER TESTS PASSED'; end $$;

rollback;
