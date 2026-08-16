-- =============================================================================
-- Portal isolation.
--
-- This is the highest-stakes test file in the project. Everything else that
-- leaks costs a school money; this leaks children.
--
-- Before the portal existed, twenty-five tables carried a policy of the form
-- `using (school_id = current_school_id())` with no role check. That was
-- correct while every account belonged to staff. Adding a parent role to that
-- world would have handed each parent the whole school — every child's name,
-- every mark, every attendance record, every other family's phone number —
-- with no bug required.
--
-- So the rules defended here are:
--
--  1. A parent account can read NOTHING from any table directly. Not students,
--     not their own child's row, not the family they belong to. Table access
--     is closed and the portal functions carry all of it.
--  2. A parent reaches their own children through the portal functions, and
--     ONLY their own — passing another family's student_id is refused.
--  3. The refusal is indistinguishable between "no such student" and "not
--     yours", so student ids cannot be enumerated.
--  4. Unfrozen result cards are never shown.
--  5. A parent cannot promote themselves, cannot link themselves to another
--     family, and cannot see the school's money or licence.
--  6. Staff are unaffected — the policy rewrite must not have broken them.
--
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/portal.sql
-- =============================================================================

\set ON_ERROR_STOP on

create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

-- --- Fixture: one school, two families, one parent account each -------------
do $seed$
declare
  v_school uuid;
  v_owner  uuid := '00000000-0000-0000-0000-00000000d001';
  v_par_a  uuid := '00000000-0000-0000-0000-00000000d002';
  v_par_b  uuid := '00000000-0000-0000-0000-00000000d003';
  v_sess uuid; v_class uuid; v_sec uuid; v_head uuid;
  v_fam_a uuid; v_fam_b uuid;
  v_kid_a1 uuid; v_kid_a2 uuid; v_kid_b uuid;
  v_enr uuid; v_term uuid;
