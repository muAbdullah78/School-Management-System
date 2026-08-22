-- =============================================================================
-- The year-end rollover.
--
-- The one operation that touches every child in the school, runs once a year,
-- and had NO test suite at all. Writing one found the most serious defect in
-- this project: fn_rollover promoted children into OTHER SCHOOLS' classrooms.
--
-- The rules this file defends:
--
--  1. THE CLASS LADDER STAYS INSIDE THE SCHOOL. "The next class up" was found
--     with `select id from public.classes where active and level_order > ...`
--     — no school anywhere in it, inside a SECURITY DEFINER function where RLS
--     never applies. Assertions 6 and 7 are the two shapes it took: a school
--     with no class above its top one promoting into another school's higher
--     class, and — the ordinary case — two schools with the same ladder, where
--     the level_order values TIE and the winner is whichever row the heap
--     returns first.
--  2. A RULE CANNOT NAME ANOTHER SCHOOL'S CLASS. Rule class ids are caller
--     input and now go through assert_own.
--  3. THE DRY RUN IS THE COMMIT. A screen whose purpose is "check this before
--     you commit" is worthless if the two can differ, so the plan is asserted
--     identical across a dry run and the commit that follows it.
--  3b. AN AMBIGUOUS RUNG IS SURFACED, NOT GUESSED. A school with "Class 8" and
--     "Class 8 Science" gives the ladder two candidates. The first fix sorted by
--     id, which silently funnelled children into whichever won — a choice made
--     for the school with nothing on screen to say so. It now reports the class
--     as `unmapped` and asks for a rule. Getting there also exposed that "no
--     unique next class" and "no class above at all" were the same condition in
--     the old code, so an ambiguous MIDDLE year would have been marked as having
--     finished school.
--  4. A DRY RUN WRITES NOTHING.
--  5. ONLY ACTIVE ENROLMENTS MOVE. A child who left in March is not promoted.
--  6. GRADUATION IS A LEAVING. 0054 made left_on the field a leaving is
--     recorded in, so the largest leaving event of the year — a whole final
--     year — must appear in the leavers report, with a date that is not in the
--     future.
--  7. UNDO IS SAFE OR REFUSED. It reverses promotions only while nothing has
--     happened in the target session, and it reports THIS school's graduate
--     count — it used to count every tenant's.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/rollover.sql
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

