-- =============================================================================
-- The two go-live importers.
--
-- These are the first tools a school touches: paste the register, paste last
-- year's arrears. Neither had a test suite, and both looked children up across
-- EVERY school on the platform.
--
-- gr_no and admission_no are per-school counters. Every school has a GR 0001.
-- That single fact is what all of this turns on, and it is why the fixture makes
-- two schools whose children share both a GR number and a very common name.
--
-- The rules this file defends:
--
--  1. A DUPLICATE IS A DUPLICATE IN MY SCHOOL. fn_import_students rejected rows
--     with "GR 0001 already exists" because ANOTHER school had a GR 0001, so a
--     school could not finish its first bulk import — and the rejection rate
--     grew with every school that joined.
--  2. A LOOKUP FINDS MY CHILD. fn_import_opening_balances used SELECT INTO,
--     which takes the first row and raises nothing, so a row could resolve to
--     another school's child and then fail with "Student is not enrolled in the
--     selected session" about a pupil who is.
--  3. AND THE REPORT NAMES MY CHILD. The result row carries the resolved name,
--     so the import report could print another school's pupil back at the
--     importer.
--  4. A NAME THAT IS UNIQUE HERE IS NOT AMBIGUOUS. "Muhammad Ali matches
--     several students — use GR No" for a school holding exactly one, with the
--     advice pointing at the GR path that was also broken.
--  5. THE MONEY LANDS WHERE THE LEDGER READS IT. An opening balance is only
--     worth importing if student_balance() then returns it.
--  6. A DRY RUN WRITES NOTHING, and re-running a file does not double the debt.
--
-- This class had already been diagnosed once, correctly, in 0042 — for staff.
-- Two of the three importers were never revisited. Assertion 1 is the one that
-- would have caught that.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/importers.sql
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

create or replace function pg_temp.sess(p_school text) returns uuid language sql as $$
  select s.id from public.academic_sessions s join public.schools sc on sc.id = s.school_id
  where sc.name = p_school and s.is_current
$$;
create or replace function pg_temp.cls(p_name text) returns uuid language sql as $$
  select id from public.classes where name = p_name
$$;
create or replace function pg_temp.gr(p_school text) returns text language sql as $$
  select s.gr_no from public.students s join public.schools sc on sc.id = s.school_id
  where sc.name = p_school and s.full_name = 'Muhammad Ali'
$$;
-- A GR that exists in school B and NOT in school A.
create or replace function pg_temp.gr_b_only() returns text language sql as $$
  select s.gr_no from public.students s join public.schools sc on sc.id = s.school_id
  where sc.name = 'Imp B' and s.full_name = 'B Only Child'
$$;

-- --- Fixture -----------------------------------------------------------------
-- School B is created FIRST so its rows sit earlier in the heap: that ordering
-- is exactly what made an unscoped SELECT INTO pick B's child over A's.
--
-- Both schools admit a "Muhammad Ali" — a name common enough in Pakistan that
-- collisions between schools are the norm, not a contrivance — and because GR is
-- a per-school counter both children get the SAME GR number.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-00000000fb01';
  v_ca uuid := '00000000-0000-0000-0000-00000000fb02';
  v_ob uuid := '00000000-0000-0000-0000-00000000fb03';
  v_sa uuid; v_sb uuid; v_cla uuid; v_clb uuid; v_head uuid;
begin
  insert into public.schools (name) values ('Imp B') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('Imp A') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa,'ia@im.test'), (v_ca,'ic@im.test'), (v_ob,'ib@im.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'Imp Owner',   'owner',       v_a),
    (v_ca, 'Imp Clerk',   'admin_clerk', v_a),
    (v_ob, 'Imp Owner B', 'owner',       v_b)
  on conflict (id) do update set school_id = excluded.school_id,
                                 role = excluded.role, full_name = excluded.full_name,
                                 active = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sb;
  update public.school_settings set current_session_id = v_sb where school_id = v_b;
  insert into public.classes (name, level_order, school_id)
    values ('B One', 1, v_b) returning id into v_clb;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Muhammad Ali','father_name','B Father','father_cnic','35201-9100001-1',
    'session_id',v_sb,'class_id',v_clb,'roll_no','1','links','[]'::jsonb));
  -- A SECOND child in school B, so B holds a GR number that school A does not.
  -- The first attempt at this test used B's first child, and both schools' first
  -- child is GR 0001 — so the "duplicate" it complained about was a real one in
  -- school A, and the assertion was testing nothing. Per-school counters agree
  -- on 0001 by construction; they diverge only once the schools differ in size.
  -- THREE more, so school B's counter runs ahead of school A's two children and
  -- B ends up holding a GR that A genuinely does not.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Filler One','father_name','BF1','father_cnic','35201-9100002-2',
    'session_id',v_sb,'class_id',v_clb,'roll_no','2','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Filler Two','father_name','BF2','father_cnic','35201-9100003-3',
    'session_id',v_sb,'class_id',v_clb,'roll_no','3','links','[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','B Only Child','father_name','B Father Two','father_cnic','35201-9100004-4',
    'session_id',v_sb,'class_id',v_clb,'roll_no','4','links','[]'::jsonb));

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sa;
  update public.school_settings set current_session_id = v_sa where school_id = v_a;
  insert into public.classes (name, level_order, school_id)
    values ('A One', 1, v_a) returning id into v_cla;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sa, v_cla, v_head, 2000, v_a);

  perform public.fn_admit_student(jsonb_build_object(
    'full_name','Muhammad Ali','father_name','A Father','father_cnic','35201-9200001-1',
    'session_id',v_sa,'class_id',v_cla,'roll_no','1','links','[]'::jsonb));
  -- A second A child, admitted to no session, so rule 2's genuine error case
  -- ("not enrolled in the selected session") has something real to fire on.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name','No Session Child','father_name','NS Father','father_cnic','35201-9200002-2',
    'session_id',v_sa,'class_id',v_cla,'roll_no','2','links','[]'::jsonb));
