-- =============================================================================
-- The student list: does the balance column agree with the ledger?
--
-- fn_student_list recomputes each student's balance SET-BASED rather than
-- calling student_balance() per row, because per-row would be 800 correlated
-- subqueries on a real school. That optimisation is only acceptable if the two
-- give identical answers, so the first and most important assertion here is a
-- row-by-row comparison against student_balance() itself — over a fixture that
-- deliberately includes every term of the formula: charges, a discount line, a
-- fine, an adjustment, a part payment, a full payment and a reversal.
--
-- The rest:
--
--  * total_count is the size of the whole filtered set, not of the page. The
--    old list silently showed 50 of 812 and never said so.
--  * Pages do not overlap and do not lose anybody.
--  * A "%" typed into the search box is a character, not a wildcard — AND a
--    pupil whose name really contains "%" or "_" can still be found. The second
--    half is the one that matters: without it the assertion passes on
--    double-escaped code that finds nothing at all. See 0051.
--  * Struck-off students are out of the default list but findable on request.
--  * No cross-tenant leak; a parent cannot call it.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/student_list.sql
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

-- --- Fixture -----------------------------------------------------------------
-- Twelve students across two classes so pagination is real, with one student
-- (SL Messy) carrying every kind of ledger entry at once.
do $seed$
declare
  v_a uuid; v_b uuid;
  v_oa uuid := '00000000-0000-0000-0000-0000005c0001';
  v_pa uuid := '00000000-0000-0000-0000-0000005c0002';
  v_ob uuid := '00000000-0000-0000-0000-0000005c0003';
  v_sess uuid; v_c1 uuid; v_c2 uuid; v_sec uuid; v_head uuid;
  v_i int;
  v_stu uuid; v_inv uuid; v_pay jsonb;
begin
  insert into public.schools (name) values ('List School') returning id into v_a;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_a, 'growth', 'active', current_date + 30);
  insert into public.schools (name) values ('List Other') returning id into v_b;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_b, 'growth', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_oa, 'sla@list.test'), (v_pa, 'slp@list.test'), (v_ob, 'slo@list.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_oa, 'List Owner',  'owner',  v_a),
    (v_pa, 'List Parent', 'parent', v_a),
    (v_ob, 'Other Owner', 'owner',  v_b)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role      = excluded.role,
                                   full_name = excluded.full_name,
                                   active    = true;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_oa::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_a) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('List One', 1, v_a) returning id into v_c1;
  insert into public.classes (name, level_order, school_id)
    values ('List Two', 2, v_a) returning id into v_c2;
  insert into public.sections (class_id, name, school_id)
    values (v_c1, 'A', v_a) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, sort_order, school_id)
    values ('Tuition', 'monthly', true, 10, v_a) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_c1, v_head, 1000, v_a);
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_c2, v_head, 2000, v_a);

  -- Eight in class one (section A), three in class two.
  for v_i in 1..8 loop
    perform public.fn_admit_student(jsonb_build_object(
      'full_name', 'SL Alpha ' || lpad(v_i::text, 2, '0'),
      'father_name', 'Alpha Father ' || v_i,
      'session_id', v_sess, 'class_id', v_c1, 'section_id', v_sec,
      'roll_no', v_i::text, 'links', '[]'::jsonb));
  end loop;
  for v_i in 1..3 loop
    perform public.fn_admit_student(jsonb_build_object(
      'full_name', 'SL Beta ' || v_i,
      'father_name', 'Beta Father ' || v_i,
      'session_id', v_sess, 'class_id', v_c2,
      'roll_no', v_i::text, 'links', '[]'::jsonb));
  end loop;

  -- The messy one: every term of the balance formula in a single student.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'SL Messy', 'father_name', 'Messy Father',
    'admission_no', 'ADM-777',
    'session_id', v_sess, 'class_id', v_c1, 'section_id', v_sec,
    'roll_no', '99', 'links', '[]'::jsonb));
  select id into v_stu from public.students where full_name = 'SL Messy';

  perform public.fn_generate_class_invoices(v_sess, v_c1,
    date_trunc('month', current_date)::date, current_date + 10);
  perform public.fn_generate_class_invoices(v_sess, v_c2,
    date_trunc('month', current_date)::date, current_date + 10);

  select i.id into v_inv from public.invoices i
   where i.student_id = v_stu order by i.created_at desc limit 1;

  -- a discount line, a fine, and an adjustment
  insert into public.invoice_lines (invoice_id, fee_head_id, description, amount, is_discount, school_id)
    values (v_inv, v_head, 'Hardship discount', 150, true, v_a);
  update public.invoices set fine = 75 where id = v_inv;
  insert into public.adjustments (invoice_id, student_id, amount, reason, created_by, school_id)
    values (v_inv, v_stu, 40, 'Library fine', v_oa, v_a);

  -- a part payment, then a payment that is reversed
  perform public.fn_record_payment(v_stu, 300, 'cash', 'part', false);
  v_pay := public.fn_record_payment(v_stu, 200, 'cash', 'to be reversed', false);
  perform public.fn_reverse_payment((v_pay->>'payment_id')::uuid, 'test reversal');

  -- one struck-off student, who still owes
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'SL StruckOff', 'father_name', 'Gone Father',
    'session_id', v_sess, 'class_id', v_c1, 'section_id', v_sec,
    'links', '[]'::jsonb));
  update public.students set status = 'struck_off' where full_name = 'SL StruckOff';

  -- and a student in the other school
  perform set_config('test.uid', v_ob::text, false);
  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_b) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('List One', 1, v_b) returning id into v_c1;
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'SL Foreign', 'father_name', 'Foreign Father',
    'session_id', v_sess, 'class_id', v_c1, 'links', '[]'::jsonb));