create or replace function pg_temp.refuses(p_sql text, p_label text, p_expect text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if p_expect is not null and sqlerrm not like p_expect then
      raise exception 'FAIL  % — refused, but with the wrong message: %', p_label, sqlerrm;
    end if;
    raise notice 'PASS  % (%)', p_label, sqlerrm;
    return;
  end;
  raise exception 'FAIL  % — it was ALLOWED', p_label;
end;
$$;

create or replace function pg_temp.cls(p_name text) returns uuid language sql as $$
  select id from public.classes where name = p_name
$$;
create or replace function pg_temp.sess(p_school text, p_name text) returns uuid language sql as $$
  select s.id from public.academic_sessions s join public.schools sc on sc.id = s.school_id
  where sc.name = p_school and s.name = p_name
$$;
create or replace function pg_temp.stu(p_name text) returns uuid language sql as $$
  select id from public.students where full_name = p_name and deleted_at is null
$$;

-- --- Fixture -----------------------------------------------------------------
-- Two schools with DELIBERATELY OVERLAPPING ladders, because that overlap is
-- what makes rule 1 testable:
--
--   School A: A Five (5), A Six (6), A Seven (7),
--             A Eight (8), A Eight Science (8), A Ten (10)
--   School B: B Six (6), B Eleven (11)
--
-- Every rung is deliberate:
--   * A Five  — level 6 exists in BOTH schools, so the level_order values tie.
--               This is the ordinary case and the one that used to send A's
--               children to B's classroom.
--   * A Seven — TWO classes at level 8, so the next rung is ambiguous.
--   * A Ten   — top of school A, while school B has a level 11.
-- School B also holds three graduates, so a scoped graduate count can be told
-- apart from an unscoped one.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000da01';
  v_pa uuid := '00000000-0000-0000-0000-00000000da02';
  v_ca uuid := '00000000-0000-0000-0000-00000000da03';
  v_ob uuid := '00000000-0000-0000-0000-00000000da04';
  v_s1 uuid; v_s2 uuid; v_sb uuid;
  v_c5 uuid; v_c6 uuid; v_c10 uuid; v_sec5 uuid; v_sec6 uuid;
  v_head uuid;
begin
  insert into public.schools (name) values ('Roll A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Roll B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa,'roa@ro.test'), (v_pa,'rpa@ro.test'), (v_ca,'rca@ro.test'), (v_ob,'rob@ro.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Ro Owner',     'owner',       v_a),
    (v_pa, 'Ro Principal', 'principal',   v_a),
    (v_ca, 'Ro Clerk',     'admin_clerk', v_a),
    (v_ob, 'Ro Owner B',   'owner',       v_b)
  on conflict (id) do update set school_id = excluded.school_id,
                                 role = excluded.role, full_name = excluded.full_name,
                                 active = true;
  alter table public.profiles enable trigger user;

  -- School B FIRST, so its rows sit earlier in the heap. Before 0055 that is
  -- precisely what made B win the level_order tie.
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sb;
  update public.school_settings set current_session_id = v_sb where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B Six', 6, v_b);
  insert into public.classes (name, level_order, school_id)
    values ('B Eleven', 11, v_b);
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Child','father_name','B Father','father_cnic','35201-8800001-1',
    'session_id',v_sb,'class_id',pg_temp.cls('B Six'),'roll_no','1','links','[]'::jsonb));
  -- Three graduates in school B, so assertion 28 can tell a scoped count from an
  -- unscoped one. Without them both answers are 1 and the guard is untestable —
  -- which is exactly how the unscoped version survived review.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Alum One','father_name','BA1','father_cnic','35201-8800011-1',
    'session_id',v_sb,'class_id',pg_temp.cls('B Six'),'roll_no','11','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Alum Two','father_name','BA2','father_cnic','35201-8800012-2',
    'session_id',v_sb,'class_id',pg_temp.cls('B Six'),'roll_no','12','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Alum Three','father_name','BA3','father_cnic','35201-8800013-3',
    'session_id',v_sb,'class_id',pg_temp.cls('B Six'),'roll_no','13','links','[]'::jsonb));
  perform public.fn_set_student_status(pg_temp.stu('B Alum One'),   'graduated', 'B', current_date);
  perform public.fn_set_student_status(pg_temp.stu('B Alum Two'),   'graduated', 'B', current_date);
  perform public.fn_set_student_status(pg_temp.stu('B Alum Three'), 'graduated', 'B', current_date);

  perform set_config('test.uid', v_oa::text, false);
  -- ends_on is in the FUTURE on purpose. Schools run the rollover before the
  -- session formally closes, and that is precisely when stamping the session's
  -- end date as a leaving date would put tomorrow in the register. With a past
  -- end date the least() guard is unreachable and the assertion is decoration.
  insert into public.academic_sessions (name, starts_on, ends_on, is_current, school_id)
    values ('2025-2026', current_date - 300, current_date + 40, true, v_a) returning id into v_s1;
  insert into public.academic_sessions (name, starts_on, ends_on, is_current, school_id)
    values ('2026-2027', current_date - 1, current_date + 360, false, v_a) returning id into v_s2;
  update public.school_settings set current_session_id = v_s1 where school_id = v_a;

  insert into public.classes (name, level_order, school_id)
    values ('A Five', 5, v_a) returning id into v_c5;
  insert into public.classes (name, level_order, school_id)
    values ('A Six', 6, v_a) returning id into v_c6;
  -- An ambiguous rung: TWO classes at level 8. A Seven's children must come out
  -- as `unmapped` rather than being funnelled into whichever the sort favours.
  insert into public.classes (name, level_order, school_id) values ('A Seven', 7, v_a);
  insert into public.classes (name, level_order, school_id) values ('A Eight', 8, v_a);
  insert into public.classes (name, level_order, school_id) values ('A Eight Science', 8, v_a);
  insert into public.classes (name, level_order, school_id)
    values ('A Ten', 10, v_a) returning id into v_c10;
  insert into public.sections (class_id, name, sort_order, school_id)
    values (v_c5, 'A', 1, v_a) returning id into v_sec5;
  -- Same section NAME in the target class, so the carry-over has somewhere to go.
  insert into public.sections (class_id, name, sort_order, school_id)
    values (v_c6, 'A', 1, v_a) returning id into v_sec6;

  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_s1, v_c5, v_head, 2000, v_a);

  -- Class 5: two children, one of whom leaves before the rollover.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Fiver Stays','father_name','FS Father','father_cnic','35201-8100001-1',
    'admission_date',(current_date - 280)::date,
    'session_id',v_s1,'class_id',v_c5,'section_id',v_sec5,'roll_no','7','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Fiver Left','father_name','FL Father','father_cnic','35201-8100002-2',
    'admission_date',(current_date - 280)::date,
    'session_id',v_s1,'class_id',v_c5,'section_id',v_sec5,'roll_no','8','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Sevener Ambiguous','father_name','SA Father','father_cnic','35201-8100007-7',
    'admission_date',(current_date - 280)::date,
    'session_id',v_s1,'class_id',pg_temp.cls('A Seven'),'roll_no','1','links','[]'::jsonb));
  -- Class 10: the top of school A.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Tenner Finishing','father_name','TF Father','father_cnic','35201-8100003-3',
    'admission_date',(current_date - 280)::date,
    'session_id',v_s1,'class_id',v_c10,'roll_no','1','links','[]'::jsonb));

  perform public.fn_set_student_status(pg_temp.stu('Fiver Left'), 'withdrawn',
                                       'Left in March', current_date - 20);

  -- An existing Class 6 roll in the TARGET session, so the roll-number seed has
  -- something to continue from rather than starting at 1.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Already In Six','father_name','AIS Father','father_cnic','35201-8100004-4',
    'session_id',v_s2,'class_id',v_c6,'section_id',v_sec6,'roll_no','3','links','[]'::jsonb));