begin
  perform set_config('test.uid', '', false);
  delete from public.schools where name = 'Portal Test School';

  insert into public.schools (name) values ('Portal Test School') returning id into v_school;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_school, 'starter', 'active', current_date + 30);

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values
    (v_owner, 'p1@portal.test'), (v_par_a, 'p2@portal.test'), (v_par_b, 'p3@portal.test')
    on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id) values
    (v_owner, 'Portal Owner', 'owner',  v_school),
    (v_par_a, 'Aslam Sahib',  'parent', v_school),
    (v_par_b, 'Khan Sahib',   'parent', v_school)
  on conflict (id) do update set school_id = excluded.school_id, role = excluded.role;
  alter table public.profiles enable trigger user;

  perform set_config('test.uid', v_owner::text, false);

  insert into public.school_settings (school_id, name)
    values (v_school, 'Portal Test School')
    on conflict (school_id) do update set name = excluded.name;

  insert into public.academic_sessions (name, is_current, school_id)
    values ('2025-2026', true, v_school) returning id into v_sess;
  insert into public.classes (name, level_order, school_id)
    values ('Class 5', 5, v_school) returning id into v_class;
  insert into public.sections (class_id, name, school_id)
    values (v_class, 'A', v_school) returning id into v_sec;
  insert into public.fee_heads (name, type, is_recurring, active, school_id)
    values ('Tuition', 'monthly', true, true, v_school) returning id into v_head;
  insert into public.fee_structures (session_id, class_id, fee_head_id, amount, school_id)
    values (v_sess, v_class, v_head, 1500, v_school);

  insert into public.families (school_id, head_name, head_cnic)
    values (v_school, 'Aslam Sahib', '35201-9999999-1') returning id into v_fam_a;
  insert into public.families (school_id, head_name, head_cnic)
    values (v_school, 'Khan Sahib', '35201-8888888-2') returning id into v_fam_b;

  insert into public.students (full_name, status, school_id, family_id)
    values ('Ali Aslam', 'active', v_school, v_fam_a) returning id into v_kid_a1;
  insert into public.students (full_name, status, school_id, family_id)
    values ('Ayesha Aslam', 'active', v_school, v_fam_a) returning id into v_kid_a2;
  insert into public.students (full_name, status, school_id, family_id)
    values ('Bilal Khan', 'active', v_school, v_fam_b) returning id into v_kid_b;

  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_kid_a1, v_sess, v_class, v_sec, 'active', v_school) returning id into v_enr;
  insert into public.attendance_daily (enrollment_id, attendance_date, status, school_id)
    values (v_enr, current_date, 'present', v_school),
           (v_enr, current_date - 1, 'absent', v_school);

  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_kid_a2, v_sess, v_class, v_sec, 'active', v_school);
  insert into public.enrollments (student_id, session_id, class_id, section_id, status, school_id)
    values (v_kid_b, v_sess, v_class, v_sec, 'active', v_school);

  -- Three cards, to prove what the portal filters:
  --   First Term  v1 (superseded) and v2 (published)  -> only v2 may appear
  --   Mid Term    generated but never published        -> must stay hidden
  insert into public.exam_terms (session_id, name, term_type, school_id)
    values (v_sess, 'First Term', 'first', v_school) returning id into v_term;
  insert into public.result_cards (student_id, enrollment_id, exam_term_id, total_marks,
                                   total_max, percentage, grade, position, version,
                                   frozen, published_at, school_id)
    values (v_kid_a1, v_enr, v_term, 111, 500, 22, 'F', 30, 1,
            '{"withheld": false}'::jsonb, now(), v_school);
  insert into public.result_cards (student_id, enrollment_id, exam_term_id, total_marks,
                                   total_max, percentage, grade, position, version,
                                   frozen, published_at, school_id)
    values (v_kid_a1, v_enr, v_term, 420, 500, 84, 'A', 3, 2,
            '{"withheld": false}'::jsonb, now(), v_school);

  insert into public.exam_terms (session_id, name, term_type, school_id)
    values (v_sess, 'Mid Term', 'mid', v_school) returning id into v_term;
  insert into public.result_cards (student_id, enrollment_id, exam_term_id, total_marks,
                                   total_max, percentage, grade, position, version,
                                   frozen, school_id)
    values (v_kid_a1, v_enr, v_term, 300, 500, 60, 'C', 9, 1,
            '{"withheld": false}'::jsonb, v_school);

  perform public.fn_generate_class_invoices(v_sess, v_class, date '2025-09-01', date '2025-09-10');

  -- Link the parent accounts to their families.
  perform public.fn_link_parent(v_par_a, v_fam_a);
  perform public.fn_link_parent(v_par_b, v_fam_b);

  raise notice 'fixture ok';
end $seed$;

-- =============================================================================
-- 1. A parent can read NOTHING from any table
-- =============================================================================
do $t$
declare r record; v_n bigint; v_leaks text := '';
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);
  set local role authenticated;

  for r in
    select unnest(array[
      'students', 'enrollments', 'attendance_daily', 'mark_entries',
      'result_cards', 'guardians', 'families', 'staff', 'classes', 'sections',
      'subjects', 'academic_sessions', 'fee_heads', 'fee_structures',
      'invoices', 'invoice_lines', 'payments', 'expenses', 'schools',
      'subscriptions', 'school_settings', 'teacher_assignments',
      'student_links', 'exam_terms', 'assessments', 'till_sessions'
    ]) as t
  loop
    execute format('select count(*) from public.%I', r.t) into v_n;
    if v_n > 0 then
      v_leaks := v_leaks || format('%s(%s) ', r.t, v_n);
    end if;
  end loop;

  reset role;
  if v_leaks <> '' then
    raise exception 'FAIL: a parent account can read these tables directly: %', v_leaks;
  end if;
  raise notice '1. parent has zero direct table access — ok';
end $t$;

-- =============================================================================
-- 2. A parent sees exactly their own children through the portal
-- =============================================================================
do $t$
declare j jsonb; v_names text;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);
  j := public.fn_portal_me();

  if j->>'role' <> 'parent' then raise exception 'FAIL: role is %', j->>'role'; end if;
  if j->>'school_name' <> 'Portal Test School' then
    raise exception 'FAIL: school name is %', j->>'school_name';
  end if;
  if jsonb_array_length(j->'children') <> 2 then
    raise exception 'FAIL: expected 2 children, got %', jsonb_array_length(j->'children');
  end if;

  select string_agg(c->>'full_name', ',' order by c->>'full_name') into v_names
  from jsonb_array_elements(j->'children') c;
  if v_names <> 'Ali Aslam,Ayesha Aslam' then
    raise exception 'FAIL: wrong children returned: %', v_names;
  end if;
  raise notice '2. parent sees exactly their own children — ok';