end;
$seed$;

-- =============================================================================
-- 1. Both schools really do share a GR number
-- =============================================================================
do $$
begin
  perform pg_temp.ok(pg_temp.gr('Imp A') = pg_temp.gr('Imp B'),
    '1. the two schools'' first children share a GR number (' || pg_temp.gr('Imp A')
      || ') — a per-school counter, which is the whole premise');
  perform pg_temp.ok(
    not exists (select 1 from public.students s
                join public.schools sc on sc.id = s.school_id
                where sc.name = 'Imp A' and s.gr_no = pg_temp.gr_b_only()),
    '1b. and school B holds a GR (' || pg_temp.gr_b_only() || ') that school A '
    'does not — the case assertion 2 needs, and the one the first version of '
    'this test got wrong by using a number both schools happened to have');
end;
$$;

-- =============================================================================
-- 2. A duplicate is a duplicate IN MY SCHOOL
-- =============================================================================
do $$
declare v_sa uuid := pg_temp.sess('Imp A'); j jsonb; r jsonb;
begin
  perform pg_temp.be('Imp Owner');

  -- A brand-new child whose GR happens to match school B's existing one.
  -- The class is named in the ROW ('class'), not as an argument: the importer
  -- resolves it per row so one file can carry a whole school.
  j := public.fn_import_students(v_sa,
        jsonb_build_array(jsonb_build_object(
          'full_name','Fresh Child','father_name','Fresh Father','class','A One',
          'gr_no', pg_temp.gr_b_only())), true);
  r := j->'rows'->0;
  perform pg_temp.ok(r->>'status' <> 'skipped',
    '2. a GR that exists only in ANOTHER school is not a duplicate here — this '
    'is what stopped a school finishing its first import (got '
      || (r->>'status') || ': ' || coalesce(r->>'message','—') || ')');

  -- ...but a GR that exists in MY school still is.
  j := public.fn_import_students(v_sa,
        jsonb_build_array(jsonb_build_object(
          'full_name','Clashing Child','father_name','C Father','class','A One',
          'gr_no', pg_temp.gr('Imp A'))), true);
  r := j->'rows'->0;
  perform pg_temp.ok(r->>'status' = 'skipped' and r->>'message' like '%already exists%',
    '3. a GR that exists in MY school still is — the check is narrowed, not '
    'switched off (got ' || (r->>'status') || ')');
end;
$$;

-- =============================================================================
-- 3. An opening-balance lookup finds MY child
-- =============================================================================
do $$
declare v_sa uuid := pg_temp.sess('Imp A'); j jsonb; r jsonb;
begin
  perform pg_temp.be('Imp Owner');

  -- By GR. Before 0056 this failed with "Student is not enrolled in the
  -- selected session" because SELECT INTO had picked school B's child.
  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('gr_no', pg_temp.gr('Imp A'),
                                            'amount', 'Rs 12,500.00')), true);
  r := j->'rows'->0;
  perform pg_temp.ok(r->>'status' = 'ok',
    '4. a row keyed on MY GR number resolves to MY child (got '
      || (r->>'status') || ': ' || coalesce(r->>'message','—') || ')');
  perform pg_temp.ok((r->>'amount')::numeric = 12500,
    '5. and "Rs 12,500.00" is read as 12500 (got ' || (r->>'amount') || ')');

  -- By name, with no father given — the ordinary case for an old register.
  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('full_name','Muhammad Ali',
                                            'amount','3000')), true);
  r := j->'rows'->0;
  perform pg_temp.ok(r->>'status' = 'ok',
    '6. a name that is unique in MY school is not "ambiguous" because another '
    'school has the same one (got ' || (r->>'status') || ': '
      || coalesce(r->>'message','—') || ')');
  perform pg_temp.ok(r->>'name' = 'Muhammad Ali',
    '7. and the report names a child, not a foreign one');
end;
$$;

-- =============================================================================
-- 4. The genuine errors still fire
-- =============================================================================
do $$
declare
  v_sa uuid := pg_temp.sess('Imp A'); j jsonb; r jsonb;
  v_other uuid;