end;
$seed$;

-- =============================================================================
-- 1. Who may run it
-- =============================================================================
do $$
declare v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
        v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
begin
  perform pg_temp.be('Ro Clerk');
  perform pg_temp.refuses(
    format('select public.fn_rollover(%L::uuid, %L::uuid, ''[]''::jsonb, false)', v_s1, v_s2),
    '1. a clerk may not run a rollover, even a dry one', '%owner or principal%');
  perform pg_temp.refuses(
    format('select public.fn_rollover_undo(%L::uuid)', v_s2),
    '2. nor undo one', '%owner or principal%');

  perform pg_temp.be('Ro Owner');
  perform pg_temp.refuses(
    format('select public.fn_rollover(%L::uuid, %L::uuid, ''[]''::jsonb, false)', v_s1, v_s1),
    '3. the target session must differ from the source', '%must differ%');
  perform pg_temp.refuses(
    format('select public.fn_rollover(%L::uuid, %L::uuid, ''{}''::jsonb, false)', v_s1, v_s2),
    '4. rules must be an array', '%must be a JSON array%');
end;
$$;

-- =============================================================================
-- 2. THE BUG. The class ladder stays inside the school.
-- =============================================================================
do $$
declare
  v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
  v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
  j jsonb; r jsonb; n integer;
begin
  perform pg_temp.be('Ro Owner');
  j := public.fn_rollover(v_s1, v_s2, '[]'::jsonb, false);

  perform pg_temp.ok(
    (select count(*) from jsonb_array_elements(j->'rows')) = 3,
    '5. the plan covers the three children still on the roll, not the one who left');

  select e into r from jsonb_array_elements(j->'rows') e
   where e->>'name' = 'Fiver Stays';
  -- Before 0055 this said "B Six": another school's classroom, chosen because
  -- both sixes carry level_order 6 and B's row came first out of the heap.
  perform pg_temp.ok(r->>'to_class' = 'A Six',
    '6. a class with a same-level twin in ANOTHER school still promotes inside '
    'its own school (got ' || coalesce(r->>'to_class','null') || ')');

  select e into r from jsonb_array_elements(j->'rows') e
   where e->>'name' = 'Tenner Finishing';
  -- Before 0055: "B Eleven", and action 'promote'.
  perform pg_temp.ok(r->>'action' = 'graduate',
    '7. the top class of the school GRADUATES rather than being promoted into '
    'another school''s higher class (got ' || coalesce(r->>'action','null') || ')');
  perform pg_temp.ok(r->>'to_class' is null,
    '8. and has no destination at all');

  perform pg_temp.ok((j->>'promoted')::int = 1 and (j->>'graduated')::int = 1
                 and (j->>'unmapped')::int = 1,
    '9. the tally agrees: one promoted, one graduated, one unmapped');

  -- The ambiguous rung. An id or name tie-break here would silently pick one of
  -- the two level-8 classes and nothing on screen would say a choice had been
  -- made for the school.
  select e into r from jsonb_array_elements(j->'rows') e
   where e->>'name' = 'Sevener Ambiguous';
  perform pg_temp.ok(r->>'action' = 'unmapped',
    '9b. a rung with TWO classes at the next level up is reported as unmapped '
    'rather than guessed at (got ' || coalesce(r->>'action','null') || ')');
  perform pg_temp.ok(r->>'message' = 'No target class chosen',
    '9c. and the plan says why, so the school knows to add a rule');

  -- Rule 5: only active enrolments move.
  perform pg_temp.ok(
    not exists (select 1 from jsonb_array_elements(j->'rows') e
                 where e->>'name' = 'Fiver Left'),
    '10. a child who left in March is not promoted');