end $t$;

-- =============================================================================
-- 3. THE BIG ONE — another family's child is refused
-- =============================================================================
do $t$
declare v_other uuid; v_ok boolean;
begin
  select id into v_other from public.students where full_name = 'Bilal Khan';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);

  v_ok := false;
  begin perform public.fn_portal_child_fees(v_other); v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: read another family''s FEES'; end if;

  v_ok := false;
  begin perform public.fn_portal_child_attendance(v_other, current_date - 30, current_date); v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: read another family''s ATTENDANCE'; end if;

  v_ok := false;
  begin perform public.fn_portal_child_results(v_other); v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: read another family''s RESULTS'; end if;

  raise notice '3. another family''s child refused on every endpoint — ok';
end $t$;

-- =============================================================================
-- 4. The refusal does not leak whether the student exists
-- =============================================================================
do $t$
declare v_real uuid; v_fake uuid := gen_random_uuid(); m_real text; m_fake text;
begin
  select id into v_real from public.students where full_name = 'Bilal Khan';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);

  begin perform public.fn_portal_child_fees(v_real);
  exception when others then m_real := sqlerrm; end;
  begin perform public.fn_portal_child_fees(v_fake);
  exception when others then m_fake := sqlerrm; end;

  if m_real is distinct from m_fake then
    raise exception 'FAIL: error differs for a real vs invented id (% vs %) — ids can be enumerated',
      m_real, m_fake;
  end if;
  raise notice '4. refusal is indistinguishable, no enumeration oracle — ok';
end $t$;

-- =============================================================================
-- 5. Own child's data comes through correctly
-- =============================================================================
do $t$
declare v_kid uuid; j jsonb;
begin
  select id into v_kid from public.students where full_name = 'Ali Aslam';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);

  j := public.fn_portal_child_fees(v_kid);
  if (j->>'balance')::numeric <> 1500 then
    raise exception 'FAIL: expected 1500 balance, got %', j->>'balance';
  end if;
  if (j->>'family_outstanding')::numeric <> 3000 then
    raise exception 'FAIL: family owes 3000 (two children), got %', j->>'family_outstanding';
  end if;

  j := public.fn_portal_child_attendance(v_kid, current_date - 7, current_date);
  if (j->>'marked')::int <> 2 then
    raise exception 'FAIL: expected 2 marked days, got %', j->>'marked';
  end if;
  if (j->>'present')::int <> 1 then
    raise exception 'FAIL: expected 1 present day, got %', j->>'present';
  end if;
  if (j->>'percent')::numeric <> 50 then
    raise exception 'FAIL: expected 50 percent, got %', j->>'percent';
  end if;
  raise notice '5. own child''s fees and attendance are correct — ok';
end $t$;

-- =============================================================================
-- 6. Unpublished cards stay hidden, and only the newest version shows
-- =============================================================================
do $t$
declare v_kid uuid; j jsonb;
begin
  select id into v_kid from public.students where full_name = 'Ali Aslam';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);
  j := public.fn_portal_child_results(v_kid);

  if jsonb_array_length(j) <> 1 then
    raise exception 'FAIL: expected 1 card (published, newest version), got %', jsonb_array_length(j);
  end if;
  if j->0->>'term' <> 'First Term' then
    raise exception 'FAIL: the UNPUBLISHED Mid Term card leaked (%)', j->0->>'term';
  end if;
  if (j->0->>'percentage')::numeric <> 84 then
    raise exception 'FAIL: a SUPERSEDED version leaked — got % instead of 84', j->0->>'percentage';
  end if;
  raise notice '6. unpublished hidden, newest version only — ok';
end $t$;