end $seed$;

-- =============================================================================
-- 1-2: THE assertion — the fast balance must equal the real one
-- =============================================================================
do $t$
declare v_mismatch int; v_messy numeric; v_real numeric;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0001', false);

  select count(*) into v_mismatch
  from public.fn_student_list(null, null, null, true, 500, 0) l
  where l.balance <> public.student_balance(l.student_id);

  perform pg_temp.ok(v_mismatch = 0,
    '1. every row''s balance equals student_balance() (' || v_mismatch || ' mismatches)');

  -- Stated explicitly for the student carrying charges, a discount, a fine, an
  -- adjustment, a part payment and a reversal all at once.
  select l.balance into v_messy
  from public.fn_student_list('SL Messy', null, null, true, 10, 0) l;
  select public.student_balance(id) into v_real from public.students where full_name = 'SL Messy';
  perform pg_temp.ok(v_messy = v_real and v_messy <> 0,
    '2. and agrees on the student with every kind of entry (' || v_messy || ')');
end $t$;

-- =============================================================================
-- 3-6: the count and the pages
-- =============================================================================
do $t$
declare v_total bigint; v_rows int; v_p1 text; v_p2 text; v_all int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0001', false);

  -- 12 active (8 + 3 + Messy); StruckOff excluded by default.
  select total_count into v_total from public.fn_student_list(null, null, null, false, 5, 0) limit 1;
  perform pg_temp.ok(v_total = 12,
    '3. total_count is the whole filtered set, not the page (' || v_total || ')');

  select count(*) into v_rows from public.fn_student_list(null, null, null, false, 5, 0);
  perform pg_temp.ok(v_rows = 5, '4. and the page really is a page (' || v_rows || ')');

  select string_agg(full_name, '|' order by full_name) into v_p1
    from public.fn_student_list(null, null, null, false, 5, 0);
  select string_agg(full_name, '|' order by full_name) into v_p2
    from public.fn_student_list(null, null, null, false, 5, 5);
  perform pg_temp.ok(v_p1 <> v_p2 and v_p1 is not null and v_p2 is not null,
    '5. page two is different from page one');

  -- Nobody lost, nobody duplicated, across the whole run of pages.
  select count(distinct full_name) into v_all from (
    select full_name from public.fn_student_list(null, null, null, false, 5, 0)
    union all
    select full_name from public.fn_student_list(null, null, null, false, 5, 5)
    union all
    select full_name from public.fn_student_list(null, null, null, false, 5, 10)
  ) x;
  perform pg_temp.ok(v_all = 12,
    '6. paging through returns every student exactly once (' || v_all || ')');
end $t$;

-- =============================================================================
-- 7-11: filters and search
-- =============================================================================
do $t$
declare v_n int; v_c1 uuid; v_sec uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0001', false);
  select id into v_c1 from public.classes
   where school_id = public.current_school_id() and name = 'List One';
  select id into v_sec from public.sections where class_id = v_c1 limit 1;

  select count(*) into v_n from public.fn_student_list('Beta', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 3, '7. a name search narrows to the right students (' || v_n || ')');

  select count(*) into v_n from public.fn_student_list('ADM-777', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 1, '8. admission number is searchable');

  select count(*) into v_n from public.fn_student_list('Messy Father', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 1, '9. so is the father''s name — how a parent is actually found');

  select count(*) into v_n from public.fn_student_list(null, v_c1, null, false, 50, 0);
  perform pg_temp.ok(v_n = 9, '10. the class filter works (8 alphas + Messy = ' || v_n || ')');

  -- A "%" typed into a search box must be a character, not a wildcard that
  -- returns the whole school.
  select count(*) into v_n from public.fn_student_list('%', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 0,
    '11. a literal % matches nothing rather than everything (' || v_n || ')');