end;
$$;

-- =============================================================================
-- 3. A rule cannot name another school's class
-- =============================================================================
do $$
declare
  v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
  v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
  v_b11 uuid := pg_temp.cls('B Eleven');
  v_a5 uuid := pg_temp.cls('A Five');
begin
  perform pg_temp.be('Ro Owner');
  perform pg_temp.refuses(
    format('select public.fn_rollover(%L::uuid, %L::uuid, %L::jsonb, false)',
      v_s1, v_s2, jsonb_build_array(jsonb_build_object(
        'from_class_id', v_a5, 'action', 'promote', 'to_class_id', v_b11))::text),
    '11. a rule naming another school''s class is REFUSED, not honoured',
    '%classes not found in this school%');
  perform pg_temp.refuses(
    format('select public.fn_rollover(%L::uuid, %L::uuid, %L::jsonb, false)',
      v_s1, v_s2, jsonb_build_array(jsonb_build_object(
        'from_class_id', v_b11, 'action', 'retain'))::text),
    '12. and so is a rule keyed on another school''s class',
    '%classes not found in this school%');
end;
$$;

-- =============================================================================
-- 4. The dry run is the commit
-- =============================================================================
do $$
declare
  v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
  v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
  a jsonb; b jsonb; c jsonb; n integer;
begin
  perform pg_temp.be('Ro Owner');

  a := public.fn_rollover(v_s1, v_s2, '[]'::jsonb, false);
  b := public.fn_rollover(v_s1, v_s2, '[]'::jsonb, false);
  perform pg_temp.ok(a->'rows' = b->'rows',
    '13. two dry runs produce the identical plan — an ambiguous rung resolves to '
    'nothing rather than to whichever row the sort favoured, so there is no '
    'ordering left for the plan to disagree about');

  select count(*) into n from public.enrollments
   where session_id = v_s2 and promoted_from is not null;
  perform pg_temp.ok(n = 0, '14. a dry run has written nothing');

  c := public.fn_rollover(v_s1, v_s2, '[]'::jsonb, true);
  perform pg_temp.ok(
    (select jsonb_agg(x order by x->>'name') from jsonb_array_elements(a->'rows') x)
    = (select jsonb_agg(x order by x->>'name') from jsonb_array_elements(c->'rows') x),
    '15. and the COMMIT does exactly what the last dry run said it would');
end;
$$;

-- =============================================================================
-- 5. What the commit actually wrote
-- =============================================================================
do $$
declare
  v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
  v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
  r record; n integer;
begin
  perform pg_temp.be('Ro Owner');

  select e.class_id, e.section_id, e.roll_no, e.status::text, e.promoted_from
    into r
    from public.enrollments e
    join public.students s on s.id = e.student_id
   where e.session_id = v_s2 and s.full_name = 'Fiver Stays';
  perform pg_temp.ok(r.class_id = pg_temp.cls('A Six'),
    '16. the promoted child is in their own school''s next class');
  perform pg_temp.ok(r.section_id is not null,
    '17. and their section was carried across by name');
  perform pg_temp.ok(r.roll_no = '4',
    '18. with a roll number continuing from the one already in that class, not '
    'restarting at 1 (got ' || coalesce(r.roll_no,'null') || ')');
  perform pg_temp.ok(r.status = 'active' and r.promoted_from is not null,
    '19. the new enrolment is active and remembers where it came from');

  select count(*) into n from public.enrollments e
    join public.students s on s.id = e.student_id
   where e.session_id = v_s1 and s.full_name = 'Fiver Stays' and e.status = 'promoted';
  perform pg_temp.ok(n = 1, '20. and the source enrolment is stamped promoted');

  select count(*) into n from public.enrollments e
    join public.classes c on c.id = e.class_id
   where e.school_id <> c.school_id;
  perform pg_temp.ok(n = 0,
    '21. NO enrolment anywhere points at a class belonging to another school');
end;
$$;