-- =============================================================================
-- 6b. A withheld result shows the reason, never the marks
-- =============================================================================
do $t$
declare
  v_kid uuid; v_enr uuid; v_term uuid; v_sess uuid; j jsonb; c jsonb;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d001', false);
  select id into v_kid from public.students where full_name = 'Ayesha Aslam';
  select id into v_enr from public.enrollments where student_id = v_kid;
  select id into v_sess from public.academic_sessions
   where school_id = (select id from public.schools where name = 'Portal Test School');
  insert into public.exam_terms (session_id, name, term_type,
                                 result_withheld_for_defaulters, school_id)
    values (v_sess, 'Withheld Term', 'final', true,
            (select id from public.schools where name = 'Portal Test School'))
    returning id into v_term;
  insert into public.result_cards (student_id, enrollment_id, exam_term_id, total_marks,
                                   total_max, percentage, grade, position, version,
                                   frozen, published_at, school_id)
    values (v_kid, v_enr, v_term, 480, 500, 96, 'A+', 1, 1,
            '{"withheld": true}'::jsonb, now(),
            (select id from public.schools where name = 'Portal Test School'));

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);
  j := public.fn_portal_child_results(v_kid);
  select e into c from jsonb_array_elements(j) e where e->>'term' = 'Withheld Term';

  if c is null then
    raise exception 'FAIL: a withheld card vanished entirely — that reads as a lost result';
  end if;
  if (c->>'withheld')::boolean is not true then
    raise exception 'FAIL: withheld card not flagged';
  end if;
  if c ? 'percentage' or c ? 'obtained_marks' or c ? 'subjects' then
    raise exception 'FAIL: a withheld card leaked the marks: %', c;
  end if;
  raise notice '6b. withheld result shows the reason, not the marks — ok';
end $t$;

-- =============================================================================
-- 7. A parent cannot promote themselves or re-point their own family
-- =============================================================================
do $t$
declare v_fam_b uuid; v_ok boolean;
begin
  select id into v_fam_b from public.families where head_name = 'Khan Sahib';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);

  v_ok := false;
  begin
    perform public.fn_link_parent('00000000-0000-0000-0000-00000000d002', v_fam_b);
    v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: a parent re-linked themselves to another family'; end if;

  -- and cannot escalate by writing their own profile row
  v_ok := false;
  begin
    set local role authenticated;
    update public.profiles set role = 'owner' where id = auth.uid();
    reset role;
    if (select role from public.profiles
        where id = '00000000-0000-0000-0000-00000000d002') = 'owner' then
      v_ok := true;
    end if;
  exception when others then reset role; end;
  if v_ok then raise exception 'FAIL: a parent promoted themselves to owner'; end if;

  raise notice '7. parent cannot escalate or re-link — ok';
end $t$;

-- =============================================================================
-- 8. A parent cannot see the school's money or licence
-- =============================================================================
do $t$
declare v_ok boolean;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d002', false);

  v_ok := false;
  begin perform public.fn_finance_summary(current_date, current_date); v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: a parent read the school profit summary'; end if;

  v_ok := false;
  begin perform public.fn_family_sheet(public.my_family_id()); v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: a parent reached the staff fee-collection sheet'; end if;

  raise notice '8. parent cannot see school money — ok';
end $t$;

-- =============================================================================
-- 9. Staff are unaffected by the policy rewrite
-- =============================================================================
do $t$
declare v_students bigint; v_classes bigint; j jsonb;
begin
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d001', false);
  set local role authenticated;
  select count(*) into v_students from public.students;
  select count(*) into v_classes from public.classes;
  reset role;

  if v_students <> 3 then
    raise exception 'FAIL: the owner now sees % students instead of 3 — policy rewrite broke staff', v_students;
  end if;
  if v_classes < 1 then
    raise exception 'FAIL: the owner cannot see classes any more';
  end if;

  j := public.fn_portal_me();
  if j->>'role' <> 'owner' then raise exception 'FAIL: portal_me wrong for staff'; end if;
  if jsonb_array_length(j->'children') <> 0 then
    raise exception 'FAIL: a staff account was given children';
  end if;
  raise notice '9. staff access unaffected — ok';
end $t$;