end $t$;

-- =============================================================================
-- 11b-11d: THE ASSERTION ABOVE PASSED FOR THE WRONG REASON FOR WEEKS
--
-- Escaping written as replace(v_term, '\\', '\\\\') is DOUBLE-escaped:
-- standard_conforming_strings is on in Postgres, so '\\' in SQL source is two
-- backslash characters, not one. The pattern built for "%" then demanded a
-- LITERAL BACKSLASH, matched nothing, and assertion 11 was satisfied — while a
-- pupil whose name or roll number genuinely contained "_" or "%" could not be
-- found at all.
--
-- "Matches nothing" and "correctly escaped" look identical from outside. The
-- only assertion that separates them is the positive one: a child WITH the
-- character in their name must be FOUND by searching for it. Fixed in 0051.
-- =============================================================================
do $t$
declare v_n int; v_c1 uuid; v_sess uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0001', false);
  select id into v_sess from public.academic_sessions
   where school_id = public.current_school_id() and is_current limit 1;
  select id into v_c1 from public.classes
   where school_id = public.current_school_id() order by level_order limit 1;

  -- "A_1" is an ordinary roll number, and imported CSVs transliterate names
  -- with underscores all the time.
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'Under_Score Child', 'father_name', 'Escape Father',
    'father_cnic', '35201-9100077-7', 'session_id', v_sess, 'class_id', v_c1,
    'roll_no', 'A_1', 'links', '[]'::jsonb));
  perform public.fn_admit_student(jsonb_build_object(
    'full_name', 'Fifty% Percent', 'father_name', 'Escape Father',
    'father_cnic', '35201-9100078-8', 'session_id', v_sess, 'class_id', v_c1,
    'roll_no', 'A2', 'links', '[]'::jsonb));

  select count(*) into v_n
  from public.fn_student_list('Under_Score', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 1,
    '11b. a name containing "_" IS found by searching it (' || v_n || ') — '
    'this is what the double-escaped version got wrong');

  select count(*) into v_n
  from public.fn_student_list('Fifty%', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 1,
    '11c. and a name containing "%" is found too (' || v_n || ')');

  -- And the escaping still holds: "_" must not behave as a single-character
  -- wildcard. It matches the one child who really has an underscore, and not
  -- the rest of the school.
  select count(*) into v_n from public.fn_student_list('_', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 1,
    '11d. "_" matches only the child who really has one, not every 1-char '
    'position (' || v_n || ')');
end $t$;

-- =============================================================================
-- 12-13: struck-off students
-- =============================================================================
do $t$
declare v_n int;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0001', false);

  select count(*) into v_n from public.fn_student_list('StruckOff', null, null, false, 50, 0);
  perform pg_temp.ok(v_n = 0, '12. a struck-off student is out of the daily list');

  select count(*) into v_n from public.fn_student_list('StruckOff', null, null, true, 50, 0);
  perform pg_temp.ok(v_n = 1,
    '13. but still findable when asked for — they may still owe money');
end $t$;

-- =============================================================================
-- 14-17: the guards
-- =============================================================================
do $t$
declare v_n int; v_foreign_class uuid;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0001', false);

  perform pg_temp.ok(not exists (
    select 1 from public.fn_student_list(null, null, null, true, 500, 0)
     where full_name = 'SL Foreign'),
    '14. the other school''s student never appears');

  select id into v_foreign_class from public.classes
   where school_id = (select id from public.schools where name = 'List Other') limit 1;
  begin
    perform count(*) from public.fn_student_list(null, v_foreign_class, null, false, 50, 0);
    raise exception 'FAIL  15. filtered by another school''s class';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  15. a foreign class id is refused (%)', sqlerrm;
  end;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0002', false);
  begin
    perform count(*) from public.fn_student_list(null, null, null, false, 50, 0);
    raise exception 'FAIL  16. a parent listed the school''s students';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    raise notice 'PASS  16. a parent cannot list students (%)', sqlerrm;
  end;

  perform set_config('test.uid', '00000000-0000-0000-0000-0000005c0001', false);
  select count(*) into v_n from public.fn_student_list(null, null, null, true, 100000, 0);
  perform pg_temp.ok(v_n <= 500, '17. an absurd page size is clamped (' || v_n || ')');
end $t$;

do $$ begin raise notice '--- student_list.sql: all assertions passed'; end $$;

rollback;