-- =============================================================================
-- 6. Graduation is a leaving
-- =============================================================================
do $$
declare v_ten uuid := pg_temp.stu('Tenner Finishing'); r record; n integer;
begin
  perform pg_temp.be('Ro Owner');

  select status::text as st, left_on, leaving_reason into r
    from public.students where id = v_ten;
  perform pg_temp.ok(r.st = 'graduated', '22. the leaver is an alumnus');
  perform pg_temp.ok(r.left_on is not null,
    '23. with a leaving DATE — 0054 made this the field a leaving lives in, and '
    'a whole final year is the largest leaving event of the school year');
  -- The source session ends 40 days from now, so an unguarded stamp of
  -- ends_on would put a leaving date in the future.
  perform pg_temp.ok(r.left_on <= current_date,
    '24. and the date is not in the future, even though the source session ends '
    'forty days from now (got ' || r.left_on || ')');
  perform pg_temp.ok(r.leaving_reason is not null, '25. and a reason');

  select count(*) into n from public.fn_students_left(null, null)
   where student_name = 'Tenner Finishing';
  perform pg_temp.ok(n = 1,
    '26. so the graduating class appears in the leavers report, which is the '
    'whole reason for stamping it');
end;
$$;

-- =============================================================================
-- 7. Undo
-- =============================================================================
do $$
declare
  v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
  v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
  j jsonb; n integer;
begin
  perform pg_temp.be('Ro Owner');
  j := public.fn_rollover_undo(v_s2);

  perform pg_temp.ok((j->>'undone')::int = 1,
    '27. undo reverses the promotion it created');

  -- The leak. School A has ONE graduate; school B has none, but before 0055
  -- this counted every tenant's graduates and handed the total to A.
  -- School A has ONE graduate; school B has three. The unscoped version
  -- returned 4 — a cross-tenant figure handed to school A's principal.
  perform pg_temp.ok((j->>'graduated_total')::int = 1,
    '28. and reports THIS school''s graduate count, not the platform''s four (got '
      || (j->>'graduated_total') || ')');

  select count(*) into n from public.enrollments
   where session_id = v_s2 and promoted_from is not null;
  perform pg_temp.ok(n = 0, '29. the rollover-created enrolment is gone');

  select count(*) into n from public.enrollments e
    join public.students s on s.id = e.student_id
   where e.session_id = v_s1 and s.full_name = 'Fiver Stays' and e.status = 'active';
  perform pg_temp.ok(n = 1, '30. and the source enrolment is active again');

  select count(*) into n from public.enrollments e
    join public.students s on s.id = e.student_id
   where e.session_id = v_s2 and s.full_name = 'Already In Six';
  perform pg_temp.ok(n = 1,
    '31. a child enrolled in the target session by HAND is untouched — undo '
    'removes only what the rollover made');
end;
$$;

-- =============================================================================
-- 8. Undo refuses once the new year has started
-- =============================================================================
do $$
declare
  v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
  v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
  v_c6 uuid := pg_temp.cls('A Six');
  v_head uuid; n integer;
begin
  perform pg_temp.be('Ro Owner');
  perform public.fn_rollover(v_s1, v_s2, '[]'::jsonb, true);

  select id into v_head from public.fee_heads
   where school_id = public.current_school_id() limit 1;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_s2, v_c6, v_head, 2500, public.current_school_id());
  perform public.fn_generate_class_invoices(v_s2, v_c6,
    date_trunc('month', current_date)::date, current_date + 7);

  perform pg_temp.refuses(
    format('select public.fn_rollover_undo(%L::uuid)', v_s2),
    '32. undo is refused once fees have been raised in the new session',
    '%already recorded in the target session%');

  select count(*) into n from public.enrollments
   where session_id = v_s2 and promoted_from is not null;
  perform pg_temp.ok(n = 1,
    '33. and the refusal left the rolled-over enrolment in place');
end;
$$;

-- =============================================================================
-- 9. Nothing crosses a school boundary
-- =============================================================================
do $$
declare
  v_s1 uuid := pg_temp.sess('Roll A','2025-2026');
  v_s2 uuid := pg_temp.sess('Roll A','2026-2027');
  n integer;
begin
  perform pg_temp.be('Ro Owner B');
  perform pg_temp.refuses(
    format('select public.fn_rollover(%L::uuid, %L::uuid, ''[]''::jsonb, true)', v_s1, v_s2),
    '34. another school''s owner cannot roll over my sessions',
    '%academic_sessions not found in this school%');
  perform pg_temp.refuses(
    format('select public.fn_rollover_undo(%L::uuid)', v_s2),
    '35. nor undo my rollover', '%academic_sessions not found in this school%');

  select count(*) into n from public.enrollments e
    join public.students s on s.id = e.student_id
   where s.full_name = 'B Child' and e.status = 'active';
  perform pg_temp.ok(n = 1,
    '36. and school B''s own child was never touched by any of school A''s runs');
end;
$$;

rollback;