-- =============================================================================
-- 10. Staff calling a parent-only endpoint is refused, not silently empty
-- =============================================================================
do $t$
declare v_kid uuid; v_ok boolean := false;
begin
  select id into v_kid from public.students where full_name = 'Ali Aslam';
  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d001', false);
  begin perform public.fn_portal_child_fees(v_kid); v_ok := true;
  exception when others then null; end;
  if v_ok then
    raise exception 'FAIL: a staff account went through the parent endpoint — that path must stay parent-only';
  end if;
  raise notice '10. parent endpoints are parent-only — ok';
end $t$;

-- =============================================================================
-- 11. Cross-tenant: a parent in another school reaches nothing
-- =============================================================================
do $t$
declare
  v_other uuid; v_par uuid := '00000000-0000-0000-0000-00000000d009';
  v_fam uuid; v_kid uuid; v_ok boolean;
begin
  perform set_config('test.uid', '', false);
  delete from public.schools where name = 'Other Portal School';
  insert into public.schools (name) values ('Other Portal School') returning id into v_other;
  insert into public.subscriptions (school_id, plan_code, status, trial_ends_on)
    values (v_other, 'starter', 'active', current_date + 30);

  insert into public.families (school_id, head_name) values (v_other, 'Outsider')
    returning id into v_fam;

  alter table public.profiles disable trigger user;
  insert into auth.users (id, email) values (v_par, 'p9@portal.test') on conflict (id) do nothing;
  insert into public.profiles (id, full_name, role, school_id, family_id)
    values (v_par, 'Outsider Parent', 'parent', v_other, v_fam)
    on conflict (id) do update set school_id = excluded.school_id,
                                   role = excluded.role, family_id = excluded.family_id;
  alter table public.profiles enable trigger user;

  select id into v_kid from public.students where full_name = 'Ali Aslam';
  perform set_config('test.uid', v_par::text, false);

  v_ok := false;
  begin perform public.fn_portal_child_fees(v_kid); v_ok := true;
  exception when others then null; end;
  if v_ok then raise exception 'FAIL: a parent in another SCHOOL read a child''s fees'; end if;

  if jsonb_array_length(public.fn_portal_me()->'children') <> 0 then
    raise exception 'FAIL: an outsider parent was given children';
  end if;

  perform set_config('test.uid', '00000000-0000-0000-0000-00000000d001', false);
  raise notice '11. cross-school parent reaches nothing — ok';
end $t$;

-- =============================================================================
-- 12. STRUCTURAL GUARD — exactly one SELECT policy per protected table,
--     and it must consult is_staff().
--
-- This exists because of a real bug caught by test 1. RLS policies are
-- permissive and OR together, so a leftover policy under a different name
-- re-opens a table that a newer policy appears to have closed. Checking the
-- catalogue directly is the only way to see that; reading the migration does
-- not show it.
-- =============================================================================
do $t$
declare t text; v_n integer; v_bad text := ''; v_quals text;
begin
  foreach t in array array[
    'academic_sessions', 'assessments', 'attendance_daily', 'campuses',
    'classes', 'enrollments', 'exam_subjects', 'exam_terms', 'families',
    'fee_heads', 'fee_structures', 'guardians', 'mark_entries',
    'result_cards', 'sections', 'shifts', 'staff', 'student_links',
    'students', 'subjects', 'teacher_assignments', 'school_settings'
  ] loop
    select count(*), string_agg(coalesce(qual, ''), ' ~ ')
      into v_n, v_quals
    from pg_policies
    where schemaname = 'public' and tablename = t and cmd = 'SELECT';

    if v_n <> 1 then
      v_bad := v_bad || format('%s has %s SELECT policies; ', t, v_n);
    elsif v_quals not like '%is_staff%' then
      v_bad := v_bad || format('%s SELECT policy does not check is_staff(); ', t);
    end if;
  end loop;

  if v_bad <> '' then
    raise exception 'FAIL: %', v_bad;
  end if;
  raise notice '12. one staff-checked SELECT policy per protected table — ok';
end $t$;

do $$ begin raise notice 'ALL PORTAL TESTS PASSED'; end $$;