begin
  perform pg_temp.be('Imp Owner');

  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('gr_no','ZZ-999','amount','500')), true);
  perform pg_temp.ok((j->'rows'->0)->>'status' = 'error',
    '8. a GR nobody has is still an error');

  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('gr_no', pg_temp.gr('Imp A'),
                                            'amount','-100')), true);
  perform pg_temp.ok(((j->'rows'->0)->>'message') like '%negative%',
    '9. a negative opening balance is refused rather than quietly credited');

  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('gr_no', pg_temp.gr('Imp A'),
                                            'amount','0')), true);
  perform pg_temp.ok((j->'rows'->0)->>'status' = 'skipped',
    '10. a zero balance is skipped, not imported as a Rs 0 challan');

  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('full_name','Muhammad Ali',
                                            'amount','abc')), true);
  perform pg_temp.ok(((j->'rows'->0)->>'message') like '%Invalid amount%',
    '11. an unparseable amount names itself in the message');

  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('full_name','Muhammad Ali',
                                            'amount','500','due_date','31-01-2026')), true);
  perform pg_temp.ok(((j->'rows'->0)->>'message') like '%YYYY-MM-DD%',
    '12. a date in the wrong format says which format it wants');
end;
$$;

-- =============================================================================
-- 5. The money lands where the ledger reads it
-- =============================================================================
do $$
declare
  v_sa uuid := pg_temp.sess('Imp A'); j jsonb; n integer; v_bal numeric;
  v_stu uuid;
begin
  perform pg_temp.be('Imp Owner');
  select s.id into v_stu from public.students s join public.schools sc on sc.id = s.school_id
   where sc.name = 'Imp A' and s.full_name = 'Muhammad Ali';

  perform pg_temp.ok(public.student_balance(v_stu) = 0,
    '13. the child owes nothing before the import');

  -- Dry run first.
  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('gr_no', pg_temp.gr('Imp A'),
                                            'amount','7500')), true);
  perform pg_temp.ok((j->>'created')::int = 1 and (j->>'dry_run')::boolean,
    '14. a dry run reports what it would do');
  perform pg_temp.ok(public.student_balance(v_stu) = 0,
    '15. and has written nothing');

  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('gr_no', pg_temp.gr('Imp A'),
                                            'amount','7500')), false);
  perform pg_temp.ok((j->>'created')::int = 1, '16. the real run creates it');

  v_bal := public.student_balance(v_stu);
  perform pg_temp.ok(v_bal = 7500,
    '17. and student_balance() returns it — an opening balance nothing reads is '
    'not worth importing (got ' || v_bal || ')');

  -- Re-running the same file must not double the debt.
  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('gr_no', pg_temp.gr('Imp A'),
                                            'amount','7500')), false);
  perform pg_temp.ok((j->'rows'->0)->>'status' = 'skipped',
    '18. re-running the file skips the row');
  perform pg_temp.ok(public.student_balance(v_stu) = 7500,
    '19. and the debt is not doubled (got ' || public.student_balance(v_stu) || ')');

  select count(*) into n from public.invoices
   where student_id = v_stu and notes = 'opening_balance';
  perform pg_temp.ok(n = 1, '20. exactly one opening-balance invoice exists');
end;
$$;

-- =============================================================================
-- 6. Who may import, and across which boundary
-- =============================================================================
do $$
declare v_sa uuid := pg_temp.sess('Imp A'); v_sb uuid := pg_temp.sess('Imp B');
        j jsonb;
begin
  perform pg_temp.be('Imp Clerk');
  j := public.fn_import_opening_balances(v_sa,
        jsonb_build_array(jsonb_build_object('full_name','No Session Child',
                                            'amount','100')), true);
  perform pg_temp.ok((j->'rows'->0)->>'status' = 'ok',
    '21. a clerk may import balances — it is clerical work');

  perform pg_temp.be('Imp Owner B');
  perform pg_temp.refuses(
    format('select public.fn_import_opening_balances(%L::uuid, ''[]''::jsonb, true)', v_sa),
    '22. another school''s owner cannot import into my session',
    '%academic_sessions not found in this school%');

  -- And school B importing into its OWN session must not find A's children,
  -- even though they share a GR number.
  j := public.fn_import_opening_balances(v_sb,
        jsonb_build_array(jsonb_build_object('gr_no', pg_temp.gr('Imp A'),
                                            'amount','999')), true);
  perform pg_temp.ok((j->'rows'->0)->>'name' <> 'No Session Child',
    '23. and the boundary holds in the other direction too');
end;
$$;

-- =============================================================================
-- 7. Nothing from this ran against school B's ledger
-- =============================================================================
do $$
declare n integer;
begin
  perform pg_temp.be('Imp Owner B');
  select count(*) into n from public.invoices i
    join public.schools sc on sc.id = i.school_id
   where sc.name = 'Imp B' and i.notes = 'opening_balance';
  perform pg_temp.ok(n = 0,
    '24. school B has no opening-balance invoice — every real run above was '
    'school A''s, and an unscoped lookup would have billed B''s child');
end;
$$;

rollback;
